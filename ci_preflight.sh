#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODON_PATH="${CODON_PATH:-$ROOT_DIR/bin/codon}"
LLVM_PATH="${LLVM_PATH:-$ROOT_DIR/sequre/codon-llvm}"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/sequre/build-preflight}"

if [ ! -d "$CODON_PATH/include" ]; then
  echo "CODON_PATH missing includes at $CODON_PATH/include" >&2
  exit 1
fi
if [ ! -d "$LLVM_PATH/install/lib/cmake/llvm" ]; then
  echo "LLVM not found at $LLVM_PATH/install/lib/cmake/llvm" >&2
  exit 1
fi

cmake -S "$ROOT_DIR/sequre" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCODON_PATH="$CODON_PATH" \
  -DCODON_SOURCE_DIR="$ROOT_DIR/codon" \
  -DLLVM_DIR="$LLVM_PATH/install/lib/cmake/llvm" \
  -DCMAKE_C_COMPILER=clang \
  -DCMAKE_CXX_COMPILER=clang++

echo "Sequre configure OK: $BUILD_DIR"
