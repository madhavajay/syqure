#!/usr/bin/env bash
set -euo pipefail

# Build syqure Rust binary using prebuilt Codon/Sequre libs from bin/
# This script does NOT compile Codon or Sequre - it reuses prebuilts.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

CODON_PATH="${CODON_PATH:-$ROOT_DIR/bin/$TARGET_ID/codon}"
if [ ! -d "$CODON_PATH/lib/codon" ]; then
  echo "Error: Codon prebuilts not found at $CODON_PATH/lib/codon" >&2
  echo "Expected path: $ROOT_DIR/bin/$TARGET_ID/codon" >&2
  exit 1
fi

LIB_EXT="so"
if [ "$OS_NAME" = "darwin" ]; then
  LIB_EXT="dylib"
fi

SEQURE_LIB="$CODON_PATH/lib/codon/plugins/sequre/build/libsequre.${LIB_EXT}"
if [ ! -f "$SEQURE_LIB" ]; then
  echo "Error: Sequre plugin not found at $SEQURE_LIB" >&2
  exit 1
fi

echo "==> Using prebuilt Codon from: $CODON_PATH"

DIST_DIR="$ROOT_DIR/target/dist/syqure"
mkdir -p "$DIST_DIR/bin" "$DIST_DIR/lib" "$DIST_DIR/include"

echo "==> Copying Codon/Sequre libs (dereferencing symlinks)"
rm -rf "$DIST_DIR/lib/codon"
cp -RL "$CODON_PATH/lib/codon" "$DIST_DIR/lib/"

if [ -d "$CODON_PATH/include" ]; then
  rm -rf "$DIST_DIR/include"
  mkdir -p "$DIST_DIR/include"
  cp -RL "$CODON_PATH/include/." "$DIST_DIR/include/"
fi

# Include LLVM headers (required for C++ bridge compilation)
# Check sources in order: CODON_LLVM_DIR, codon build, LLVM_PREFIX, homebrew, llvm-config
CODON_LLVM_DIR="${CODON_LLVM_DIR:-}"
LLVM_INC=""
if [ -n "$CODON_LLVM_DIR" ] && [ -d "$CODON_LLVM_DIR/install/include" ]; then
  LLVM_INC="$CODON_LLVM_DIR/install/include"
elif [ -d "$ROOT_DIR/codon/llvm-project/install/include" ]; then
  LLVM_INC="$ROOT_DIR/codon/llvm-project/install/include"
elif [ -n "${LLVM_PREFIX:-}" ] && [ -d "$LLVM_PREFIX/include/llvm" ]; then
  LLVM_INC="$LLVM_PREFIX/include"
elif [ "$OS_NAME" = "darwin" ] && command -v brew >/dev/null 2>&1; then
  BREW_LLVM="$(brew --prefix llvm 2>/dev/null || true)"
  if [ -n "$BREW_LLVM" ] && [ -d "$BREW_LLVM/include/llvm" ]; then
    LLVM_INC="$BREW_LLVM/include"
  fi
elif command -v llvm-config >/dev/null 2>&1; then
  LLVM_INC="$(llvm-config --includedir)"
fi

if [ -n "$LLVM_INC" ] && [ -d "$LLVM_INC" ]; then
  echo "==> Copying LLVM headers from $LLVM_INC"
  mkdir -p "$DIST_DIR/include"
  cp -RL "$LLVM_INC/." "$DIST_DIR/include/"
else
  echo "Error: LLVM headers not found." >&2
  echo "Options: set CODON_LLVM_DIR, LLVM_PREFIX, or install llvm via brew." >&2
  exit 1
fi

find_gmp_lib() {
  if [ -n "${SEQURE_GMP_PATH:-}" ] && [ -f "$SEQURE_GMP_PATH" ]; then
    printf "%s\n" "$SEQURE_GMP_PATH"
    return 0
  fi
  if [ "$OS_NAME" = "darwin" ]; then
    if command -v brew >/dev/null 2>&1; then
      local gmp_prefix
      gmp_prefix="$(brew --prefix gmp 2>/dev/null || true)"
      if [ -n "$gmp_prefix" ] && [ -f "$gmp_prefix/lib/libgmp.dylib" ]; then
        printf "%s\n" "$gmp_prefix/lib/libgmp.dylib"
        return 0
      fi
    fi
    for candidate in \
      /opt/homebrew/opt/gmp/lib/libgmp.dylib \
      /usr/local/opt/gmp/lib/libgmp.dylib; do
      if [ -f "$candidate" ]; then
        printf "%s\n" "$candidate"
        return 0
      fi
    done
  else
    for dir in /usr/lib /usr/lib64 /usr/local/lib; do
      local candidate
      candidate="$(ls -1 "$dir"/libgmp.so "$dir"/libgmp.so.* 2>/dev/null | head -n 1 || true)"
      if [ -n "$candidate" ] && [ -f "$candidate" ]; then
        printf "%s\n" "$candidate"
        return 0
      fi
    done
  fi
  return 1
}

GMP_SRC="$(find_gmp_lib || true)"
if [ -n "$GMP_SRC" ]; then
  echo "==> Bundling libgmp from $GMP_SRC"
  if [ "$OS_NAME" = "darwin" ]; then
    cp -L "$GMP_SRC" "$DIST_DIR/lib/codon/libgmp.dylib"
    cp -L "$GMP_SRC" "$DIST_DIR/lib/codon/libgmp.so"
  else
    cp -L "$GMP_SRC" "$DIST_DIR/lib/codon/libgmp.so"
  fi
else
  echo "Warning: libgmp not found" >&2
fi

TRIPLE="$(rustc -vV | awk '/host:/{print $2}')"
BUNDLE_OUT="$ROOT_DIR/syqure/bundles/${TRIPLE}.tar.zst"
mkdir -p "$(dirname "$BUNDLE_OUT")"
echo "==> Creating bundle $BUNDLE_OUT"
rm -f "$BUNDLE_OUT"
tar -C "$DIST_DIR" -c . | zstd -19 -o "$BUNDLE_OUT"

echo "==> Building syqure Rust binary"
cd "$ROOT_DIR"
export SYQURE_BUNDLE_FILE="$BUNDLE_OUT"
cargo build -p syqure

echo "==> Done. Binary at: $ROOT_DIR/target/debug/syqure"
echo "    Run: cargo run -p syqure -- example/two_party_sum_simple.codon"
