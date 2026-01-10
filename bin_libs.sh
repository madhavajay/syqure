#!/usr/bin/env bash
set -euo pipefail

# Bundle prebuilt Codon + Sequre libs into syqure/bundles/<triple>.tar.zst.
# This script does not compile anything.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODON_PATH="${CODON_PATH:-$HOME/.codon}"
export CODON_PATH

if [ ! -d "$CODON_PATH/lib/codon" ]; then
  echo "Codon install not found at $CODON_PATH" >&2
  exit 1
fi

SEQURE_SO="$CODON_PATH/lib/codon/plugins/sequre/build/libsequre.so"
if [ ! -f "$SEQURE_SO" ]; then
  echo "Sequre plugin not found at $SEQURE_SO" >&2
  echo "Run ./compile_sequre.sh first (or set CODON_PATH to the install)." >&2
  exit 1
fi

# Prepare a dist layout for bundling
DIST_DIR="$ROOT_DIR/target/dist/syqure"
mkdir -p "$DIST_DIR/bin" "$DIST_DIR/lib" "$DIST_DIR/include"

SYQURE_BIN="${SYQURE_BIN:-$ROOT_DIR/target/debug/syqure}"
if [ -x "$SYQURE_BIN" ]; then
  echo "==> Copying existing syqure binary into dist"
  cp "$SYQURE_BIN" "$DIST_DIR/bin/"
fi

echo "==> Copying Codon/Sequre libs into dist"
rm -rf "$DIST_DIR/lib/codon"
cp -R "$CODON_PATH/lib/codon" "$DIST_DIR/lib/"
if [ -d "$CODON_PATH/include" ]; then
  rm -rf "$DIST_DIR/include"
  mkdir -p "$DIST_DIR/include"
  cp -R "$CODON_PATH/include/." "$DIST_DIR/include/"
fi

# Also include LLVM headers if available (needed for the Rust C++ bridge).
LLVM_INC=""
if [ -d "$ROOT_DIR/external/llvm-project/llvm/include" ]; then
  LLVM_INC="$ROOT_DIR/external/llvm-project/llvm/include"
elif command -v llvm-config >/dev/null 2>&1; then
  LLVM_INC="$(llvm-config --includedir)"
fi
if [ -n "$LLVM_INC" ] && [ -d "$LLVM_INC" ]; then
  mkdir -p "$DIST_DIR/include"
  cp -R "$LLVM_INC/." "$DIST_DIR/include/"
fi

# Create a per-target bundle
TRIPLE="$(rustc -vV | awk '/host:/{print $2}')"
BUNDLE_OUT="$ROOT_DIR/syqure/bundles/${TRIPLE}.tar.zst"
mkdir -p "$(dirname "$BUNDLE_OUT")"
echo "==> Creating bundle $BUNDLE_OUT"
rm -f "$BUNDLE_OUT"
tar -C "$DIST_DIR" -c . | zstd -19 -o "$BUNDLE_OUT"

echo "==> Done. Bundle stored at $BUNDLE_OUT"
