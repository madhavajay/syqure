#!/usr/bin/env bash
set -euo pipefail

# Bundle prebuilt Codon + Sequre libs into syqure/bundles/<triple>.tar.zst.
# This script does not compile anything.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODON_PATH="${CODON_PATH:-$HOME/.codon}"
CODON_LLVM_DIR="${CODON_LLVM_DIR:-}"
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

# Bundle LLVM shared library from Codon's build if available.
LLVM_LIBDIR="$ROOT_DIR/codon/llvm-project/install/lib"
if [ -n "$CODON_LLVM_DIR" ] && [ -d "$CODON_LLVM_DIR/install/lib" ]; then
  LLVM_LIBDIR="$CODON_LLVM_DIR/install/lib"
fi
if [ -d "$LLVM_LIBDIR" ]; then
  if ls "$LLVM_LIBDIR"/libLLVM*.so* >/dev/null 2>&1; then
    mkdir -p "$DIST_DIR/lib/llvm"
    cp -P "$LLVM_LIBDIR"/libLLVM*.so* "$DIST_DIR/lib/llvm/" 2>/dev/null || true
  fi
fi

# Include LLVM headers if available (needed for the Rust C++ bridge).
LLVM_INC=""
if [ -n "$CODON_LLVM_DIR" ] && [ -d "$CODON_LLVM_DIR/install/include" ]; then
  LLVM_INC="$CODON_LLVM_DIR/install/include"
elif [ -d "$ROOT_DIR/codon/llvm-project/install/include" ]; then
  LLVM_INC="$ROOT_DIR/codon/llvm-project/install/include"
elif [ -d "$ROOT_DIR/external/llvm-project/llvm/include" ]; then
  LLVM_INC="$ROOT_DIR/external/llvm-project/llvm/include"
elif command -v llvm-config >/dev/null 2>&1; then
  LLVM_INC="$(llvm-config --includedir)"
fi
if [ -n "$LLVM_INC" ] && [ -d "$LLVM_INC" ]; then
  mkdir -p "$DIST_DIR/include"
  cp -R "$LLVM_INC/." "$DIST_DIR/include/"
fi

# Generate required LLVM .inc files when using source headers (no build tree).
if [ "$LLVM_INC" = "$ROOT_DIR/external/llvm-project/llvm/include" ]; then
  LLVM_TBLGEN="${LLVM_TBLGEN:-llvm-tblgen}"
  if ! command -v "$LLVM_TBLGEN" >/dev/null 2>&1; then
    echo "llvm-tblgen not found; install LLVM to generate required headers." >&2
    exit 1
  fi
  LLVM_IR_SRC="$ROOT_DIR/external/llvm-project/llvm/include/llvm/IR"
  LLVM_IR_DST="$DIST_DIR/include/llvm/IR"
  mkdir -p "$LLVM_IR_DST"
  "$LLVM_TBLGEN" -gen-attrs -I "$ROOT_DIR/external/llvm-project/llvm/include" \
    -o "$LLVM_IR_DST/Attributes.inc" "$LLVM_IR_SRC/Attributes.td"
  "$LLVM_TBLGEN" -gen-intrinsic-enums -I "$ROOT_DIR/external/llvm-project/llvm/include" \
    -o "$LLVM_IR_DST/IntrinsicEnums.inc" "$LLVM_IR_SRC/Intrinsics.td"
fi

# Create a per-target bundle
TRIPLE="$(rustc -vV | awk '/host:/{print $2}')"
BUNDLE_OUT="$ROOT_DIR/syqure/bundles/${TRIPLE}.tar.zst"
mkdir -p "$(dirname "$BUNDLE_OUT")"
echo "==> Creating bundle $BUNDLE_OUT"
rm -f "$BUNDLE_OUT"
tar -C "$DIST_DIR" -c . | zstd -19 -o "$BUNDLE_OUT"

echo "==> Done. Bundle stored at $BUNDLE_OUT"
