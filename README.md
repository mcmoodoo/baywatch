# Baywatch Radar

**A self-defending Aqua market maker that prices toxic flow across the entire DEX landscape.**

One off-chain agent runs *one standardized query* across every major AMM (on The Graph's Messari DEX-AMM
schema), scores each venue's adverse-selection **markout**, and feeds that live signal on-chain — where custom
1inch **SwapVM** opcodes re-price and toll the swap through **Aqua** as a real ERC-20 transfer.

> Delete the Radar query and the pool stops defending itself. The cross-protocol data is the product, not a
> dashboard bolted on top.

Built for two ETHGlobal Lisbon tracks that share one causal loop:

- **The Graph — Best Use of Composable or Standardized Graph Products.** Composes **two** Graph products
  (a Standardized Subgraph + the Subgraph MCP) over live data.
- **1inch — Build an Aqua App.** Custom SwapVM opcodes power an "advanced AMM"; the demo settles a real
  on-chain token transfer.

---

## The loop

```
 The Graph                          off-chain (deterministic, no LLM)                 on-chain (anvil)
┌────────────────────────┐         ┌───────────────────────────────┐        ┌───────────────────────────┐
│ Messari DEX-AMM schema  │  one    │ radar/score.mjs               │        │ ParamOracle               │
│  · Uniswap V2           │ query   │  reserve-implied markout      │ cast   │  spread / per-taker toll  │
│  · SushiSwap            │ ──────▶ │  · per-venue toxicity         │ ─────▶ │           │               │
│  · Curve                │ shape   │  · cross-venue reputation     │ send   │           ▼               │
│  · Balancer …           │ fanned  │  · market toxicity index      │        │ SwapVM opcodes reprice    │
│ (Subgraph MCP fan-out)  │         │ agent/agent.mjs               │        │ Aqua pull/push (ERC-20)   │
└────────────────────────┘         └───────────────────────────────┘        └───────────────────────────┘
```

Two signals, mapped onto opcodes that already exist:

| Radar signal | → | On-chain effect (opcode) |
|---|---|---|
| **market toxicity index** (whole-DEX markout) | → | global spread — `_loadParamsXD` |
| **cross-venue reputation** (an address adverse on ≥2 AMMs) | → | per-taker toll — `_toxicFlowToll` |
| operator depeg control | → | regime / halt — `_depegCircuitBreaker` |

## Why this is *composable / standardized* (the Graph track, in one breath)

- **One query shape, every AMM.** `radar/query.graphql` is written once against the standardized Messari
  DEX-AMM schema and runs unchanged across Uniswap/Sushi/Curve/Balancer/…. **Adding a venue is a line in
  `radar/venues.json` — zero code.** That's the entire "what became easier" story the rubric asks for.
- **Two Graph products composed.** Standardized Subgraph (the shared schema) **+** Subgraph MCP (discovers
  deployments and orchestrates the cross-venue fan-out — see [`radar/mcp.md`](radar/mcp.md)). One gateway API
  key powers both.
- **Live data, gated.** [`radar/probe.mjs`](radar/probe.mjs) checks each deployment's `_meta` chain-head
  freshness and decides ride-public vs self-deploy — so the "live data" qualification is enforced, not
  assumed.
- **Breadth = the point.** The output is a cross-protocol toxicity leaderboard: which AMMs are getting picked
  off, and which addresses are toxic across the whole landscape.

The metric is **oracle-free**: execution price comes from each swap's own amounts; the reference mid comes
from `reserveAmounts`; the schema's USD fields are used only to notional-weight (and guarded against its known
zero/stale pricing gaps).

## One signal, two defended venues (Uniswap v4)

The ParamOracle is keyed by `bytes32`, so a Uniswap v4 `PoolId` slots in exactly where the SwapVM `orderHash`
does — the same Graph-fetched signal defends **two venues** with zero oracle changes:

| Radar signal | 1inch Aqua (SwapVM opcodes) | Uniswap v4 ([`BaywatchV4Hook`](src/v4/BaywatchV4Hook.sol)) |
|---|---|---|
| market toxicity index | global spread (`_loadParamsXD`) | dynamic LP-fee override (`beforeSwap`) |
| cross-venue reputation | per-taker toll (`_toxicFlowToll`) | per-swapper fee surcharge |
| depeg regime | halt / one-directional (`_depegCircuitBreaker`) | revert / one-directional |

The hook resolves the real swapper through Uniswap's **official `IMsgSender` pattern** (trusted-router
allowlist — the Universal Router implements it), and an unknown router is simply its own identity: toll the
router once *it* earns a reputation. Fail semantics mirror the opcodes: spread fails **safe** to the max
defensive fee, the personal toll fails **open**, so a dead agent can never over-charge honest flow.
`test/BaywatchV4Hook.t.sol` proves it against a real deployed `PoolManager`: same pool, same trade, same block —
the shark is surcharged 366bps over the tourist by one oracle write.

## Run it — offline, no key

Everything runs on **mock fixtures** (real Messari-schema shape) so the whole loop is provable with nothing to
provision:

```bash
bash radar/e2e.sh          # unit tests + contract tests + live closed loop on anvil (deploy→agent→verify)
bash ui/desk.sh            # the operator console → http://localhost:5170
```

`radar/e2e.sh` proves, end to end:

```
standardized DEX-AMM subgraph (mock) → Radar markout → ParamOracle → per-taker on-chain reprice
  market index 88.63/100 → 2.67% spread
  SHARK  (36bps across 2 AMMs) → 3.63% toll → surcharged 362 bps vs a tourist, on-chain
  SHARK3 (30bps across 2 AMMs) → 2.97% toll → surcharged 296 bps vs a tourist, on-chain
```

**The Desk** (`ui/`) drives two real Aqua pools on identical flow — a DEFENDED order (full program) and a
NAÏVE x*y=k order — so the divergence *is* the edge the defense earned, with the cross-protocol radar,
market-index gauge, and toxic-address watchlist live over SSE.

## Run it — live data (with a key)

```bash
export GRAPH_API_KEY=<free key from thegraph.com/studio/apikeys>   # 100k queries/mo, ~$0
node radar/probe.mjs       # which standardized deployments are live (ride-public vs self-deploy)
node radar/signal.mjs      # fan the standardized query across live venues → toxicity leaderboard
bash radar/e2e.sh          # same closed loop, now on live data
```

The only code that changes between mock and live is the transport in `radar/fetch.mjs`; the scorer, agent,
opcodes, and UI are identical.

## Tests

```bash
node --test radar/test/*.test.mjs   # 9 — scoring primitives + cross-venue separation (deterministic)
forge test                          # 15 — SwapVM opcode invariants (quote==swap, markout toll, breaker)
```

## Repo map

```
radar/            the Graph half — standardized query, scoring, fan-out, freshness probe
  score.mjs         reserve-implied markout → per-venue / cross-venue / market index (pure, tested)
  query.graphql     the ONE standardized query (Messari DEX-AMM), fanned across every AMM
  fetch.mjs         mock (fixtures) + gateway/MCP transport, one normalized shape
  venues.json       candidate deployments (real Curve/Balancer IDs; others resolve via MCP)
  probe.mjs         _meta freshness gate (live-data qualification)
  fixtures/         multi-venue swaps in real schema shape (SHARK cross-venue, SHARK2 gated, tourists)
  e2e.sh · mcp.md   headless proof · the Subgraph-MCP composition
src/              the 1inch half — SharedAquaRouter + custom SwapVM opcodes + ParamOracle + LpStrategy
  v4/               the Uniswap half — BaywatchV4Hook (same oracle, same signal, v4 dynamic fees + breaker)
agent/agent.mjs   Radar signal → ParamOracle (spread + per-taker tolls)
ui/               The Desk operator console (server.mjs + index.html)
script/           DeployDesk / FlowStep / VerifyDesk (the two-pool demo on anvil)
```
