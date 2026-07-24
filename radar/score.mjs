// Baywatch Radar — cross-protocol toxic-flow scoring.
//
// Pure, deterministic, dependency-free. Consumes swaps in the **Messari DEX-AMM standardized schema**
// shape (one shape across every AMM) and produces:
//   • per-venue toxicity   — notional-weighted mean adverse-selection markout per AMM (the "breadth" view)
//   • cross-venue watchlist — per `from` address markout aggregated across ALL venues (the reputation the
//                             standardized schema makes possible: one query shape → every AMM at once)
//   • market toxicity index — a single 0..100 gauge over the whole dataset (drives the pool's global spread)
//
// The metric is ORACLE-FREE: execution price comes from the swap's own amounts; the reference price comes
// from the pool's `reserveAmounts` (constant-product mid) at a later swap. USD fields are used ONLY to
// notional-weight, and are guarded against the schema's known zero/stale pricing gaps.
//
// When `fundingEdges` are supplied, a one-hop funding-graph provenance pass (provenance.mjs) augments the
// watchlist: fresh wallets funded by confirmed-toxic addresses inherit a weaker prior — closing the
// rotate-your-wallet evasion the observed-markout watchlist can't see on its own.

import { provenanceFlags, applyProvenance } from "./provenance.mjs";

/** @typedef {{id:string, decimals:number}} TokenRef */
/** @typedef {{
 *   venue:string, network?:string, venueName?:string,
 *   pool:string, inputTokens:TokenRef[],
 *   tokenIn:string, tokenOut:string,
 *   amountIn:string|number, amountOut:string|number,
 *   amountInUSD?:string|number, amountOutUSD?:string|number,
 *   reserveAmounts:(string|number)[],
 *   from:string, timestamp:number, logIndex?:number
 * }} Swap */

// ---- low-level numeric helpers -------------------------------------------------

/** Base-unit (BigInt-string) amount -> human float, applying token decimals. */
export function toUnits(raw, decimals) {
  const n = Number(raw);
  if (!Number.isFinite(n)) return NaN;
  return n / 10 ** decimals;
}

/** Canonical pair ordering: token0 = lexicographically smaller id. Deployment/venue-agnostic so the same
 *  real-world pair is framed identically on every AMM. Returns {token0, token1} as {id, decimals} — or
 *  null when the pool isn't a plain 2-token pair (curve 3pools/metapools etc.): those swaps go unmarked. */
export function canonicalPair(inputTokens) {
  if (!Array.isArray(inputTokens) || inputTokens.length !== 2) return null;
  const [a, b] = inputTokens;
  return a.id.toLowerCase() < b.id.toLowerCase() ? { token0: a, token1: b } : { token0: b, token1: a };
}

/** Reserve-implied MID price of token0 in units of token1 (r1/r0, decimal-adjusted). Oracle-free. */
export function impliedMidPrice(swap) {
  const pair = canonicalPair(swap.inputTokens);
  if (!pair) return NaN;
  const { token0, token1 } = pair;
  const idx = swap.inputTokens.map((t) => t.id.toLowerCase());
  const r0 = toUnits(swap.reserveAmounts[idx.indexOf(token0.id.toLowerCase())], token0.decimals);
  const r1 = toUnits(swap.reserveAmounts[idx.indexOf(token1.id.toLowerCase())], token1.decimals);
  if (!(r0 > 0) || !(r1 > 0)) return NaN;
  return r1 / r0;
}

/** The taker's EXECUTION price of token0 in token1 (average fill from the actual amounts), plus the side:
 *  side = +1 if the taker BOUGHT token0, -1 if they SOLD token0. Oracle-free. Swaps whose legs don't match
 *  the pool's 2-token frame (metapool underlying, exotic routing) return {NaN, 0} and go unmarked. */
export function executionPrice(swap) {
  const pair = canonicalPair(swap.inputTokens);
  if (!pair) return { price0: NaN, side: 0 };
  const { token0 } = pair;
  const tin = swap.tokenIn.toLowerCase();
  const tokIn = swap.inputTokens.find((t) => t.id.toLowerCase() === tin);
  const tokOut = swap.inputTokens.find((t) => t.id.toLowerCase() === swap.tokenOut.toLowerCase());
  if (!tokIn || !tokOut || tokIn === tokOut) return { price0: NaN, side: 0 };
  const amtIn = toUnits(swap.amountIn, tokIn.decimals);
  const amtOut = toUnits(swap.amountOut, tokOut.decimals);
  if (!(amtIn > 0) || !(amtOut > 0)) return { price0: NaN, side: 0 };
  if (tin === token0.id.toLowerCase()) {
    // sold token0, received token1 -> price0 = token1 out per token0 in
    return { price0: amtOut / amtIn, side: -1 };
  }
  // paid token1, received token0 -> price0 = token1 in per token0 out
  return { price0: amtIn / amtOut, side: +1 };
}

/** Notional (USD) of a swap for weighting. Prefers the schema's USD fields; guards the known zero/stale
 *  pricing gaps by falling back to the other USD leg, then to 0 (caller drops zero-notional swaps). */
export function notionalUsd(swap) {
  const inUsd = Number(swap.amountInUSD ?? 0);
  const outUsd = Number(swap.amountOutUSD ?? 0);
  const best = Math.max(Number.isFinite(inUsd) ? inUsd : 0, Number.isFinite(outUsd) ? outUsd : 0);
  return best > 0 ? best : 0;
}

// ---- markout -------------------------------------------------------------------

/** Signed adverse-selection markout in bps for one swap, given the reference (later) mid price.
 *  Positive = price moved in the TAKER's favor after the trade = informed/toxic flow (bad for the LP). */
export function markoutBps(execPrice0, side, refMid0) {
  if (!(execPrice0 > 0) || !(refMid0 > 0) || side === 0) return NaN;
  return (side * (refMid0 - execPrice0)) / execPrice0 * 10_000;
}

/** Attach a per-swap markout to every swap that has a valid later reference in the SAME pool.
 *  Reference = reserve-implied mid at the first swap whose timestamp is >= t + horizonSecs (fallback: the
 *  last later swap in the pool). Swaps with no valid later reference are returned with markout=null. */
export function computeMarkouts(swaps, { horizonSecs = 60 } = {}) {
  const byPool = new Map();
  for (const s of swaps) {
    const key = `${s.venue}:${s.pool.toLowerCase()}`;
    if (!byPool.has(key)) byPool.set(key, []);
    byPool.get(key).push(s);
  }
  const out = [];
  for (const poolSwaps of byPool.values()) {
    const ordered = [...poolSwaps].sort((a, b) => (a.timestamp - b.timestamp) || ((a.logIndex ?? 0) - (b.logIndex ?? 0)));
    for (let i = 0; i < ordered.length; i++) {
      const s = ordered[i];
      const { price0, side } = executionPrice(s);
      // pick the reference: first later swap >= horizon away, else the last later swap
      let ref = null;
      for (let j = i + 1; j < ordered.length; j++) {
        if (ordered[j].timestamp >= s.timestamp + horizonSecs) { ref = ordered[j]; break; }
        ref = ordered[j];
      }
      // Reference mid: reserve-implied when the deployment carries reserveAmounts; otherwise fall back to
      // the reference trade's own execution price (some live deployments predate the field — see venues.json).
      let refMid = ref ? impliedMidPrice(ref) : NaN;
      if (ref && !(refMid > 0)) refMid = executionPrice(ref).price0;
      const mk = markoutBps(price0, side, refMid);
      out.push({ ...s, execPrice0: price0, side, refMid0: refMid, markoutBps: Number.isFinite(mk) ? mk : null });
    }
  }
  return out;
}

// ---- aggregation ---------------------------------------------------------------

/** Notional-weighted mean of {markoutBps, notional}. Returns {bps, notionalUsd, swaps}. */
function weightedMarkout(rows) {
  let wsum = 0, w = 0, n = 0;
  for (const r of rows) {
    if (r.markoutBps == null) continue;
    const notional = notionalUsd(r);
    if (notional <= 0) continue;
    wsum += r.markoutBps * notional;
    w += notional;
    n++;
  }
  return { bps: w > 0 ? wsum / w : 0, notionalUsd: w, swaps: n };
}

/** Per-venue toxicity leaderboard (the breadth view — one query shape, ranked across every AMM). */
export function scoreVenues(marked) {
  const byVenue = new Map();
  for (const r of marked) {
    if (!byVenue.has(r.venue)) byVenue.set(r.venue, []);
    byVenue.get(r.venue).push(r);
  }
  const venues = [];
  for (const [venue, rows] of byVenue) {
    const wm = weightedMarkout(rows);
    venues.push({
      venue,
      name: rows[0].venueName || venue,
      network: rows[0].network || "mainnet",
      live: rows.some((r) => r.live === true),
      toxicityBps: round2(wm.bps),
      notionalUsd: round2(wm.notionalUsd),
      swaps: wm.swaps,
    });
  }
  venues.sort((a, b) => b.toxicityBps - a.toxicityBps);
  venues.forEach((v, i) => (v.rank = i + 1));
  return venues;
}

/** Cross-venue toxic-address watchlist: aggregate each `from` address's markout across ALL venues. This is
 *  the reputation the standardized schema unlocks — an address's behavior on EVERY AMM in one shape. An
 *  address qualifies as toxic when its notional-weighted markout exceeds `thresholdBps`; `minVenues` (>=2)
 *  requires cross-venue confirmation so a single-venue fluke doesn't get flagged. */
export function crossVenueWatchlist(marked, { thresholdBps = 15, minVenues = 2 } = {}) {
  const byAddr = new Map();
  for (const r of marked) {
    const a = r.from.toLowerCase();
    if (!byAddr.has(a)) byAddr.set(a, []);
    byAddr.get(a).push(r);
  }
  const list = [];
  for (const [address, rows] of byAddr) {
    const wm = weightedMarkout(rows);
    const venuesActive = new Set(rows.filter((r) => r.markoutBps != null).map((r) => r.venue)).size;
    list.push({
      address,
      toxicityBps: round2(wm.bps),
      venuesActive,
      swaps: wm.swaps,
      notionalUsd: round2(wm.notionalUsd),
      toxic: wm.bps > thresholdBps && venuesActive >= minVenues,
    });
  }
  list.sort((a, b) => b.toxicityBps - a.toxicityBps);
  return list;
}

/** Market toxicity index: whole-dataset notional-weighted markout mapped to 0..100. `fullScaleBps` is the
 *  markout that reads as "100" (maximally toxic regime). Negative aggregate markout (benign) clamps to 0. */
export function marketIndex(marked, { fullScaleBps = 40 } = {}) {
  const wm = weightedMarkout(marked);
  const idx = Math.max(0, Math.min(100, (wm.bps / fullScaleBps) * 100));
  return { markoutBps: round2(wm.bps), index: round2(idx), notionalUsd: round2(wm.notionalUsd), swaps: wm.swaps };
}

function round2(x) { return Number.isFinite(x) ? Math.round(x * 100) / 100 : 0; }

// ---- top-level signal builder --------------------------------------------------

/** Latest timestamp across all data — the deterministic "now" for recency when none is passed in. */
function latestTimestamp(swaps, fundingEdges) {
  let m = 0;
  for (const s of swaps) if (s.timestamp > m) m = s.timestamp;
  for (const e of fundingEdges) if (Number(e.timestamp) > m) m = Number(e.timestamp);
  return m || undefined;
}

/** Build the full Radar signal from raw standardized-schema swaps.
 *  `opts.fundingEdges` (optional) enables the one-hop provenance pass; `opts.provenance` overrides its knobs;
 *  `opts.nowSecs` sets the recency clock (defaults to the latest timestamp in the data, keeping it pure). */
export function buildSignal(swaps, opts = {}) {
  const { horizonSecs = 60, thresholdBps = 15, minVenues = 2, fullScaleBps = 40,
          fundingEdges = [], nowSecs, provenance = {} } = opts;
  const marked = computeMarkouts(swaps, { horizonSecs });
  const venues = scoreVenues(marked);
  let watchlist = crossVenueWatchlist(marked, { thresholdBps, minVenues });

  // One-hop funding-graph provenance: fresh wallets funded by confirmed-toxic addresses inherit a prior.
  let provFlags = [];
  if (fundingEdges && fundingEdges.length) {
    const now = nowSecs ?? latestTimestamp(swaps, fundingEdges);
    provFlags = provenanceFlags(watchlist, fundingEdges, { nowSecs: now, ...provenance });
    watchlist = applyProvenance(watchlist, provFlags);
  }

  const market = marketIndex(marked, { fullScaleBps });
  return {
    schema: "messari/dex-amm",
    horizonSecs,
    thresholdBps,
    marketMarkoutBps: market.markoutBps,
    marketIndex: market.index,
    totalSwaps: marked.length,
    markedSwaps: marked.filter((r) => r.markoutBps != null).length,
    venues,
    watchlist,
    provenanceFlags: provFlags,
  };
}
