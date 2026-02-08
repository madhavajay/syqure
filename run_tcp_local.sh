#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE="${1:-example/two_party_sum_tcp.codon}"

echo "Running TCP demo: ${EXAMPLE}"
echo "Starting 3 parties on localhost (base port 9000)..."

export SEQURE_CP_IPS="127.0.0.1,127.0.0.1,127.0.0.1"

cleanup() {
  kill $PID0 $PID1 $PID2 2>/dev/null || true
  wait $PID0 $PID1 $PID2 2>/dev/null || true
}
trap cleanup EXIT

cd "$SCRIPT_DIR"

cargo run -p syqure -- "${EXAMPLE}" -- 0 2>&1 | sed 's/^/[CP0] /' &
PID0=$!

sleep 0.5

cargo run -p syqure -- "${EXAMPLE}" -- 1 2>&1 | sed 's/^/[CP1] /' &
PID1=$!

cargo run -p syqure -- "${EXAMPLE}" -- 2 2>&1 | sed 's/^/[CP2] /' &
PID2=$!

echo "PIDs: CP0=$PID0 CP1=$PID1 CP2=$PID2"
wait $PID0 $PID1 $PID2
echo "Done."
