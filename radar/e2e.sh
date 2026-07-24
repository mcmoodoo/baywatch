#!/usr/bin/env bash
# Baywatch Radar — headless end-to-end proof (no Graph key needed, fixtures only).
#   standardized DEX-AMM subgraph (mock) -> Radar markout -> ParamOracle -> on-chain per-taker reprice
# Proves: scoring unit tests, contract tests, and the live closed loop on anvil.
set -uo pipefail
cd "$(dirname "$0")/.."
RPC="${RPC:-http://localhost:8545}"

echo "→ [1/5] Radar scoring unit tests"
node --test radar/test/*.test.mjs >/tmp/radar-unit.log 2>&1 && echo "  ok" || { echo "  FAILED"; tail -20 /tmp/radar-unit.log; exit 1; }

echo "→ [2/5] Baywatch contract tests (forge)"
forge test >/tmp/radar-forge.log 2>&1 && echo "  ok ($(grep -Eo '[0-9]+ tests passed' /tmp/radar-forge.log | tail -1))" || { echo "  FAILED"; tail -20 /tmp/radar-forge.log; exit 1; }

echo "→ [3/5] ensure anvil (instant-mining) on $RPC"
if ! cast block-number --rpc-url "$RPC" >/dev/null 2>&1; then
  echo "  starting anvil…"; anvil --host 0.0.0.0 >/tmp/radar-anvil.log 2>&1 &
  for i in $(seq 1 30); do cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.3; done
fi
echo "  anvil block $(cast block-number --rpc-url "$RPC")"

echo "→ [4/5] deploy two-pool desk + run Radar agent"
forge script script/DeployDesk.s.sol --rpc-url "$RPC" --broadcast --skip-simulation >/tmp/radar-deploy.log 2>&1 \
  && echo "  deployed" || { echo "  DEPLOY FAILED"; tail -20 /tmp/radar-deploy.log; exit 1; }
node agent/agent.mjs || { echo "  AGENT FAILED"; exit 1; }

echo "→ [5/5] verify the toll bites on-chain"
forge script script/VerifyDesk.s.sol --rpc-url "$RPC" 2>&1 | grep -E "closed loop|out |surcharged|PASS|FAIL" \
  || { echo "  VERIFY FAILED"; exit 1; }
echo "✓ Baywatch Radar end-to-end proven."
