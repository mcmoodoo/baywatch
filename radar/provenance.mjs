// Baywatch Radar — one-hop funding-graph provenance.
//
// The markout watchlist only flags addresses with observed cross-venue history, so a FRESH wallet a shark
// spins up and funds has no reputation → it trades toll-free (the opcode fails open). This closes the
// cheapest evasion: propagate suspicion ONE HOP backward along funding edges. A wallet funded DIRECTLY by a
// confirmed-toxic address inherits a PRIOR on its first trade — a synthetic "inherited markout" that observed
// behavior later confirms or decays. The prior is deliberately WEAKER than an observed signal
// (`inheritFraction` < 1), recency-weighted (snipers fund-then-attack fast), and guarded against infra
// fan-out (a CEX / bridge / router funds thousands of wallets → never inherit from it).
//
// Data note: funding edges are NOT in the Messari DEX-AMM swap schema. They come from a transfers / Token-API
// source (the 2nd composed Graph product — see fetch.mjs). Normalized shape:
//   { to, from, token?, valueUsd?, timestamp }

/** @typedef {{ to:string, from:string, token?:string, valueUsd?:number, timestamp?:number }} FundingEdge */

function round2(x) { return Number.isFinite(x) ? Math.round(x * 100) / 100 : 0; }

/** Recency weight in [0,1]: 1 at t=now, halving every `halfLifeSecs`. Missing/future time → 1 (no decay). */
export function recencyWeight(edgeTs, nowSecs, halfLifeSecs) {
  if (!(edgeTs > 0) || !(nowSecs > 0) || !(halfLifeSecs > 0)) return 1;
  const age = nowSecs - edgeTs;
  if (age <= 0) return 1; // funded at/after "now" → full weight
  return Math.pow(0.5, age / halfLifeSecs);
}

/** One-hop funding-graph provenance flags.
 *  seed = the markout-confirmed toxic addresses (watchlist rows with `toxic` and no prior provenance tag).
 *  For every address funded DIRECTLY by a seed address through a QUALIFYING edge, emit a provenance flag
 *  carrying an inherited-markout prior. Qualifying = funder is seed, not infra, not high-fan-out, and the
 *  edge is recent enough that the inherited prior clears `minInheritBps`. */
export function provenanceFlags(watchlist, fundingEdges, {
  inheritFraction = 0.5,        // a prior is worth HALF the funder's confirmed signal
  halfLifeSecs    = 86_400,     // funding older than ~a day decays fast
  maxFanOut       = 8,          // funders bankrolling > this many distinct wallets look like infra
  minInheritBps   = 1,          // drop fully-decayed / negligible inheritances
  infraAllowlist  = new Set(),  // known CEX / bridge / router / mixer addrs → never inherit from
  nowSecs,
} = {}) {
  const infra = infraAllowlist instanceof Set
    ? new Set([...infraAllowlist].map((a) => String(a).toLowerCase()))
    : new Set([...(infraAllowlist || [])].map((a) => String(a).toLowerCase()));

  // seed: confirmed-toxic address → its markout magnitude (bps). Exclude already-provenance rows so a prior
  // can never itself become a seed (no multi-hop laundering through the one-hop check).
  const seed = new Map();
  for (const w of watchlist) {
    if (w.toxic && !w.provenance) seed.set(w.address.toLowerCase(), Math.max(0, Number(w.toxicityBps) || 0));
  }

  // distinct-fundee out-degree per funder → the behavioral infra heuristic (backs up the allowlist).
  const fanOut = new Map();
  for (const e of fundingEdges) {
    const f = String(e.from).toLowerCase();
    if (!fanOut.has(f)) fanOut.set(f, new Set());
    fanOut.get(f).add(String(e.to).toLowerCase());
  }

  // best inherited prior per fundee (strongest qualifying funder wins).
  const best = new Map(); // to → { inheritedMarkoutBps, fundedBy, funderBps, recency }
  for (const e of fundingEdges) {
    const to = String(e.to).toLowerCase();
    const from = String(e.from).toLowerCase();
    if (to === from) continue;
    if (seed.has(to)) continue;                            // observed-toxic already: observation beats a prior
    const funderBps = seed.get(from);
    if (funderBps == null) continue;                       // funder isn't confirmed-toxic → nothing to inherit
    if (infra.has(from)) continue;                         // GUARDRAIL: never inherit from known infra
    if ((fanOut.get(from)?.size ?? 0) > maxFanOut) continue; // GUARDRAIL: high fan-out looks like infra
    const rec = recencyWeight(Number(e.timestamp), nowSecs, halfLifeSecs);
    const inherited = inheritFraction * funderBps * rec;
    if (inherited < minInheritBps) continue;
    const prev = best.get(to);
    if (!prev || inherited > prev.inheritedMarkoutBps) {
      best.set(to, { inheritedMarkoutBps: inherited, fundedBy: from, funderBps, recency: rec });
    }
  }

  const flags = [];
  for (const [address, b] of best) {
    flags.push({
      address,
      inheritedMarkoutBps: round2(b.inheritedMarkoutBps),
      fundedBy: b.fundedBy,
      funderMarkoutBps: round2(b.funderBps),
      recency: round2(b.recency),
      reason: "one-hop-toxic-funding",
    });
  }
  flags.sort((a, b) => b.inheritedMarkoutBps - a.inheritedMarkoutBps);
  return flags;
}

/** Merge provenance flags into a markout watchlist → a NEW augmented watchlist (pure).
 *  A flagged address becomes toxic with `provenance:true`; its `toxicityBps` carries the inherited prior so
 *  the agent's existing markout→toll mapping tolls it uniformly, just weaker. An address that is ALREADY
 *  observed-toxic is never downgraded (observation always dominates the prior). */
export function applyProvenance(watchlist, flags) {
  const byAddr = new Map(watchlist.map((w) => [w.address.toLowerCase(), { ...w }]));
  for (const f of flags) {
    const a = f.address.toLowerCase();
    const existing = byAddr.get(a);
    if (existing) {
      existing.provenance = true;
      existing.fundedBy = f.fundedBy;
      existing.inheritedMarkoutBps = f.inheritedMarkoutBps;
      existing.reason = f.reason;
      existing.toxic = true; // a prior can only ADD suspicion, never clear it
      if (f.inheritedMarkoutBps > (Number(existing.toxicityBps) || 0)) existing.toxicityBps = f.inheritedMarkoutBps;
    } else {
      byAddr.set(a, {
        address: a,
        toxicityBps: f.inheritedMarkoutBps,
        venuesActive: 0, // fresh wallet — no observed venue activity yet
        swaps: 0,
        notionalUsd: 0,
        toxic: true,
        provenance: true,
        fundedBy: f.fundedBy,
        inheritedMarkoutBps: f.inheritedMarkoutBps,
        reason: f.reason,
      });
    }
  }
  const out = [...byAddr.values()];
  out.sort((a, b) => b.toxicityBps - a.toxicityBps);
  return out;
}
