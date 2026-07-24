// Baywatch Radar — data-source adapter.
//
// One interface, two transports:
//   • mock     — reads the per-venue fixtures (no key, no network) so the whole pipeline runs offline
//   • gateway  — the SAME standardized query (query.graphql) POSTed to The Graph gateway per subgraphId,
//                the identical shape across every AMM. Activated when GRAPH_API_KEY is set.
// The Subgraph MCP (radar/mcp.md) is the 2nd composed Graph product: it discovers/deduces the subgraphIds
// (resolving the null entries in venues.json) and drives the same fan-out interactively. Automated runs use
// the gateway with the same key; the MCP and the gateway share one credential.
//
// Both transports emit the SAME normalized swap shape the scorer expects:
//   { venue, venueName, network, pool, inputTokens:[{id,decimals}], tokenIn, tokenOut,
//     amountIn, amountOut, amountInUSD, amountOutUSD, reserveAmounts, from, timestamp, logIndex }
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));
export const GATEWAY = process.env.GRAPH_GATEWAY || "https://gateway.thegraph.com/api";

export function loadVenues() {
  return JSON.parse(readFileSync(join(HERE, "venues.json"), "utf8")).venues;
}

function loadQuery() {
  return readFileSync(join(HERE, "query.graphql"), "utf8");
}

/** Normalize a raw swap (fixture OR gateway shape) into the scorer shape, tagged with venue metadata.
 *  `live` marks gateway-sourced swaps so the signal can report mock/gateway/hybrid per venue. */
export function normalizeSwap(raw, v, live = false) {
  const inputTokens = (raw.inputTokens || raw.pool?.inputTokens || []).map((t) => ({
    id: String(t.id).toLowerCase(),
    decimals: Number(t.decimals),
    symbol: t.symbol,
  }));
  const idOf = (t) => (typeof t === "string" ? t : t?.id);
  return {
    venue: v.venue,
    venueName: v.name,
    network: v.network || "mainnet",
    pool: String(raw.pool?.id || raw.pool).toLowerCase(),
    inputTokens,
    tokenIn: String(idOf(raw.tokenIn)).toLowerCase(),
    tokenOut: String(idOf(raw.tokenOut)).toLowerCase(),
    amountIn: raw.amountIn,
    amountOut: raw.amountOut,
    amountInUSD: raw.amountInUSD,
    amountOutUSD: raw.amountOutUSD,
    reserveAmounts: raw.reserveAmounts || [],
    from: String(raw.from).toLowerCase(),
    timestamp: Number(raw.timestamp),
    logIndex: Number(raw.logIndex ?? 0),
    live,
  };
}

function loadFixtureSwaps(v) {
  if (!v.fixture) return [];
  const raw = JSON.parse(readFileSync(join(HERE, "fixtures", v.fixture), "utf8"));
  return raw.map((s) => normalizeSwap(s, v, false));
}

/** Mock transport: read each venue's fixture, normalize, and concatenate. */
export function fetchMock() {
  const out = [];
  for (const v of loadVenues()) out.push(...loadFixtureSwaps(v));
  return out;
}

/** One gateway query for one venue; auto-degrades around per-deployment schema drift (a deployment that
 *  predates a selected field gets the query re-run without it — the scorer falls back accordingly). */
async function queryVenue(v, apiKey, query, variables) {
  const url = `${GATEWAY}/${apiKey}/subgraphs/id/${v.subgraphId}`;
  const post = async (q) => {
    const res = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ query: q, variables }),
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return res.json();
  };
  let body = await post(query);
  const missing = (body.errors || []).map((e) => /has no field `(\w+)`/.exec(e.message)?.[1]).filter(Boolean);
  if (missing.length) {
    let degraded = query;
    for (const f of new Set(missing)) degraded = degraded.replace(new RegExp(`^\\s*${f}\\s*$`, "m"), "");
    console.warn(`[radar] ${v.venue}: schema drift, re-querying without: ${[...new Set(missing)].join(", ")}`);
    body = await post(degraded);
  }
  if (body.errors) throw new Error(JSON.stringify(body.errors).slice(0, 200));
  return body.data?.swaps || [];
}

/** Gateway transport with PER-VENUE fixture fallback: every venue answers — live when its deployment is
 *  servable, from its fixture otherwise (tagged, so the signal reports gateway/hybrid/mock honestly). */
export async function fetchGateway({ apiKey, first = 1000, windowSecs = 3600 } = {}) {
  if (!apiKey) throw new Error("fetchGateway needs an apiKey (GRAPH_API_KEY)");
  const query = loadQuery();
  const minTs = Math.floor(Date.now() / 1000) - windowSecs;
  const out = [];
  for (const v of loadVenues()) {
    if (v.subgraphId) {
      try {
        const swaps = await queryVenue(v, apiKey, query, { first, minTs: String(minTs) });
        if (swaps.length) {
          for (const s of swaps) out.push(normalizeSwap(s, v, true));
          console.log(`[radar] ${v.venue}: ${swaps.length} LIVE swaps`);
          continue;
        }
        console.warn(`[radar] ${v.venue}: live but 0 swaps in window — using fixture`);
      } catch (e) {
        console.warn(`[radar] ${v.venue}: gateway failed (${e.message.slice(0, 120)}) — using fixture`);
      }
    } else {
      console.warn(`[radar] ${v.venue}: no subgraphId — using fixture (resolve via MCP, see mcp.md)`);
    }
    out.push(...loadFixtureSwaps(v));
  }
  return out;
}

/** Dispatch: gateway when a key is present (or source:"gateway"), else the offline fixtures. */
export async function fetchSwaps({ source, apiKey = process.env.GRAPH_API_KEY, ...opts } = {}) {
  const useGateway = source === "gateway" || (source !== "mock" && apiKey);
  if (useGateway) return fetchGateway({ apiKey, ...opts });
  return fetchMock();
}

// ---- funding edges (the 2nd data source: transfers / Token-API) -----------------
// Funding edges are NOT in the DEX-AMM swap schema — they come from a transfers subgraph / Token-API / a
// Substreams module (the composed 2nd Graph product) that indexes ERC-20 + native value transfers. The
// scorer stays transport-agnostic: same normalized edge shape from the fixture or the live source.

/** Normalize a raw funding transfer (fixture OR gateway shape) into the provenance edge shape. */
export function normalizeFunding(raw) {
  return {
    to: String(raw.to).toLowerCase(),
    from: String(raw.from).toLowerCase(),
    token: raw.token != null ? String(raw.token) : undefined,
    valueUsd: raw.valueUsd != null ? Number(raw.valueUsd) : undefined,
    timestamp: raw.timestamp != null ? Number(raw.timestamp) : undefined,
  };
}

/** Mock transport: read fixtures/funding.json (optional — absent file ⇒ no provenance, fail-open). */
export function fetchFundingMock() {
  const p = join(HERE, "fixtures", "funding.json");
  if (!existsSync(p)) return [];
  return JSON.parse(readFileSync(p, "utf8")).filter((e) => e && e.to && e.from).map(normalizeFunding);
}

/** Gateway transport: a recent-transfers query against a transfers/Token-API subgraph (GRAPH_FUNDING_SUBGRAPH).
 *  The exact `transfers` field/shape depends on the chosen source; this is the canonical recent-window form. */
export async function fetchFundingGateway({ apiKey, fundingSubgraph, first = 1000, windowSecs = 86_400 } = {}) {
  if (!apiKey || !fundingSubgraph) throw new Error("fetchFundingGateway needs apiKey + fundingSubgraph");
  const minTs = Math.floor(Date.now() / 1000) - windowSecs;
  const query = `query($first:Int!,$minTs:BigInt!){ transfers(first:$first, orderBy:timestamp, orderDirection:desc, where:{timestamp_gte:$minTs}){ to from value timestamp } }`;
  const url = `${GATEWAY}/${apiKey}/subgraphs/id/${fundingSubgraph}`;
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ query, variables: { first, minTs: String(minTs) } }),
  });
  if (!res.ok) { console.warn(`[radar] funding HTTP ${res.status}`); return []; }
  const body = await res.json();
  if (body.errors) { console.warn(`[radar] funding query errors:`, JSON.stringify(body.errors).slice(0, 200)); return []; }
  return (body.data?.transfers || []).map(normalizeFunding);
}

/** Dispatch funding edges: live transfers source when a key + GRAPH_FUNDING_SUBGRAPH are set, else fixtures. */
export async function fetchFunding({ source, apiKey = process.env.GRAPH_API_KEY, fundingSubgraph = process.env.GRAPH_FUNDING_SUBGRAPH, ...opts } = {}) {
  const useGateway = (source === "gateway" || (source !== "mock" && apiKey)) && fundingSubgraph;
  if (useGateway) return fetchFundingGateway({ apiKey, fundingSubgraph, ...opts });
  return fetchFundingMock();
}
