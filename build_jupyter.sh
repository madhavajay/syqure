#!/usr/bin/env bash
# Build the Codon Jupyter plugin (libcodon_jupyter) and install it into the Codon prefix.
# Usage: ./build_jupyter.sh [--clean]
# Optional env:
#   CODON_PREFIX   : Codon install prefix (default: repo-root/codon/install)
#   CMAKE          : cmake binary to use (default: cmake)
#   BUILD_DIR      : build directory (default: codon/jupyter/build)
#   OPENSSL_ROOT_DIR: OpenSSL prefix if CMake cannot find it automatically.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JUPYTER_DIR="$ROOT/codon/jupyter"
BUILD_DIR_DEFAULT="$JUPYTER_DIR/build"

CMAKE_BIN="${CMAKE:-cmake}"
BUILD_DIR="${BUILD_DIR:-$BUILD_DIR_DEFAULT}"
CODON_PREFIX="${CODON_PREFIX:-$ROOT/codon/install}"
LLVM_DIR_DEFAULT="$ROOT/codon/llvm-project/install/lib/cmake/llvm"
LLVM_DIR="${LLVM_DIR:-$LLVM_DIR_DEFAULT}"

if [[ "${1:-}" == "--clean" ]]; then
  echo "Cleaning Jupyter build directory..."
  rm -rf "$BUILD_DIR"
fi

if [[ ! -x "$CODON_PREFIX/bin/codon" ]]; then
  echo "Codon binary not found at $CODON_PREFIX/bin/codon; set CODON_PREFIX or build Codon first." >&2
  exit 1
fi

echo "Configuring Codon Jupyter plugin..."
"$CMAKE_BIN" -S "$JUPYTER_DIR" -B "$BUILD_DIR" \
  -DCODON_PATH="$CODON_PREFIX" \
  -DCMAKE_INSTALL_PREFIX="$CODON_PREFIX/lib/codon" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DLLVM_DIR="$LLVM_DIR"

echo "Building codon_jupyter..."
"$CMAKE_BIN" --build "$BUILD_DIR" --target codon_jupyter -- -j$(sysctl -n hw.ncpu)

echo "Installing codon_jupyter into $CODON_PREFIX/lib/codon..."
"$CMAKE_BIN" --install "$BUILD_DIR"

TARGET_LIB="$CODON_PREFIX/lib/codon/libcodon_jupyter.dylib"
if [[ -f "$TARGET_LIB" ]]; then
  echo "Copying $TARGET_LIB to repo root for reuse..."
  cp "$TARGET_LIB" "$ROOT/libcodon_jupyter.dylib"
fi

echo "Done. libcodon_jupyter should now be under $CODON_PREFIX/lib/codon and mirrored at $ROOT/libcodon_jupyter.dylib."
