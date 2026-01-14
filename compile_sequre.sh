#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEQURE_PATH="${SEQURE_PATH:-$ROOT_DIR/sequre}"
OS_NAME="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH_NAME="$(uname -m | tr '[:upper:]' '[:lower:]')"
OS_LABEL="$OS_NAME"
ARCH_LABEL="$ARCH_NAME"
case "$OS_NAME" in
  darwin) OS_LABEL="macos" ;;
  linux) OS_LABEL="linux" ;;
esac
case "$ARCH_NAME" in
  arm64|aarch64) ARCH_LABEL="arm64" ;;
  x86_64|amd64|i386|i686) ARCH_LABEL="x86" ;;
esac
TARGET_ID="${OS_LABEL}-${ARCH_LABEL}"
LIB_EXT="so"
if [[ "$OS_NAME" == "darwin" ]]; then
  LIB_EXT="dylib"
fi
CC="${CC:-}"
CXX="${CXX:-}"
CMAKE_OSX_SYSROOT_ARGS=()
if [[ "$OS_NAME" == "darwin" ]]; then
  if [[ -z "$CC" ]]; then
    CC="/usr/bin/clang"
  fi
  if [[ -z "$CXX" ]]; then
    CXX="/usr/bin/clang++"
  fi
  if [[ -z "${SDKROOT:-}" ]]; then
    SDKROOT="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
  fi
  if [[ -n "${SDKROOT:-}" ]]; then
    export SDKROOT
    CMAKE_OSX_SYSROOT_ARGS+=("-DCMAKE_OSX_SYSROOT=$SDKROOT")
  fi
else
  if [[ -z "$CC" ]]; then
    CC="clang"
  fi
  if [[ -z "$CXX" ]]; then
    CXX="clang++"
  fi
fi
export CC CXX
if [[ -z "${CODON_PATH:-}" ]]; then
  if [[ -d "$ROOT_DIR/bin/$TARGET_ID/codon" ]]; then
    CODON_PATH="$ROOT_DIR/bin/$TARGET_ID/codon"
  elif [[ -d "$ROOT_DIR/bin/codon" ]]; then
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
LLVM_BRANCH="${LLVM_BRANCH:-codon-17.0.6}"
LLVM_TARGETS="${LLVM_TARGETS:-all}"
SEQ_PATH="${SEQ_PATH:-$SEQURE_PATH/codon-seq}"
BUILD_TYPE="${BUILD_TYPE:-Release}"
BUILD_SEQ="${BUILD_SEQ:-0}"
SEQURE_CLEAN="${SEQURE_CLEAN:-0}"

for arg in "$@"; do
  case "$arg" in
    --clean) SEQURE_CLEAN=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

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
echo "  LLVM_BRANCH=$LLVM_BRANCH"
echo "  SEQ_PATH=$SEQ_PATH"
echo "  BUILD_TYPE=$BUILD_TYPE"
echo "  BUILD_SEQ=$BUILD_SEQ"
echo "  SEQURE_CLEAN=$SEQURE_CLEAN"
echo "  CC=$CC"
echo "  CXX=$CXX"
if [[ -n "${SDKROOT:-}" ]]; then
  echo "  SDKROOT=$SDKROOT"
fi

require_cmd git
require_cmd cmake
require_cmd ninja
require_cmd "$CC"
require_cmd "$CXX"

abspath() {
  if command -v realpath >/dev/null 2>&1; then
    if realpath -m . >/dev/null 2>&1; then
      realpath -m "$1"
      return
    fi
  fi
  python3 - <<'PY' "$1"
from pathlib import Path
import sys
print(Path(sys.argv[1]).resolve())
PY
}

cmake_cache_value() {
  local cache="$1"
  local key="$2"
  if command -v rg >/dev/null 2>&1; then
    rg -n "^${key}:" "$cache" 2>/dev/null | head -n 1 | cut -d= -f2- || true
  else
    grep -E "^${key}:" "$cache" 2>/dev/null | head -n 1 | cut -d= -f2- || true
  fi
}

clean_build_if_mismatch() {
  local build_dir="$1"
  local label="$2"
  shift 2
  local cache="$build_dir/CMakeCache.txt"
  if [[ ! -f "$cache" ]]; then
    return 0
  fi
  local cache_cxx
  cache_cxx="$(cmake_cache_value "$cache" "CMAKE_CXX_COMPILER:FILEPATH")"
  local cache_sysroot=""
  if [[ "$OS_NAME" == "darwin" ]]; then
    cache_sysroot="$(cmake_cache_value "$cache" "CMAKE_OSX_SYSROOT:PATH")"
  fi
  local mismatch=0
  if [[ -n "$cache_cxx" && "$cache_cxx" != "$CXX" ]]; then
    mismatch=1
  fi
  if [[ "$OS_NAME" == "darwin" && -n "${SDKROOT:-}" && -n "$cache_sysroot" && "$cache_sysroot" != "$SDKROOT" ]]; then
    mismatch=1
  fi
  if [[ "$mismatch" -eq 1 ]]; then
    echo "$label build toolchain mismatch: cache_cxx=${cache_cxx:-<unset>} expected=$CXX"
    if [[ "$OS_NAME" == "darwin" && -n "${SDKROOT:-}" ]]; then
      echo "$label build SDKROOT mismatch: cache_sysroot=${cache_sysroot:-<unset>} expected=$SDKROOT"
    fi
    rm -rf "$build_dir"
    if [[ "$#" -gt 0 ]]; then
      rm -rf "$@"
    fi
  fi
}

if [[ ! -d "$CODON_PATH/include/codon" || ! -d "$CODON_PATH/lib/codon" ]]; then
  echo "Codon install not found at $CODON_PATH" >&2
  echo "Install Codon or set CODON_PATH to the Codon install prefix." >&2
  exit 1
fi

CODON_PATH="$(abspath "$CODON_PATH")"
SEQURE_PATH="$(abspath "$SEQURE_PATH")"
LLVM_PATH="$(abspath "$LLVM_PATH")"
SEQ_PATH="$(abspath "$SEQ_PATH")"
if [[ -n "${CODON_SOURCE_DIR:-}" ]]; then
  CODON_SOURCE_DIR="$(abspath "$CODON_SOURCE_DIR")"
fi

ABI_FLAG=""
CXX_ABI_FLAGS=""
if [[ "$OS_NAME" != "darwin" ]]; then
  ABI_FLAG=0
  CODONC_LIB="$CODON_PATH/lib/codon/libcodonc.${LIB_EXT}"
  if command -v rg >/dev/null 2>&1; then
    if rg -q "B5cxx11" <<<"$(nm -D "$CODONC_LIB" 2>/dev/null)"; then
      ABI_FLAG=1
    fi
  else
    if nm -D "$CODONC_LIB" 2>/dev/null | grep -q "B5cxx11"; then
      ABI_FLAG=1
    fi
  fi
  CXX_ABI_FLAGS="-D_GLIBCXX_USE_CXX11_ABI=${ABI_FLAG}"
fi
if [[ -d "$ROOT_DIR/compat" ]]; then
  if [[ -n "$CXX_ABI_FLAGS" ]]; then
    CXX_ABI_FLAGS+=" "
  fi
  CXX_ABI_FLAGS+="-I$ROOT_DIR/compat"
fi
if [[ -n "$ABI_FLAG" ]]; then
  echo "  ABI_FLAG=$ABI_FLAG"
fi

if [[ ! -d "$SEQURE_PATH" ]]; then
  echo "Sequre repo not found at $SEQURE_PATH" >&2
  exit 1
fi

clean_build_if_mismatch "$LLVM_PATH/build" "LLVM" "$LLVM_PATH/install"

# Build LLVM (Codon fork) if not present.
if [[ -d "$LLVM_PATH/install/lib/cmake/llvm" ]]; then
  echo "Found existing LLVM installation."
else
  echo "LLVM not installed. Building Codon LLVM..."
  rm -rf "$LLVM_PATH"
  git clone --depth 1 -b "$LLVM_BRANCH" https://github.com/exaloop/llvm-project "$LLVM_PATH"
  cmake -S "$LLVM_PATH/llvm" -B "$LLVM_PATH/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_ENABLE_RTTI=ON \
    -DLLVM_ENABLE_ZLIB=OFF \
    -DLLVM_ENABLE_TERMINFO=OFF \
    -DLLVM_TARGETS_TO_BUILD="$LLVM_TARGETS" \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_CXX_COMPILER="$CXX" \
    "${CMAKE_OSX_SYSROOT_ARGS[@]}"
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
      -DCMAKE_C_COMPILER="$CC" \
      -DCMAKE_CXX_COMPILER="$CXX" \
      "${CMAKE_OSX_SYSROOT_ARGS[@]}"
    cmake --build "$SEQ_PATH/build" --config "$BUILD_TYPE"
    cmake --install "$SEQ_PATH/build" --prefix "$CODON_PATH/lib/codon/plugins/seq"
  fi
else
  echo "Skipping Seq-lang build (BUILD_SEQ=$BUILD_SEQ)."
fi

# Build Sequre plugin.
echo "Building Sequre plugin..."
if [[ "$SEQURE_CLEAN" == "1" ]]; then
  rm -rf "$SEQURE_PATH/build"
fi
clean_build_if_mismatch "$SEQURE_PATH/build" "Sequre"
CPM_VERSION="0.32.3"
CPM_PATH="$SEQURE_PATH/build/cmake/CPM_${CPM_VERSION}.cmake"
if [[ ! -s "$CPM_PATH" ]]; then
  mkdir -p "$(dirname "$CPM_PATH")"
  if [[ -n "${CODON_SOURCE_DIR:-}" && -s "$CODON_SOURCE_DIR/build/cmake/CPM_${CPM_VERSION}.cmake" ]]; then
    cp -f "$CODON_SOURCE_DIR/build/cmake/CPM_${CPM_VERSION}.cmake" "$CPM_PATH"
  elif [[ -s "$ROOT_DIR/codon/build/cmake/CPM_${CPM_VERSION}.cmake" ]]; then
    cp -f "$ROOT_DIR/codon/build/cmake/CPM_${CPM_VERSION}.cmake" "$CPM_PATH"
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL "https://github.com/TheLartians/CPM.cmake/releases/download/v${CPM_VERSION}/CPM.cmake" -o "$CPM_PATH" || true
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$CPM_PATH" "https://github.com/TheLartians/CPM.cmake/releases/download/v${CPM_VERSION}/CPM.cmake" || true
  fi
  if [[ ! -s "$CPM_PATH" ]]; then
    echo "Error: failed to obtain CPM.cmake at $CPM_PATH" >&2
    echo "Check network access or ensure it exists before rerunning." >&2
    exit 1
  fi
fi
cmake -S "$SEQURE_PATH" -B "$SEQURE_PATH/build" -G Ninja \
  -DLLVM_DIR="$LLVM_PATH/install/lib/cmake/llvm" \
  -DCODON_PATH="$CODON_PATH" \
  ${CODON_SOURCE_DIR:+-DCODON_SOURCE_DIR="$CODON_SOURCE_DIR"} \
  -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
  -DCMAKE_CXX_FLAGS="$CXX_ABI_FLAGS" \
  -DCMAKE_C_COMPILER="$CC" \
  -DCMAKE_CXX_COMPILER="$CXX" \
  "${CMAKE_OSX_SYSROOT_ARGS[@]}"
cmake --build "$SEQURE_PATH/build" --config "$BUILD_TYPE"
cmake --install "$SEQURE_PATH/build" --prefix "$CODON_PATH/lib/codon/plugins/sequre"

echo "Sequre plugin installed to $CODON_PATH/lib/codon/plugins/sequre"
SEQURE_STDLIB_SRC="$SEQURE_PATH/stdlib"
SEQURE_STDLIB_DST="$CODON_PATH/lib/codon/plugins/sequre/stdlib"
if [[ -d "$SEQURE_STDLIB_SRC" ]]; then
  rm -rf "$SEQURE_STDLIB_DST"
  ln -s "$SEQURE_STDLIB_SRC" "$SEQURE_STDLIB_DST"
else
  echo "Warning: Sequre stdlib source not found at $SEQURE_STDLIB_SRC; keeping installed stdlib." >&2
fi
