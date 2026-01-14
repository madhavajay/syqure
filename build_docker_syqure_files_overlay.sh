#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="${IMAGE_NAME:-syqure-cli-files}"
BASE_IMAGE="${BASE_IMAGE:-syqure-cli:latest}"
DOCKERFILE="${DOCKERFILE:-$SCRIPT_DIR/docker/Dockerfile.syqure-files}"
PLATFORM="${PLATFORM:-}"

msg() {
  printf "\n==> %s\n" "$*"
}

if [ ! -f "$DOCKERFILE" ]; then
  echo "Error: Dockerfile not found at $DOCKERFILE." >&2
  exit 1
fi

msg "Building file-transport overlay image $IMAGE_NAME (base: $BASE_IMAGE)"
if [ -n "$PLATFORM" ]; then
  docker build --platform "$PLATFORM" -f "$DOCKERFILE" \
    --build-arg BASE_IMAGE="$BASE_IMAGE" \
    -t "$IMAGE_NAME" \
    "$SCRIPT_DIR"
else
  docker build -f "$DOCKERFILE" \
    --build-arg BASE_IMAGE="$BASE_IMAGE" \
    -t "$IMAGE_NAME" \
    "$SCRIPT_DIR"
fi
