#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="${IMAGE_NAME:-syqure-cli}"
DOCKERFILE="${DOCKERFILE:-$SCRIPT_DIR/docker/Dockerfile.syqure}"

msg() {
  printf "\n==> %s\n" "$*"
}

if [ ! -x "$SCRIPT_DIR/bin/codon/bin/codon" ]; then
  msg "Codon not found; building"
  export CODON_ENABLE_OPENMP=OFF
  "$SCRIPT_DIR/compile_codon_linux.sh"
fi

PLUGIN_SO="$SCRIPT_DIR/bin/codon/lib/codon/plugins/sequre/build/libsequre.so"
if [ ! -f "$PLUGIN_SO" ]; then
  msg "Sequre plugin not found; building"
  CODON_PATH="$SCRIPT_DIR/bin/codon" "$SCRIPT_DIR/compile_sequre.sh"
fi

msg "Bundling Codon/Sequre assets for syqure"
CODON_PATH="$SCRIPT_DIR/bin/codon" "$SCRIPT_DIR/bin_libs.sh"

msg "Building syqure (Rust)"
cargo build -p syqure

if [ ! -f "$DOCKERFILE" ]; then
  echo "Error: Dockerfile not found at $DOCKERFILE." >&2
  exit 1
fi

msg "Building Docker image $IMAGE_NAME"
docker build -f "$DOCKERFILE" -t "$IMAGE_NAME" "$SCRIPT_DIR"
