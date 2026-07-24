#!/usr/bin/env node
// Baywatch · The Desk — operator console server.
// Orchestrates a live two-pool simulation and streams it to the browser:
//   • flow engine: runs FlowStep (identical trades to the defended + naïve pools) on an interval
//   • shadow PnL: accumulates each pool's reserves from trade deltas -> the "edge" (what the defense earned)
//   • agent loop: runs the Radar markout agent, which flags sharks and posts per-taker tolls
//   • controls: pause/resume, launch a shark attack, trip / restore the depeg circuit breaker
//   • transport: Server-Sent Events (live push) + /api/state (poll fallback)
// All on-chain actions are SERIALIZED through one promise chain so they never collide on the
// shared anvil account's nonce. forge/cast run async so the HTTP server stays responsive.
import { createServer } from "node:http";
import { readFileSync, existsSync, appendFileSync } from "node:fs";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const pexec = promisify(execFile);
const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "..");

// Synchronous logging (Node block-buffers stdout to a file, hiding crashes) + never die silently.
const LOGF = join(HERE, "server.log");
const _log = (tag, a) => {
  const line = `[${new Date().toISOString().slice(11, 19)} ${tag}] ` + a.map((x) => typeof x === "string" ? x : (x?.stack || JSON.stringify(x))).join(" ") + "\n";
  try { appendFileSync(LOGF, line); } catch { /* noop */ }
  try { process.stderr.write(line); } catch { /* noop */ }
};
console.log = (...a) => _log("log", a);
console.error = (...a) => _log("err", a);
process.on("unhandledRejection", (e) => _log("unhandledRejection", [e]));
process.on("uncaughtException", (e) => _log("uncaughtException", [e]));
const PORT = Number(process.env.PORT || 5170);
const RPC = process.env.RPC || "http://localhost:8545";
const POSTER_PK = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"; // anvil[0]
const ZERO = "0x0000000000000000000000000000000000000000";

// timing
const TICK_GAP_MS = 1200;   // pause between flow ticks
const AGENT_EVERY = 4;      // run the agent every N ticks
const FLOW_N = 3;           // trades per tick
const ATTACK_TICKS = 6;     // ticks of heavy shark flow per "attack"
const SERIES_CAP = 150, TRADES_CAP = 50;

const forgeEnv = (extra = {}) => ({ ...process.env, ...extra });
const runForge = (script, env = {}) =>
  pexec("forge", ["script", script, "--rpc-url", RPC, "--broadcast", "--skip-simulation"],
    { cwd: ROOT, env: forgeEnv(env), maxBuffer: 1 << 27 });
const runAgent = () => pexec("node", ["agent/agent.mjs"], { cwd: ROOT, env: forgeEnv(), maxBuffer: 1 << 27 });
const cast = (...args) => pexec("cast", args, { cwd: ROOT, env: forgeEnv() });
const readJson = (p) => (existsSync(p) ? JSON.parse(readFileSync(p, "utf8")) : null);
const nowSec = () => Math.floor(Date.now() / 1000);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// The main loop is the SINGLE sequencer of every on-chain op (flow + agent + regime), so there are no
// nonce races and no separate serialization. Controls just set flags: the loop applies a pending regime
// at the top of the next iteration (~1 tick, responsive) while the UI reflects it optimistically.
let pendingRegime = null; // { tier, name }

// ---- state ----
let desk = null;
let R = { defA: 0n, defB: 0n, naiveA: 0n, naiveB: 0n };
let series = [];      // {t, edge, defValue, naiveValue}
let trades = [];      // recent, newest first
let brain = { lastScan: null, flagged: [], spreadPct: 0, regime: "NORMAL", scans: 0, marketIndex: 0, marketMarkoutBps: 0, source: "mock", venues: [], watchlist: [] };
let status = { paused: false, mode: "normal", attackTicks: 0, block: 0, step: 0, tolls: 0, trend: "up" };
let clients = [];

const toNum = (wei) => Number(wei) / 1e18;
const defValue = () => toNum(R.defA + R.defB);
const naiveValue = () => toNum(R.naiveA + R.naiveB);

function snapshot() {
  return {
    meta: desk && {
      defendedOrderHash: desk.defendedOrderHash, naiveOrderHash: desk.naiveOrderHash,
      oracle: desk.oracle, router: desk.router, tokenA: desk.tokenA, tokenB: desk.tokenB,
      initReserve: desk.initReserve, numTourists: desk.numTourists, numSharks: desk.numSharks,
    },
    reserves: { defA: R.defA.toString(), defB: R.defB.toString(), naiveA: R.naiveA.toString(), naiveB: R.naiveB.toString() },
    defValue: defValue(), naiveValue: naiveValue(), edge: defValue() - naiveValue(),
    series, trades, brain, status, now: nowSec(),
  };
}

function broadcast() {
  const data = `event: state\ndata: ${JSON.stringify(snapshot())}\n\n`;
  for (const c of clients) { try { c.write(data); } catch { /* dropped */ } }
}

// ---- flow tick: run FlowStep, accumulate reserves/edge, append trades ----
async function flowTick() {
  const attack = status.attackTicks > 0;
  if (attack) status.attackTicks--;
  status.mode = attack ? "attack" : "normal";
  status.step++;
  status.trend = (Math.floor(status.step / 8) % 2 === 0) ? "up" : "down"; // oscillate so reserves stay bounded
  // When halted, the maker's router doesn't route to the defended pool — the on-chain breaker is the
  // provable enforcement backstop, but skipping the doomed swap keeps the tick fast and blocking instant.
  const defBlocked = brain.regime === "HALT";
  try {
    await runForge("script/FlowStep.s.sol", { FLOW_STEP: String(status.step), FLOW_MODE: status.mode, FLOW_N: String(FLOW_N), FLOW_TREND: status.trend, FLOW_DEF_BLOCKED: defBlocked ? "1" : "0" });
  } catch (e) {
    // forge can exit non-zero when a swap reverts; FlowStep still writes laststep.json (validated by step).
  }
  const ls = readJson(join(HERE, "laststep.json"));
  if (!ls || ls.step !== status.step) return;
  status.block = ls.block;
  const flaggedToll = new Map(brain.flagged.map((f) => [f.address.toLowerCase(), f.tollBps]));
  for (const t of ls.trades) {
    const amt = BigInt(t.amountIn), outD = BigInt(t.outDef), outN = BigInt(t.outNaive);
    // apply reserve deltas only for the legs that actually executed (breaker may block defended)
    if (t.tin === "B") { // bought A: B in, A out
      if (t.defOk) { R.defB += amt; R.defA -= outD; }
      if (t.naiveOk) { R.naiveB += amt; R.naiveA -= outN; }
    } else {             // A in, B out
      if (t.defOk) { R.defA += amt; R.defB -= outD; }
      if (t.naiveOk) { R.naiveA += amt; R.naiveB -= outN; }
    }
    // per-trade defense = the actual toll the agent posted for this taker (clean; NOT the pool-divergence diff)
    const tollBps = flaggedToll.get(t.taker.toLowerCase()) || 0;
    trades.unshift({
      taker: t.taker, shark: t.shark, tin: t.tin, defOk: t.defOk,
      amountIn: toNum(amt), outDef: toNum(outD), outNaive: toNum(outN),
      tollBps, ts: nowSec(), block: ls.block,
    });
  }
  trades = trades.slice(0, TRADES_CAP);
  series.push({ t: nowSec(), edge: defValue() - naiveValue(), defValue: defValue(), naiveValue: naiveValue() });
  series = series.slice(-SERIES_CAP);
  broadcast();
}

// ---- agent run: flag sharks, post tolls, refresh brain ----
async function agentRun() {
  try {
    await runAgent();
  } catch (e) {
    console.error("[agent] error:", (e.stderr || e.message || "").slice(0, 200));
    return;
  }
  const a = readJson(join(HERE, "analytics.json"));
  if (a) {
    brain.flagged = (a.takers || []).filter((x) => x.toxic)
      .map((x) => ({ address: x.address, markoutBps: x.markoutBps, tollBps: x.tollBps, venuesActive: x.venuesActive, boundTo: x.boundTo }));
    brain.marketIndex = a.marketIndex ?? 0;
    brain.marketMarkoutBps = a.marketMarkoutBps ?? 0;
    brain.venues = a.venues || [];
    brain.watchlist = a.watchlist || [];
    brain.source = a.source || "mock";
    brain.spreadPct = a.spreadPct ?? 0; // Radar market-index-driven spread the agent posted
    brain.lastScan = nowSec();
    brain.scans++;
    status.tolls = brain.flagged.length;
  }
  broadcast();
}

// ---- main loop (sequential; every on-chain op is serialized) ----
let ticksSinceAgent = AGENT_EVERY; // scan promptly on the first loop
async function loop() {
  for (;;) {
    try {
      if (pendingRegime) { const p = pendingRegime; pendingRegime = null; await applyRegime(p.tier, p.name); }
      if (!status.paused) {
        await flowTick();
        if (++ticksSinceAgent >= AGENT_EVERY) { ticksSinceAgent = 0; await agentRun(); }
      }
    } catch (e) { console.error("[loop]", e?.stack || e); }
    await sleep(TICK_GAP_MS);
  }
}

// ---- boot: fresh deploy, reset state ----
async function boot() {
  console.log("[boot] deploying fresh desk…");
  await runForge("script/DeployDesk.s.sol");
  desk = readJson(join(HERE, "desk.json"));
  if (!desk) throw new Error("desk.json missing after deploy");
  const init = BigInt(desk.initReserve);
  R = { defA: init, defB: init, naiveA: init, naiveB: init };
  series = []; trades = []; status.step = 0;
  brain = { lastScan: null, flagged: [], spreadPct: 0, regime: "NORMAL", scans: 0, marketIndex: 0, marketMarkoutBps: 0, source: "mock", venues: [], watchlist: [] };
  console.log(`[boot] desk ready. defended=${desk.defendedOrderHash.slice(0, 10)} naive=${desk.naiveOrderHash.slice(0, 10)}`);
}

// ---- controls ----
async function applyRegime(tier, name) {
  try {
    await cast("send", desk.oracle, "setRisk(bytes32,uint8,address)", desk.defendedOrderHash, String(tier), ZERO,
      "--private-key", POSTER_PK, "--rpc-url", RPC);
  } catch (e) { console.error("[regime] cast error:", (e.stderr || e.message || "").slice(0, 150)); }
  brain.regime = name;
  broadcast();
}

// ---- http ----
const send = (res, code, body, type = "application/json") => {
  res.writeHead(code, { "content-type": type, "cache-control": "no-store", "access-control-allow-origin": "*" });
  res.end(typeof body === "string" ? body : JSON.stringify(body));
};

createServer(async (req, res) => {
  const url = req.url.split("?")[0];
  try {
    if (url === "/" || url === "/index.html") return send(res, 200, readFileSync(join(HERE, "index.html"), "utf8"), "text/html; charset=utf-8");
    if (url === "/api/state") return send(res, 200, snapshot());
    if (url === "/api/stream") {
      res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache", connection: "keep-alive", "access-control-allow-origin": "*" });
      res.write(`event: state\ndata: ${JSON.stringify(snapshot())}\n\n`);
      clients.push(res);
      req.on("close", () => { clients = clients.filter((c) => c !== res); });
      return;
    }
    if (req.method === "POST") {
      if (url === "/api/pause") { status.paused = true; broadcast(); return send(res, 200, { ok: true }); }
      if (url === "/api/resume") { status.paused = false; broadcast(); return send(res, 200, { ok: true }); }
      if (url === "/api/attack") { status.attackTicks = ATTACK_TICKS; broadcast(); return send(res, 200, { ok: true }); }
      if (url === "/api/depeg") { pendingRegime = { tier: 2, name: "HALT" }; brain.regime = "HALT"; broadcast(); return send(res, 200, { ok: true }); }
      if (url === "/api/restore") { pendingRegime = { tier: 0, name: "NORMAL" }; brain.regime = "NORMAL"; broadcast(); return send(res, 200, { ok: true }); }
    }
    return send(res, 404, { error: "not found" });
  } catch (e) {
    return send(res, 500, { error: String(e?.message || e) });
  }
}).listen(PORT, async () => {
  console.log(`The Desk → http://localhost:${PORT}  (RPC ${RPC})`);
  try { await boot(); loop(); } catch (e) { console.error("[boot] FAILED:", e.message); }
});
