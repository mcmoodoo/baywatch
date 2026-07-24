#!/usr/bin/env bash
# Launch "Baywatch Radar · The Desk" operator console as a SINGLE server.
# Idempotent: frees port 5170 first (kills any prior instance) so instances never accumulate/race.
#   1. ensure anvil (instant-mining) is up  — no external services; the Radar signal is the
#      standardized DEX-AMM subgraph (mock fixtures offline, The Graph gateway when GRAPH_API_KEY is set)
#   2. free :5170
#   3. start one server  ->  http://localhost:5170
set -uo pipefail
cd "$(dirname "$0")/.."
RPC="${RPC:-http://localhost:8545}"

echo "→ ensuring anvil (instant-mining) on $RPC…"
if ! cast block-number --rpc-url "$RPC" >/dev/null 2>&1; then
  anvil --host 0.0.0.0 >/tmp/baywatch-anvil.log 2>&1 &
  for i in $(seq 1 30); do cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.3; done
fi
echo "  anvil block $(cast block-number --rpc-url "$RPC" 2>/dev/null || echo '?')"

echo "→ freeing :5170 (stopping any prior Desk)…"
fuser -k 5170/tcp >/dev/null 2>&1 || true
sleep 1

rm -f ui/server.log
echo "→ starting The Desk → http://localhost:5170"
exec node ui/server.mjs
