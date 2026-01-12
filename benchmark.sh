#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IMAGE_NAME="${IMAGE_NAME:-syqure-cli}"
PLATFORM="${PLATFORM:-}"
HOST_EXAMPLE_DIR="${HOST_EXAMPLE_DIR:-${SCRIPT_DIR}/example}"
SEQURE_FLAGS="${SEQURE_FLAGS:-}"
SEQURE_CP_COUNT="${SEQURE_CP_COUNT:-3}"
SEQURE_FILE_POLL_MS="${SEQURE_FILE_POLL_MS:-50}"

NETWORK_NAME="${NETWORK_NAME:-syqure-net}"
SUBNET="${SUBNET:-172.28.0.0/16}"
CP0_IP="${CP0_IP:-172.28.0.2}"
CP1_IP="${CP1_IP:-172.28.0.3}"
CP2_IP="${CP2_IP:-172.28.0.4}"

TRANSPORT="tcp"
FOLLOW_LOGS=1
EXAMPLE_REL=""
EXTRA_ARGS=()

usage() {
  cat <<EOF
Usage: $0 [--file-transport|--network-transport] [--no-follow] [--] <example>

Examples:
  $0 example/two_party_sum_tcp.codon
  $0 --file-transport example/two_party_sum_tcp.codon
  PLATFORM=linux/amd64 $0 --network-transport example/two_party_sum_tcp.codon

Env overrides: IMAGE_NAME, PLATFORM, HOST_EXAMPLE_DIR, SEQURE_FLAGS, SEQURE_CP_COUNT,
SEQURE_FILE_POLL_MS, NETWORK_NAME, SUBNET, CP0_IP, CP1_IP, CP2_IP.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --file-transport) TRANSPORT="file"; shift ;;
    --network-transport) TRANSPORT="tcp"; shift ;;
    --no-follow) FOLLOW_LOGS=0; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; EXTRA_ARGS=("$@"); break ;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      EXAMPLE_REL="$1"
      shift
      ;;
  esac
done

if [ -z "$EXAMPLE_REL" ]; then
  echo "Missing example path." >&2
  usage
  exit 1
fi

# Normalize example path under /workspace/example.
if [[ "$EXAMPLE_REL" == /workspace/example/* ]]; then
  EXAMPLE_REL="${EXAMPLE_REL#/workspace/example/}"
elif [[ "$EXAMPLE_REL" == example/* ]]; then
  EXAMPLE_REL="${EXAMPLE_REL#example/}"
fi

HOST_EXAMPLE_PATH="${HOST_EXAMPLE_DIR}/${EXAMPLE_REL}"
if [ ! -f "$HOST_EXAMPLE_PATH" ]; then
  echo "Example file not found at ${HOST_EXAMPLE_PATH}" >&2
  exit 1
fi
EXAMPLE_PATH="/workspace/example/${EXAMPLE_REL}"

program_flags=()
if [ -n "$SEQURE_FLAGS" ]; then
  read -r -a program_flags <<< "$SEQURE_FLAGS"
fi
if [ "${#EXTRA_ARGS[@]}" -gt 0 ]; then
  program_flags+=("${EXTRA_ARGS[@]}")
fi

platform_args=()
if [ -n "$PLATFORM" ]; then
  platform_args+=(--platform "$PLATFORM")
fi

cleanup() {
  docker rm -f syqure-bench-cp0 syqure-bench-cp1 syqure-bench-cp2 >/dev/null 2>&1 || true
  if [ "$TRANSPORT" = "tcp" ]; then
    docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

common_mount=(
  -v "${HOST_EXAMPLE_DIR}:/workspace/example:ro"
)

common_env=(
  -e "SEQURE_CP_COUNT=${SEQURE_CP_COUNT}"
)

if [ "$TRANSPORT" = "file" ]; then
  SHARED_DIR="${SHARED_DIR:-${SCRIPT_DIR}/sandbox/syqure-messages}"
  rm -rf "$SHARED_DIR"
  mkdir -p "$SHARED_DIR"
  for pair in 0_to_1 0_to_2 1_to_0 1_to_2 2_to_0 2_to_1; do
    mkdir -p "$SHARED_DIR/$pair"
  done
  common_env+=(
    -e "SEQURE_TRANSPORT=file"
    -e "SEQURE_FILE_DIR=/workspace/shared"
    -e "SEQURE_FILE_POLL_MS=${SEQURE_FILE_POLL_MS}"
  )
  common_mount+=(-v "${SHARED_DIR}:/workspace/shared")
else
  existing_subnet="$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$NETWORK_NAME" 2>/dev/null || true)"
  if [ -z "$existing_subnet" ]; then
    docker network create --subnet "$SUBNET" "$NETWORK_NAME" >/dev/null
  elif [ "$existing_subnet" != "$SUBNET" ]; then
    docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
    docker network create --subnet "$SUBNET" "$NETWORK_NAME" >/dev/null
  fi
  common_env+=(
    -e "SEQURE_TRANSPORT=tcp"
    -e "SEQURE_CP_IPS=${CP0_IP},${CP1_IP},${CP2_IP}"
  )
fi

start_ts="$(date +%s)"

if [ "$TRANSPORT" = "tcp" ]; then
  docker run -d --rm --name syqure-bench-cp0 --network "$NETWORK_NAME" --ip "$CP0_IP" \
    "${platform_args[@]}" "${common_env[@]}" "${common_mount[@]}" \
    "$IMAGE_NAME" syqure "$EXAMPLE_PATH" -- "${program_flags[@]}" 0 >/dev/null
  docker run -d --rm --name syqure-bench-cp1 --network "$NETWORK_NAME" --ip "$CP1_IP" \
    "${platform_args[@]}" "${common_env[@]}" "${common_mount[@]}" \
    "$IMAGE_NAME" syqure "$EXAMPLE_PATH" -- "${program_flags[@]}" 1 >/dev/null
  docker run -d --rm --name syqure-bench-cp2 --network "$NETWORK_NAME" --ip "$CP2_IP" \
    "${platform_args[@]}" "${common_env[@]}" "${common_mount[@]}" \
    "$IMAGE_NAME" syqure "$EXAMPLE_PATH" -- "${program_flags[@]}" 2 >/dev/null
else
  docker run -d --rm --name syqure-bench-cp0 \
    "${platform_args[@]}" "${common_env[@]}" "${common_mount[@]}" \
    "$IMAGE_NAME" syqure "$EXAMPLE_PATH" -- "${program_flags[@]}" 0 >/dev/null
  docker run -d --rm --name syqure-bench-cp1 \
    "${platform_args[@]}" "${common_env[@]}" "${common_mount[@]}" \
    "$IMAGE_NAME" syqure "$EXAMPLE_PATH" -- "${program_flags[@]}" 1 >/dev/null
  docker run -d --rm --name syqure-bench-cp2 \
    "${platform_args[@]}" "${common_env[@]}" "${common_mount[@]}" \
    "$IMAGE_NAME" syqure "$EXAMPLE_PATH" -- "${program_flags[@]}" 2 >/dev/null
fi

if [ "$FOLLOW_LOGS" = "1" ]; then
  echo "Containers started ($TRANSPORT). Tailing logs (Ctrl+C to stop)..."
  docker logs -f syqure-bench-cp0 &
  docker logs -f syqure-bench-cp1 &
  docker logs -f syqure-bench-cp2 &
fi

rc0="$(docker wait syqure-bench-cp0)"
rc1="$(docker wait syqure-bench-cp1)"
rc2="$(docker wait syqure-bench-cp2)"
end_ts="$(date +%s)"

echo "Elapsed: $((end_ts - start_ts))s"
echo "Exit codes: cp0=${rc0} cp1=${rc1} cp2=${rc2}"

if [ "$rc0" != "0" ] || [ "$rc1" != "0" ] || [ "$rc2" != "0" ]; then
  exit 1
fi
