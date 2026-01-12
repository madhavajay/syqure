#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-syqure-cli}"
NETWORK_NAME="${NETWORK_NAME:-syqure-net}"
EXAMPLE_PATH="${EXAMPLE_PATH:-/workspace/example/two_party_sum_tcp.codon}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST_EXAMPLE_DIR="${HOST_EXAMPLE_DIR:-${SCRIPT_DIR}/example}"
PLATFORM="${PLATFORM:-}"
SUBNET="${SUBNET:-172.28.0.0/16}"
CP0_IP="${CP0_IP:-172.28.0.2}"
CP1_IP="${CP1_IP:-172.28.0.3}"
CP2_IP="${CP2_IP:-172.28.0.4}"
SEQURE_FLAGS="${SEQURE_FLAGS:-}"

program_flags=()
if [ -n "$SEQURE_FLAGS" ]; then
  read -r -a program_flags <<< "$SEQURE_FLAGS"
fi

platform_args=()
if [ -n "$PLATFORM" ]; then
  platform_args+=(--platform "$PLATFORM")
fi

cleanup() {
  docker rm -f syqure-cp0 syqure-cp1 syqure-cp2 >/dev/null 2>&1 || true
  docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

existing_subnet="$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$NETWORK_NAME" 2>/dev/null || true)"
if [ -z "$existing_subnet" ]; then
  docker network create --subnet "$SUBNET" "$NETWORK_NAME" >/dev/null
elif [ "$existing_subnet" != "$SUBNET" ]; then
  docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
  docker network create --subnet "$SUBNET" "$NETWORK_NAME" >/dev/null
fi

common_env=(-e "SEQURE_CP_IPS=${CP0_IP},${CP1_IP},${CP2_IP}")
common_mount=(-v "${HOST_EXAMPLE_DIR}:/workspace/example:ro")

if [ ! -f "${HOST_EXAMPLE_DIR}/two_party_sum_tcp.codon" ]; then
  echo "Example file not found at ${HOST_EXAMPLE_DIR}/two_party_sum_tcp.codon" >&2
  exit 1
fi

docker run -d --rm --name syqure-cp0 --network "$NETWORK_NAME" \
  --ip "$CP0_IP" \
  ${platform_args[@]+"${platform_args[@]}"} "${common_env[@]}" "${common_mount[@]}" \
  "$IMAGE_NAME" syqure "$EXAMPLE_PATH" -- ${program_flags[@]+"${program_flags[@]}"} 0 >/dev/null

docker run -d --rm --name syqure-cp1 --network "$NETWORK_NAME" \
  --ip "$CP1_IP" \
  ${platform_args[@]+"${platform_args[@]}"} "${common_env[@]}" "${common_mount[@]}" \
  "$IMAGE_NAME" syqure "$EXAMPLE_PATH" -- ${program_flags[@]+"${program_flags[@]}"} 1 >/dev/null

docker run -d --rm --name syqure-cp2 --network "$NETWORK_NAME" \
  --ip "$CP2_IP" \
  ${platform_args[@]+"${platform_args[@]}"} "${common_env[@]}" "${common_mount[@]}" \
  "$IMAGE_NAME" syqure "$EXAMPLE_PATH" -- ${program_flags[@]+"${program_flags[@]}"} 2 >/dev/null

echo "Containers started. Tailing logs (Ctrl+C to stop)..."
docker logs -f syqure-cp0 &
docker logs -f syqure-cp1 &
docker logs -f syqure-cp2 &
wait
