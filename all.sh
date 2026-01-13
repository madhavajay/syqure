#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_FILE="$ROOT_DIR/syqure/bundles/$(rustc -vV | awk '/host:/{print $2}').tar.zst"
SYQURE_CACHE_DIR="$ROOT_DIR/target/syqure-cache"
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
BIN_DIR="$ROOT_DIR/bin/$TARGET_ID"
CODON_PATH="$BIN_DIR/codon"
CODON_BUILD_SCRIPT="$ROOT_DIR/compile_codon.sh"
case "$OS_NAME" in
  darwin) CODON_BUILD_SCRIPT="$ROOT_DIR/compile_codon_macos.sh" ;;
  linux) CODON_BUILD_SCRIPT="$ROOT_DIR/compile_codon_linux.sh" ;;
esac
if [ "$OS_NAME" = "darwin" ] && [ -z "${LLVM_TARGETS:-}" ]; then
  export LLVM_TARGETS="AArch64"
fi
if [ -z "${SEQURE_GMP_PATH:-}" ] && [ "$OS_NAME" = "darwin" ]; then
  if command -v brew >/dev/null 2>&1; then
    gmp_prefix="$(brew --prefix gmp 2>/dev/null || true)"
    if [ -n "$gmp_prefix" ] && [ -f "$gmp_prefix/lib/libgmp.dylib" ]; then
      export SEQURE_GMP_PATH="$gmp_prefix/lib/libgmp.dylib"
    fi
  fi
  if [ -z "${SEQURE_GMP_PATH:-}" ]; then
    for candidate in \
      /opt/homebrew/opt/gmp/lib/libgmp.dylib \
      /usr/local/opt/gmp/lib/libgmp.dylib \
      /opt/homebrew/lib/libgmp.dylib \
      /usr/local/lib/libgmp.dylib; do
      if [ -f "$candidate" ]; then
        export SEQURE_GMP_PATH="$candidate"
        break
      fi
    done
  fi
  if [ -z "${SEQURE_GMP_PATH:-}" ]; then
    export SEQURE_GMP_PATH="libgmp.dylib"
  fi
fi

CLEAN=0
for arg in "$@"; do
  case "$arg" in
    --clean) CLEAN=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

msg() {
  printf "\n==> %s\n" "$*"
}

msg "Building Codon + LLVM shared (this can take a while, os=${OS_NAME})"
export CODON_ENABLE_OPENMP=OFF
export BIN_DIR
CODON_BUILD_ARGS=()
if [ "$CLEAN" -eq 1 ]; then
  CODON_BUILD_ARGS+=(--clean)
fi
"$CODON_BUILD_SCRIPT" "${CODON_BUILD_ARGS[@]+"${CODON_BUILD_ARGS[@]}"}"

msg "Building Sequre plugin against repo-local Codon"
if [ -z "${LLVM_PATH:-}" ] && [ -d "$ROOT_DIR/codon/llvm-project/install/lib/cmake/llvm" ]; then
  export LLVM_PATH="$ROOT_DIR/codon/llvm-project"
fi
SEQURE_BUILD_ARGS=()
if [ "$CLEAN" -eq 1 ]; then
  SEQURE_BUILD_ARGS+=(--clean)
fi
CODON_PATH="$CODON_PATH" "$ROOT_DIR/compile_sequre.sh" "${SEQURE_BUILD_ARGS[@]+"${SEQURE_BUILD_ARGS[@]}"}"

msg "Bundling Codon/Sequre assets for Rust"
CODON_PATH="$CODON_PATH" "$ROOT_DIR/bin_libs.sh"

if [ "$CLEAN" -eq 1 ]; then
  msg "Cleaning previous syqure build"
  cargo clean -p syqure
  rm -rf "$SYQURE_CACHE_DIR"
fi

msg "Running syqure example"
export SYQURE_BUNDLE_FILE="$BUNDLE_FILE"
export SYQURE_BUNDLE_CACHE="$SYQURE_CACHE_DIR"
cargo run -p syqure -- example/two_party_sum_simple.codon
