#!/usr/bin/env bash
set -euo pipefail

# Build and package a self-contained Python wheel that bundles Codon/Sequre libs
# using the same bundle approach as the Rust syqure CLI.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CODON_PATH="${CODON_PATH:-$ROOT_DIR/codon/install}"
export XZ_SOURCE_DIR="${XZ_SOURCE_DIR:-$ROOT_DIR/codon/build/_deps/xz-src}"

# 1) Build Codon/Sequre libs and create the bundle
echo "==> Building Codon/Sequre libs and creating bundle (./build_libs.sh)"
"$ROOT_DIR/build_libs.sh"

# 2) Detect the bundle path for the current target
TRIPLE="$(rustc -vV | grep host: | awk '{print $2}')"
BUNDLE_OUT="$ROOT_DIR/syqure/bundles/${TRIPLE}.tar.zst"

if [ ! -f "$BUNDLE_OUT" ]; then
  echo "Error: Bundle not found at $BUNDLE_OUT" >&2
  echo "Run build_libs.sh first or check your target triple." >&2
  exit 1
fi

# 3) Set SYQURE_BUNDLE_FILE so python/build.rs unpacks it automatically
export SYQURE_BUNDLE_FILE="$BUNDLE_OUT"
echo "==> Using bundle: $SYQURE_BUNDLE_FILE"

# 4) Build the wheel with maturin (build.rs will unpack the bundle)
echo "==> Building wheel"
cd "$ROOT_DIR"
if ! command -v maturin >/dev/null 2>&1; then
  echo "maturin not found; install with: pip install maturin" >&2
  exit 1
fi
maturin build --release --manifest-path python/Cargo.toml "$@"

echo "==> Wheel(s) available under target/wheels"
