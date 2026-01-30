#!/usr/bin/env bash
set -euo pipefail

SYQURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SYQURE_DIR/.." && pwd)"
EXAMPLE_TCP="$SYQURE_DIR/example/two_party_sum_tcp.codon"
EXAMPLE_HE_TCP="$SYQURE_DIR/example/two_party_sum_he_tcp.codon"

MODE="all"
if [ "${1:-}" = "--he" ]; then
  MODE="he"
elif [ "${1:-}" = "--smpc" ]; then
  MODE="smpc"
elif [ -n "${1:-}" ]; then
  echo "Usage: $0 [--he|--smpc]" >&2
  exit 1
fi

if [ ! -f "$EXAMPLE_TCP" ]; then
  echo "Missing $EXAMPLE_TCP" >&2
  exit 1
fi

if [ ! -f "$EXAMPLE_HE_TCP" ]; then
  echo "Missing $EXAMPLE_HE_TCP" >&2
  exit 1
fi

# Use TCP transport and pin all parties to localhost
export SEQURE_CP_IPS="127.0.0.1,127.0.0.1,127.0.0.1"

run_three_parties() {
  local label="$1"
  local source="$2"
  local val1="$3"
  local val2="$4"
  shift 4
  local extra_args=("$@")

  echo "==> Running ${label}"
  local start_ts
  start_ts="$(date +%s)"

  (cd "$SYQURE_DIR" && cargo run -p syqure -- "${extra_args[@]}" "$source" -- 0) &
  p0=$!
  sleep 0.2
  (cd "$SYQURE_DIR" && SEQURE_INPUT="$val1" cargo run -p syqure -- "${extra_args[@]}" "$source" -- 1) &
  p1=$!
  sleep 0.2
  (cd "$SYQURE_DIR" && SEQURE_INPUT="$val2" cargo run -p syqure -- "${extra_args[@]}" "$source" -- 2) &
  p2=$!

  wait "$p0" "$p1" "$p2"

  local end_ts
  end_ts="$(date +%s)"
  echo "==> Done: ${label} in $((end_ts - start_ts))s"
  echo
}

if [ "$MODE" = "all" ] || [ "$MODE" = "smpc" ]; then
  run_three_parties "MPC TCP (two_party_sum_tcp.codon, skip MHE)" "$EXAMPLE_TCP" "${SMPC_VAL1:-5}" "${SMPC_VAL2:-9}" --skip-mhe-setup
fi
if [ "$MODE" = "all" ] || [ "$MODE" = "he" ]; then
  run_three_parties "HE TCP (two_party_sum_he_tcp.codon)" "$EXAMPLE_HE_TCP" "${HE_VAL1:-5.0}" "${HE_VAL2:-9.0}"
fi
