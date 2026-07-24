#!/usr/bin/env node
// Baywatch Radar — LIVE-data freshness probe.
//
// The bounty's hard gate is "consume LIVE data from a Graph provider — mocked/static does not qualify."
// The scout flagged that some public Messari DEX deployments read "updated 2 years ago." This probe is the
// FIRST thing to run once GRAPH_API_KEY exists: it asks each candidate deployment for its chain-head via
// `_meta` and decides, per venue, ride-the-public-deployment vs self-deploy-to-Studio.
//
// Run: GRAPH_API_KEY=xxx node radar/probe.mjs
import { loadVenues, GATEWAY } from "./fetch.mjs";

const FRESH_SECS = Number(process.env.FRESH_SECS || 900); // <=15 min behind head = fresh enough for the demo
const META = `{ _meta { block { number timestamp } hasIndexingErrors } }`;

async function probe(v, apiKey) {
  if (!v.subgraphId) return { venue: v.venue, status: "UNRESOLVED", note: `resolve via MCP: "${v.resolve}"` };
  try {
    const res = await fetch(`${GATEWAY}/${apiKey}/subgraphs/id/${v.subgraphId}`, {
      method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ query: META }),
    });
    if (!res.ok) return { venue: v.venue, status: "HTTP_" + res.status };
    const body = await res.json();
    if (body.errors) return { venue: v.venue, status: "QUERY_ERR", note: JSON.stringify(body.errors).slice(0, 120) };
    const m = body.data?._meta;
    if (!m) return { venue: v.venue, status: "NO_META" };
    const lagSecs = Math.floor(Date.now() / 1000) - Number(m.block.timestamp);
    const fresh = !m.hasIndexingErrors && lagSecs <= FRESH_SECS;
    return { venue: v.venue, status: fresh ? "FRESH" : "STALE", block: Number(m.block.number), lagSecs, indexingErrors: m.hasIndexingErrors };
  } catch (e) {
    return { venue: v.venue, status: "ERROR", note: String(e.message).slice(0, 120) };
  }
}

const apiKey = process.env.GRAPH_API_KEY;
if (!apiKey) {
  console.error("GRAPH_API_KEY not set. This probe needs a Graph gateway key (free tier, thegraph.com/studio/apikeys).");
  console.error("Until then the pipeline runs on fixtures: `node radar/signal.mjs`.");
  process.exit(2);
}

const results = await Promise.all(loadVenues().map((v) => probe(v, apiKey)));
console.log(`[probe] freshness threshold ${FRESH_SECS}s\n`);
for (const r of results) {
  const line = r.status === "FRESH" ? `✓ FRESH  (block ${r.block}, ${r.lagSecs}s behind head)`
    : r.status === "STALE" ? `✗ STALE  (block ${r.block}, ${r.lagSecs}s behind${r.indexingErrors ? ", indexing errors" : ""})`
    : `? ${r.status}${r.note ? "  " + r.note : ""}`;
  console.log(`  ${r.venue.padEnd(14)} ${line}`);
}
const fresh = results.filter((r) => r.status === "FRESH").map((r) => r.venue);
const unfresh = results.filter((r) => r.status !== "FRESH").map((r) => r.venue);
console.log(`\n[probe] verdict: ${fresh.length}/${results.length} venues live.`);
if (fresh.length >= 2) console.log(`[probe] RIDE PUBLIC deployments: ${fresh.join(", ")}`);
else console.log(`[probe] SELF-DEPLOY the Messari DEX-AMM subgraph to Studio for: ${unfresh.join(", ")} (guarantees the live-data gate).`);
