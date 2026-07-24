#!/usr/bin/env node
// Baywatch Radar — signal orchestrator. Fetch standardized-schema swaps across every AMM (mock fixtures with
// no key; The Graph gateway when GRAPH_API_KEY is set), score them, and write radar/out/signal.json — the
// typed contract the on-chain agent consumes. Run: node radar/signal.mjs   (add GRAPH_API_KEY for live data)
import { mkdirSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

import { fetchSwaps, fetchFunding } from "./fetch.mjs";
import { buildSignal } from "./score.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));

export async function generate(opts = {}) {
  // RADAR_SOURCE=mock forces the deterministic fixture demo even when a key is present.
  const source = opts.source || process.env.RADAR_SOURCE || undefined;
  const swaps = await fetchSwaps({ ...opts, source });
  const fundingEdges = await fetchFunding({ ...opts, source });
  // Report what actually happened, per the swap tags: all live -> gateway, none -> mock, else hybrid.
  const liveCount = swaps.filter((s) => s.live).length;
  const actual = liveCount === 0 ? "mock" : liveCount === swaps.length ? "gateway" : "hybrid";
  const signal = { source: actual, generatedAt: Math.floor(Date.now() / 1000), ...buildSignal(swaps, { ...opts, fundingEdges }) };
  return signal;
}

// CLI
if (import.meta.url === `file://${process.argv[1]}`) {
  const signal = await generate();
  mkdirSync(join(HERE, "out"), { recursive: true });
  writeFileSync(join(HERE, "out/signal.json"), JSON.stringify(signal, null, 2));
  const toxic = signal.watchlist.filter((w) => w.toxic);
  console.log(`[radar] source=${signal.source}  swaps=${signal.totalSwaps} (marked ${signal.markedSwaps})`);
  console.log(`[radar] MARKET toxicity index ${signal.marketIndex}/100  (${signal.marketMarkoutBps}bps)`);
  console.log(`[radar] venue leaderboard:`);
  for (const v of signal.venues) console.log(`   #${v.rank} ${v.live ? "🟢" : "⚪"} ${v.name.padEnd(16)} ${String(v.toxicityBps).padStart(8)}bps  ($${Math.round(v.notionalUsd).toLocaleString()}, ${v.swaps} swaps${v.live ? ", LIVE" : ", sim"})`);
  console.log(`[radar] cross-venue toxic watchlist (${toxic.length}):`);
  for (const w of toxic) {
    const tag = w.provenance ? `provenance ← funded by ${w.fundedBy.slice(0, 10)}…` : `observed across ${w.venuesActive} venues`;
    console.log(`   ${w.address}  ${w.toxicityBps}bps  (${tag})`);
  }
  const prov = signal.provenanceFlags || [];
  if (prov.length) console.log(`[radar] provenance: ${prov.length} fresh wallet(s) flagged one-hop from a toxic funder`);
  console.log(`[radar] wrote radar/out/signal.json`);
}
