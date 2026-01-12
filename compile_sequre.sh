#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEQURE_PATH="${SEQURE_PATH:-$ROOT_DIR/sequre}"
if [[ -z "${CODON_PATH:-}" ]]; then
  if [[ -d "$ROOT_DIR/bin/codon" ]]; then
    CODON_PATH="$ROOT_DIR/bin/codon"
  else
    CODON_PATH="$HOME/.codon"
  fi
fi
CODON_SOURCE_DIR="${CODON_SOURCE_DIR:-}"
if [[ -z "$CODON_SOURCE_DIR" && -d "$ROOT_DIR/codon" ]]; then
  CODON_SOURCE_DIR="$ROOT_DIR/codon"
fi
LLVM_PATH="${LLVM_PATH:-$SEQURE_PATH/codon-llvm}"
SEQ_PATH="${SEQ_PATH:-$SEQURE_PATH/codon-seq}"
BUILD_TYPE="${BUILD_TYPE:-Release}"
BUILD_SEQ="${BUILD_SEQ:-0}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    return 1
  fi
}

echo "Using paths:"
echo "  SEQURE_PATH=$SEQURE_PATH"
echo "  CODON_PATH=$CODON_PATH"
echo "  CODON_SOURCE_DIR=${CODON_SOURCE_DIR:-<unset>}"
echo "  LLVM_PATH=$LLVM_PATH"
echo "  SEQ_PATH=$SEQ_PATH"
echo "  BUILD_TYPE=$BUILD_TYPE"
echo "  BUILD_SEQ=$BUILD_SEQ"

require_cmd git
require_cmd cmake
require_cmd ninja
require_cmd clang
require_cmd clang++

if [[ ! -d "$CODON_PATH/include/codon" || ! -d "$CODON_PATH/lib/codon" ]]; then
  echo "Codon install not found at $CODON_PATH" >&2
  echo "Install Codon or set CODON_PATH to the Codon install prefix." >&2
  exit 1
fi

ABI_FLAG=0
if command -v rg >/dev/null 2>&1; then
  if rg -q "B5cxx11" <<<"$(nm -D "$CODON_PATH/lib/codon/libcodonc.so" 2>/dev/null)"; then
    ABI_FLAG=1
  fi
else
  if nm -D "$CODON_PATH/lib/codon/libcodonc.so" 2>/dev/null | grep -q "B5cxx11"; then
    ABI_FLAG=1
  fi
fi
CXX_ABI_FLAGS="-D_GLIBCXX_USE_CXX11_ABI=${ABI_FLAG}"
echo "  ABI_FLAG=$ABI_FLAG"

if [[ ! -d "$SEQURE_PATH" ]]; then
  echo "Sequre repo not found at $SEQURE_PATH" >&2
  exit 1
fi

# Build LLVM (Codon fork) if not present.
if [[ -d "$LLVM_PATH/install/lib/cmake/llvm" ]]; then
  echo "Found existing LLVM installation."
else
  echo "LLVM not installed. Building Codon LLVM..."
  rm -rf "$LLVM_PATH"
  git clone --depth 1 -b codon https://github.com/exaloop/llvm-project "$LLVM_PATH"
  cmake -S "$LLVM_PATH/llvm" -B "$LLVM_PATH/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_ENABLE_RTTI=ON \
    -DLLVM_ENABLE_ZLIB=OFF \
    -DLLVM_ENABLE_TERMINFO=OFF \
    -DLLVM_TARGETS_TO_BUILD=all \
    -DCMAKE_C_COMPILER=clang \
    -DCMAKE_CXX_COMPILER=clang++
  cmake --build "$LLVM_PATH/build"
  cmake --install "$LLVM_PATH/build" --prefix "$LLVM_PATH/install"
fi

if [[ "$BUILD_SEQ" == "1" ]]; then
  # Build Seq plugin if not present.
  if [[ -d "$CODON_PATH/lib/codon/plugins/seq" ]]; then
    echo "Found existing Seq-lang installation."
  else
    echo "Seq-lang not installed. Building..."
    rm -rf "$SEQ_PATH"
    git clone https://github.com/exaloop/seq.git "$SEQ_PATH"
    cmake -S "$SEQ_PATH" -B "$SEQ_PATH/build" -G Ninja \
      -DLLVM_DIR="$LLVM_PATH/install/lib/cmake/llvm" \
      -DCODON_PATH="$CODON_PATH" \
      -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
      -DCMAKE_CXX_FLAGS="$CXX_ABI_FLAGS" \
      -DCMAKE_C_COMPILER=clang \
      -DCMAKE_CXX_COMPILER=clang++
    cmake --build "$SEQ_PATH/build" --config "$BUILD_TYPE"
    cmake --install "$SEQ_PATH/build" --prefix "$CODON_PATH/lib/codon/plugins/seq"
  fi
else
  echo "Skipping Seq-lang build (BUILD_SEQ=$BUILD_SEQ)."
fi

# Build Sequre plugin.
echo "Building Sequre plugin..."
rm -rf "$SEQURE_PATH/build"
cmake -S "$SEQURE_PATH" -B "$SEQURE_PATH/build" -G Ninja \
  -DLLVM_DIR="$LLVM_PATH/install/lib/cmake/llvm" \
  -DCODON_PATH="$CODON_PATH" \
  ${CODON_SOURCE_DIR:+-DCODON_SOURCE_DIR="$CODON_SOURCE_DIR"} \
  -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
  -DCMAKE_CXX_FLAGS="$CXX_ABI_FLAGS" \
  -DCMAKE_C_COMPILER=clang \
  -DCMAKE_CXX_COMPILER=clang++
cmake --build "$SEQURE_PATH/build" --config "$BUILD_TYPE"
cmake --install "$SEQURE_PATH/build" --prefix "$CODON_PATH/lib/codon/plugins/sequre"

echo "Sequre plugin installed to $CODON_PATH/lib/codon/plugins/sequre"
