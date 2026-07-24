// Baywatch Radar scoring — unit tests. Run: node --test radar/test/
import { test } from "node:test";
import assert from "node:assert/strict";

import { impliedMidPrice, executionPrice, markoutBps, buildSignal } from "../score.mjs";
import { fetchMock } from "../fetch.mjs";

const SHARK = "0x5111111111111111111111111111111111111151";
const SHARK2 = "0x5222222222222222222222222222222222222252";
const SHARK3 = "0x5333333333333333333333333333333333333353";
const TOUR1 = "0x7111111111111111111111111111111111111171";
const TOUR2 = "0x7222222222222222222222222222222222222272";

const swaps = fetchMock();
const uniS0 = swaps.find((s) => s.venue === "uniswap-v2" && s.from === SHARK && s.timestamp === 1700000000);

// ---- exact primitives (hand-computed) ----
test("impliedMidPrice: reserves 1000 A / 2,000,000 B -> mid 2000 (B per A)", () => {
  assert.equal(impliedMidPrice(uniS0), 2000);
});

test("executionPrice: SHARK buys 20 A for 40,000 B -> price0 2000, side +1 (bought token0)", () => {
  const { price0, side } = executionPrice(uniS0);
  assert.equal(price0, 2000);
  assert.equal(side, 1);
});

test("markoutBps: exec 2000, side +1, ref 2008 -> +40 bps", () => {
  assert.equal(markoutBps(2000, 1, 2008), 40);
});

test("markoutBps: a seller (side -1) into a rising market is NEGATIVE (not toxic)", () => {
  assert.ok(markoutBps(2000, -1, 2010) < 0);
});

// ---- signal over the 4-venue fixtures ----
const sig = buildSignal(swaps);
const wl = Object.fromEntries(sig.watchlist.map((w) => [w.address, w]));

test("signal is deterministic", () => {
  assert.deepEqual(buildSignal(fetchMock()), sig);
});

test("market toxicity: positive markout, index in (0,100]", () => {
  assert.ok(sig.marketMarkoutBps > 15, `marketMarkoutBps=${sig.marketMarkoutBps}`);
  assert.ok(sig.marketIndex > 0 && sig.marketIndex <= 100, `marketIndex=${sig.marketIndex}`);
});

test("venue leaderboard: ranked desc; toxic AMMs on top, benign at bottom", () => {
  const byRank = sig.venues;
  assert.equal(byRank[0].venue, "uniswap-v2");
  assert.equal(byRank[byRank.length - 1].venue, "balancer-v2");
  const tox = Object.fromEntries(sig.venues.map((v) => [v.venue, v.toxicityBps]));
  assert.ok(tox["uniswap-v2"] > 15 && tox["sushiswap"] > 15, "toxic venues > 15bps");
  assert.ok(tox["curve"] > tox["balancer-v2"], "curve less negative than balancer");
  assert.ok(tox["uniswap-v2"] > tox["curve"], "toxic > benign");
  // ranks are 1..N in order
  byRank.forEach((v, i) => assert.equal(v.rank, i + 1));
});

test("cross-venue reputation: SHARK toxic (2 venues); SHARK2 gated out (1 venue); tourists benign", () => {
  assert.equal(wl[SHARK].toxic, true);
  assert.equal(wl[SHARK].venuesActive, 2);
  assert.ok(wl[SHARK].toxicityBps > 15);

  // SHARK2 IS positive-markout but only on ONE venue -> the minVenues=2 confirmation gate rejects it.
  assert.equal(wl[SHARK2].venuesActive, 1);
  assert.equal(wl[SHARK2].toxic, false);

  assert.equal(wl[TOUR1].toxic, false);
  assert.equal(wl[TOUR2].toxic, false);
});

test("only the cross-venue-confirmed addresses survive as toxic: SHARK + SHARK3 (not SHARK2)", () => {
  const toxic = new Set(sig.watchlist.filter((w) => w.toxic).map((w) => w.address));
  assert.deepEqual(toxic, new Set([SHARK, SHARK3]));
  assert.equal(wl[SHARK3].toxic, true);
  assert.equal(wl[SHARK3].venuesActive, 2);
});
