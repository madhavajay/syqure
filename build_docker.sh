#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="${IMAGE_NAME:-sequre-binary}"
DOCKERFILE="${DOCKERFILE:-$SCRIPT_DIR/docker/Dockerfile.sequre}"
BUILD_SYQURE="${BUILD_SYQURE:-1}"

msg() {
  printf "\n==> %s\n" "$*"
}

if [ ! -x "$SCRIPT_DIR/bin/codon/bin/codon" ]; then
  msg "Codon not found; building"
  export CODON_ENABLE_OPENMP=OFF
  "$SCRIPT_DIR/compile_codon_linux.sh"
fi

PLUGIN_SO="$SCRIPT_DIR/bin/codon/lib/codon/plugins/sequre/build/libsequre.so"
PLUGIN_CACHE="$SCRIPT_DIR/docker/binaries/libsequre.so"
if [ ! -f "$PLUGIN_SO" ]; then
  msg "Sequre plugin not found; building"
  CODON_PATH="$SCRIPT_DIR/bin/codon" "$SCRIPT_DIR/compile_sequre.sh"
fi
if [ -f "$PLUGIN_SO" ]; then
  msg "Refreshing docker plugin cache"
  mkdir -p "$(dirname "$PLUGIN_CACHE")"
  cp "$PLUGIN_SO" "$PLUGIN_CACHE"
fi

if [ "$BUILD_SYQURE" = "1" ]; then
  if [ ! -x "$SCRIPT_DIR/target/debug/syqure" ]; then
    msg "Bundling Codon/Sequre assets for syqure"
    CODON_PATH="$SCRIPT_DIR/bin/codon" "$SCRIPT_DIR/bin_libs.sh"
    msg "Building syqure (Rust)"
    cargo build -p syqure
  fi
fi

if [ ! -f "$DOCKERFILE" ]; then
  echo "Error: Dockerfile not found at $DOCKERFILE." >&2
  exit 1
fi

docker build -f "$DOCKERFILE" -t "$IMAGE_NAME" "$SCRIPT_DIR"
