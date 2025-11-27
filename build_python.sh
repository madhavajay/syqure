#!/usr/bin/env bash
set -euo pipefail

# Build and package a self-contained Python wheel that bundles Codon/Sequre libs.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1) Build Codon/Sequre and the Rust artifacts (creates codon/install)
echo "==> Building Codon/Sequre + Rust (./build.sh)"
"$ROOT_DIR/build.sh"

# 2) Bundle Codon/Sequre libs into the Python package tree so maturin includes them.
PKG_LIB_DIR="$ROOT_DIR/python/syqure/lib/codon"
SRC_LIB_DIR="$ROOT_DIR/codon/install/lib/codon"
echo "==> Bundling Codon/Sequre libs into python package: $PKG_LIB_DIR"
rm -rf "$PKG_LIB_DIR"
mkdir -p "$PKG_LIB_DIR"
cp -R "$SRC_LIB_DIR/" "$PKG_LIB_DIR/"

# 3) Build the wheel with maturin
echo "==> Building wheel"
cd "$ROOT_DIR"
if ! command -v maturin >/dev/null 2>&1; then
  echo "maturin not found; install with: pip install maturin" >&2
  exit 1
fi
maturin build --release --manifest-path python/Cargo.toml "$@"

echo "==> Wheel(s) available under target/wheels"
