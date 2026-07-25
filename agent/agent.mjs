#!/usr/bin/env node
// Baywatch Radar agent: turn the cross-protocol toxicity signal into on-chain defense.
//
// Deterministic, no LLM. Pulls the Radar signal (one standardized query shape fanned across every AMM on
// the Messari DEX-AMM schema — mock fixtures with no key, The Graph gateway when GRAPH_API_KEY is set),
// then posts to the SAME ParamOracle the Baywatch opcodes already read:
//   • market toxicity index  -> global spread   (setParams)  — defends against ALL flow when the DEX
//                                                              landscape is being picked off
//   • cross-venue reputation -> per-taker toll   (setToll)    — an address that is adverse across ≥2 AMMs
//                                                              is pre-tolled the FIRST time it hits our pool
// The regime/breaker is left to the operator (the agent must not clobber a manual HALT).
//
// Binding note (local demo): our anvil MockTaker "sharks" can't literally be mainnet addresses, so we bind
// desk shark[i] -> the i-th cross-venue-confirmed toxic address (by toxicity). In production the binding is
// literal address equality: a watchlisted address showing up at our Aqua pool is tolled on sight.
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

import { generate } from "../radar/signal.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "..");
const POSTER_PK = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"; // anvil[0]

// Policy knobs (units: 1e9 = 100%, so 1e6 = 0.1%).
const BASE_SPREAD_BPS = 1_000_000;         // 0.1% floor spread (kept fresh = staleness fail-safe)
const MAX_MARKET_SPREAD_BPS = 30_000_000;  // 3.0% spread at market index 100 (well under the 50% program cap)
const TOLL_PER_MARKOUT_BP = 1_000_000;     // 1e6 tollBps per 1 markout-bp -> 36bps reputation => 3.6% toll
const MAX_TOLL_BPS = 0.5e9;

const d = JSON.parse(readFileSync(join(ROOT, "ui/desk.json"), "utf8"));
const rpc = d.rpc, oracle = d.oracle, orderHash = d.defendedOrderHash;
const sharks = d.takers.slice(d.numTourists); // desk shark addresses (informed flow in the sim)

const send = (sig, ...args) =>
  execFileSync("cast", ["send", oracle, sig, ...args, "--private-key", POSTER_PK, "--rpc-url", rpc, "--json"],
    { encoding: "utf8" });

// 1. Pull the cross-protocol Radar signal.
const signal = await generate();
mkdirSync(join(ROOT, "radar/out"), { recursive: true });
writeFileSync(join(ROOT, "radar/out/signal.json"), JSON.stringify(signal, null, 2));
console.log(`[agent] Radar source=${signal.source}: market index ${signal.marketIndex}/100 (${signal.marketMarkoutBps}bps), ${signal.venues.length} venues, ${signal.watchlist.filter((w) => w.toxic).length} toxic addresses`);

// 2. Market toxicity index -> global spread. Higher market-wide adverse selection => wider defensive spread.
const spreadBps = Math.round(BASE_SPREAD_BPS + (Math.max(0, Math.min(100, signal.marketIndex)) / 100) * (MAX_MARKET_SPREAD_BPS - BASE_SPREAD_BPS));
send("setParams(bytes32,uint32)", orderHash, String(spreadBps));
console.log(`[agent] SPREAD ${(spreadBps / 1e7).toFixed(2)}% (from market index ${signal.marketIndex})`);

// 3. Cross-venue-confirmed toxic addresses -> per-taker tolls, bound to our desk sharks.
const confirmed = signal.watchlist.filter((w) => w.toxic); // already sorted by toxicity desc
const bound = [];
for (let i = 0; i < sharks.length && i < confirmed.length; i++) {
  const w = confirmed[i];
  const tollBps = Math.min(MAX_TOLL_BPS, Math.round(w.toxicityBps * TOLL_PER_MARKOUT_BP));
  send("setToll(bytes32,address,uint32)", orderHash, sharks[i], String(tollBps));
  bound.push({ address: sharks[i].toLowerCase(), boundTo: w.address, markoutBps: w.toxicityBps, venuesActive: w.venuesActive, tollBps, toxic: true });
  console.log(`[agent] TOLL ${(tollBps / 1e7).toFixed(2)}% -> ${sharks[i]}  (reputation ${w.toxicityBps}bps across ${w.venuesActive} AMMs, ${w.address.slice(0, 10)}…)`);
}
console.log(`[agent] done: spread + ${bound.length} toll(s).`);

// 3b. SAME signal defends the Uniswap v4 pool — one oracle, keyed by the v4 PoolId instead of the orderHash.
let v4 = null;
try {
  const v = JSON.parse(readFileSync(join(ROOT, "ui/v4.json"), "utf8"));
  const top = confirmed[0];
  const v4Toll = top ? Math.min(MAX_TOLL_BPS, Math.round(top.toxicityBps * TOLL_PER_MARKOUT_BP)) : 0;
  send("setParams(bytes32,uint32)", v.defendedPoolId, String(spreadBps)); // same oracle (v.oracle === desk oracle)
  if (top) send("setToll(bytes32,address,uint32)", v.defendedPoolId, v.shark, String(v4Toll));
  v4 = { poolId: v.defendedPoolId, hook: v.hook, shark: v.shark, spreadPct: spreadBps / 1e7, tollPct: v4Toll / 1e7,
         boundTo: top ? top.address : null, markoutBps: top ? top.toxicityBps : 0, venuesActive: top ? top.venuesActive : 0 };
  console.log(`[agent] v4: same signal -> Uniswap v4 pool (spread ${(spreadBps / 1e7).toFixed(2)}% + toll ${(v4Toll / 1e7).toFixed(2)}%)`);
} catch (e) { /* v4 not deployed this run — Aqua-only */ }

// 4. Cache analytics for the dashboard (decouples the UI from any live query). `takers` keeps the shape the
//    server expects (address+tollBps+toxic); the Radar leaderboard/market fields drive the new panels.
const analytics = {
  orderHash,
  source: signal.source,
  generatedAt: signal.generatedAt,
  thresholdBps: signal.thresholdBps,
  marketIndex: signal.marketIndex,
  marketMarkoutBps: signal.marketMarkoutBps,
  spreadPct: spreadBps / 1e7,
  venues: signal.venues,
  watchlist: signal.watchlist,
  takers: bound, // the bound sharks (address = desk taker, reputation = its cross-venue identity)
  v4, // the same signal posted to the Uniswap v4 pool (null if v4 not deployed)
};
writeFileSync(join(ROOT, "ui/analytics.json"), JSON.stringify(analytics, null, 2));
console.log(`[agent] wrote ui/analytics.json + radar/out/signal.json`);
