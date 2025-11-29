#!/usr/bin/env bash
set -euo pipefail

# Build and run the Ubuntu builder container locally, mounting this repo so the
# bundle/artifacts are written to your working tree.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKERFILE="${DOCKERFILE:-docker/Dockerfile.ubuntu-builder}"
IMAGE_TAG="${IMAGE_TAG:-syqure-linux}"

if ! command -v docker >/dev/null 2>&1; then
  echo "Error: docker not found in PATH." >&2
  exit 1
fi

if [ ! -f "$ROOT_DIR/$DOCKERFILE" ]; then
  echo "Error: Dockerfile not found at $DOCKERFILE" >&2
  exit 1
fi

echo "==> Building image $IMAGE_TAG from $DOCKERFILE"
docker build -f "$ROOT_DIR/$DOCKERFILE" -t "$IMAGE_TAG" "$ROOT_DIR"

echo "==> Running build.sh inside container (artifacts stay in your repo)"
docker run --rm \
  -v "$ROOT_DIR":/workspace \
  -w /workspace \
  "$IMAGE_TAG" \
  bash -lc "source /root/.cargo/env && ./build.sh"

echo "==> Done. Bundles should be in syqure/bundles/ under this repo."
