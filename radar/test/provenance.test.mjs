// Baywatch Radar — one-hop funding-graph provenance. Run: node --test radar/test/*.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";

import { recencyWeight, provenanceFlags, applyProvenance } from "../provenance.mjs";
import { buildSignal } from "../score.mjs";
import { fetchMock, fetchFundingMock } from "../fetch.mjs";

const SHARK  = "0x5111111111111111111111111111111111111151"; // confirmed toxic (uni+sushi)
const SHARK3 = "0x5333333333333333333333333333333333333353"; // confirmed toxic (uni+sushi)
const SHARK2 = "0x5222222222222222222222222222222222222252"; // positive markout, single-venue → NOT toxic
const TOUR1  = "0x7111111111111111111111111111111111111171"; // benign
const GHOST    = "0x6111111111111111111111111111111111111161"; // fresh, funded by SHARK (recent)
const GHOST_T  = "0x6222222222222222222222222222222222222262"; // fresh, funded by TOUR1 (benign funder)
const GHOSTOLD = "0x6333333333333333333333333333333333333363"; // fresh, funded by SHARK (a year ago)
const CEX = "0xcccccccccccccccccccccccccccccccccccccc01";

// A hand-built seed watchlist so the provenance unit is tested in isolation from the markout math.
const SEED = [
  { address: SHARK,  toxicityBps: 36, venuesActive: 2, toxic: true },
  { address: SHARK3, toxicityBps: 30, venuesActive: 2, toxic: true },
  { address: SHARK2, toxicityBps: 20, venuesActive: 1, toxic: false },
];

// ---- recency ----
test("recencyWeight: 1 at now, 0.5 after one half-life, 1 for missing/future time", () => {
  assert.equal(recencyWeight(1000, 1000, 100), 1);
  assert.equal(recencyWeight(900, 1000, 100), 0.5);
  assert.equal(recencyWeight(1100, 1000, 100), 1); // funded after "now" → full weight
  assert.equal(recencyWeight(undefined, 1000, 100), 1);
});

// ---- core: a fresh wallet inherits HALF its toxic funder's signal ----
test("provenanceFlags: GHOST funded by SHARK → inherited prior = 0.5 × 36 bps; benign funder ignored", () => {
  const edges = [
    { to: GHOST,   from: SHARK, timestamp: 1000 },
    { to: GHOST_T, from: TOUR1, timestamp: 1000 }, // TOUR1 not on the seed → no propagation
  ];
  const flags = provenanceFlags(SEED, edges, { nowSecs: 1000, halfLifeSecs: 86_400 });
  assert.equal(flags.length, 1);
  assert.equal(flags[0].address, GHOST);
  assert.equal(flags[0].fundedBy, SHARK);
  assert.equal(flags[0].inheritedMarkoutBps, 18); // 0.5 × 36 × recency(1)
  assert.equal(flags[0].reason, "one-hop-toxic-funding");
});

// ---- guardrail: never inherit from infra (allowlist) ----
test("provenanceFlags: a funder on the infra allowlist never propagates", () => {
  const edges = [{ to: GHOST, from: SHARK, timestamp: 1000 }];
  const flags = provenanceFlags(SEED, edges, { nowSecs: 1000, infraAllowlist: new Set([SHARK]) });
  assert.equal(flags.length, 0);
});

// ---- guardrail: high fan-out looks like infra ----
test("provenanceFlags: maxFanOut gates a funder that bankrolls too many wallets", () => {
  const edges = [
    { to: GHOST,   from: SHARK, timestamp: 1000 },
    { to: "0xd1",  from: SHARK, timestamp: 1000 },
    { to: "0xd2",  from: SHARK, timestamp: 1000 },
  ];
  // SHARK funds 3 distinct wallets; with maxFanOut=2 it reads as a distributor → nothing inherits.
  assert.equal(provenanceFlags(SEED, edges, { nowSecs: 1000, maxFanOut: 2 }).length, 0);
  // With the default cap it propagates to all three.
  assert.ok(provenanceFlags(SEED, edges, { nowSecs: 1000, maxFanOut: 8 }).some((f) => f.address === GHOST));
});

// ---- guardrail: recency decay drops stale funding ----
test("provenanceFlags: funding a year stale decays below minInheritBps → not flagged", () => {
  const edges = [{ to: GHOSTOLD, from: SHARK, timestamp: 1000 }];
  const flags = provenanceFlags(SEED, edges, { nowSecs: 1000 + 20 * 86_400, halfLifeSecs: 86_400, minInheritBps: 1 });
  assert.equal(flags.length, 0); // 0.5 × 36 × 0.5^20 ≈ 1.7e-5 bps « 1
});

// ---- never re-flag an already-observed-toxic address (no laundering through one hop) ----
test("provenanceFlags: a seed→seed funding edge produces no prior (observation dominates)", () => {
  const edges = [{ to: SHARK3, from: SHARK, timestamp: 1000 }];
  assert.equal(provenanceFlags(SEED, edges, { nowSecs: 1000 }).length, 0);
});

// ---- merge semantics ----
test("applyProvenance: adds a fresh flagged wallet as toxic-by-provenance", () => {
  const wl = applyProvenance(SEED, [{ address: GHOST, inheritedMarkoutBps: 18, fundedBy: SHARK, reason: "one-hop-toxic-funding" }]);
  const g = wl.find((w) => w.address === GHOST);
  assert.equal(g.toxic, true);
  assert.equal(g.provenance, true);
  assert.equal(g.venuesActive, 0);
  assert.equal(g.toxicityBps, 18);
});

test("applyProvenance: upgrades a gated single-venue address; never downgrades an observed-toxic one", () => {
  const wl = applyProvenance(SEED, [
    { address: SHARK2, inheritedMarkoutBps: 25, fundedBy: SHARK, reason: "one-hop-toxic-funding" }, // was toxic:false
    { address: SHARK,  inheritedMarkoutBps: 5,  fundedBy: SHARK3, reason: "one-hop-toxic-funding" }, // observed 36 wins
  ]);
  const s2 = wl.find((w) => w.address === SHARK2);
  assert.equal(s2.toxic, true);          // provenance turned the gated address toxic
  assert.equal(s2.toxicityBps, 25);      // raised to the (stronger) prior
  const s1 = wl.find((w) => w.address === SHARK);
  assert.equal(s1.toxicityBps, 36);      // observed signal not lowered by a weaker prior
});

// ---- end-to-end through buildSignal on the real fixtures ----
test("buildSignal + funding fixture: GHOST joins the toxic set via provenance; benign/stale funding does not", () => {
  const swaps = fetchMock();
  const funded = buildSignal(swaps, { fundingEdges: fetchFundingMock() });
  const wl = Object.fromEntries(funded.watchlist.map((w) => [w.address, w]));

  assert.equal(wl[GHOST].toxic, true, "GHOST flagged toxic-by-provenance");
  assert.equal(wl[GHOST].provenance, true);
  assert.equal(wl[GHOST].fundedBy, SHARK);
  assert.ok(wl[GHOST].toxicityBps > 0);
  assert.ok(!wl[GHOST_T], "benign-funded wallet is absent");
  assert.ok(!wl[GHOSTOLD], "stale-funded wallet is absent");
  assert.ok(funded.provenanceFlags.length >= 1);

  // The seed sharks are still there and rank above the weaker inherited prior.
  const toxic = funded.watchlist.filter((w) => w.toxic).map((w) => w.address);
  assert.ok(toxic.includes(SHARK) && toxic.includes(SHARK3) && toxic.includes(GHOST));
  assert.ok(wl[SHARK].toxicityBps > wl[GHOST].toxicityBps, "observed shark out-ranks a provenance prior");
});

test("buildSignal WITHOUT funding is unchanged (provenance is purely additive)", () => {
  const swaps = fetchMock();
  const base = buildSignal(swaps);
  assert.deepEqual(base.provenanceFlags, []);
  const toxic = new Set(base.watchlist.filter((w) => w.toxic).map((w) => w.address));
  assert.deepEqual(toxic, new Set([SHARK, SHARK3]));
});
