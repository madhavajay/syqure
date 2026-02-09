#!/usr/bin/env bash
set -euo pipefail

SYQURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SYQURE_DIR/.." && pwd)"
EXAMPLE_TCP="$SYQURE_DIR/example/two_party_sum_tcp.codon"
EXAMPLE_HE_TCP="$SYQURE_DIR/example/two_party_sum_he_tcp.codon"

MODE="all"
USE_DOCKER=0
while [ $# -gt 0 ]; do
  case "$1" in
    --he)
      MODE="he"
      ;;
    --smpc)
      MODE="smpc"
      ;;
    --docker)
      USE_DOCKER=1
      ;;
    *)
      echo "Usage: $0 [--he|--smpc] [--docker]" >&2
      exit 1
      ;;
  esac
  shift
done

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

run_three_parties_docker() {
  local label="$1"
  local source="$2"
  local val1="$3"
  local val2="$4"
  shift 4
  local extra_args=("$@")

  local runtime="${BIOVAULT_CONTAINER_RUNTIME:-docker}"
  local image="${SYQURE_DOCKER_IMAGE:-ghcr.io/madhavajay/syqure-cli:latest}"
  local platform="${SYQURE_DOCKER_PLATFORM:-linux/amd64}"
  local net="syqure-tcp-$$"
  local c0="syq-tcp-p0-$$"
  local c1="syq-tcp-p1-$$"
  local c2="syq-tcp-p2-$$"
  local subnet="172.29.0.0/24"
  local ip0="172.29.0.2"
  local ip1="172.29.0.3"
  local ip2="172.29.0.4"
  local cp_ips="$ip0,$ip1,$ip2"
  local source_rel="${source#"$SYQURE_DIR/"}"
  local source_in_container="/work/syqure/${source_rel}"

  echo "==> Running ${label} (docker image: ${image})"
  local start_ts
  start_ts="$(date +%s)"

  "$runtime" network create --subnet "$subnet" "$net" >/dev/null
  cleanup() {
    "$runtime" rm -f "$c0" "$c1" "$c2" >/dev/null 2>&1 || true
    "$runtime" network rm "$net" >/dev/null 2>&1 || true
  }
  trap cleanup RETURN

  "$runtime" run -d --name "$c0" --network "$net" --ip "$ip0" --platform "$platform" \
    -e "SEQURE_CP_IPS=$cp_ips" \
    -v "$SYQURE_DIR:/work/syqure:ro" \
    "$image" syqure "${extra_args[@]}" "$source_in_container" -- 0 >/dev/null
  sleep 0.2
  "$runtime" run -d --name "$c1" --network "$net" --ip "$ip1" --platform "$platform" \
    -e "SEQURE_CP_IPS=$cp_ips" \
    -e "SEQURE_INPUT=$val1" \
    -v "$SYQURE_DIR:/work/syqure:ro" \
    "$image" syqure "${extra_args[@]}" "$source_in_container" -- 1 >/dev/null
  sleep 0.2
  "$runtime" run -d --name "$c2" --network "$net" --ip "$ip2" --platform "$platform" \
    -e "SEQURE_CP_IPS=$cp_ips" \
    -e "SEQURE_INPUT=$val2" \
    -v "$SYQURE_DIR:/work/syqure:ro" \
    "$image" syqure "${extra_args[@]}" "$source_in_container" -- 2 >/dev/null

  local rc0 rc1 rc2
  rc0=$("$runtime" wait "$c0")
  rc1=$("$runtime" wait "$c1")
  rc2=$("$runtime" wait "$c2")
  if [ "$rc0" -ne 0 ] || [ "$rc1" -ne 0 ] || [ "$rc2" -ne 0 ]; then
    echo "Container exit codes: p0=$rc0 p1=$rc1 p2=$rc2" >&2
    echo "--- ${c0} logs ---" >&2
    "$runtime" logs "$c0" >&2 || true
    echo "--- ${c1} logs ---" >&2
    "$runtime" logs "$c1" >&2 || true
    echo "--- ${c2} logs ---" >&2
    "$runtime" logs "$c2" >&2 || true
    exit 1
  fi

  local end_ts
  end_ts="$(date +%s)"
  echo "==> Done: ${label} in $((end_ts - start_ts))s"
  echo
}

if [ "$MODE" = "all" ] || [ "$MODE" = "smpc" ]; then
  if [ "$USE_DOCKER" -eq 1 ]; then
    run_three_parties_docker "MPC TCP (two_party_sum_tcp.codon, skip MHE)" "$EXAMPLE_TCP" "${SMPC_VAL1:-5}" "${SMPC_VAL2:-9}" --skip-mhe-setup
  else
    run_three_parties "MPC TCP (two_party_sum_tcp.codon, skip MHE)" "$EXAMPLE_TCP" "${SMPC_VAL1:-5}" "${SMPC_VAL2:-9}" --skip-mhe-setup
  fi
fi
if [ "$MODE" = "all" ] || [ "$MODE" = "he" ]; then
  if [ "$USE_DOCKER" -eq 1 ]; then
    run_three_parties_docker "HE TCP (two_party_sum_he_tcp.codon)" "$EXAMPLE_HE_TCP" "${HE_VAL1:-5.0}" "${HE_VAL2:-9.0}"
  else
    run_three_parties "HE TCP (two_party_sum_he_tcp.codon)" "$EXAMPLE_HE_TCP" "${HE_VAL1:-5.0}" "${HE_VAL2:-9.0}"
  fi
fi
