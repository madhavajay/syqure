#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODON_PATH="$ROOT_DIR/bin/codon"
BUNDLE_FILE="$ROOT_DIR/syqure/bundles/$(rustc -vV | awk '/host:/{print $2}').tar.zst"
SYQURE_CACHE_DIR="$ROOT_DIR/target/syqure-cache"

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

msg "Building Codon + LLVM shared (this can take a while)"
export CODON_ENABLE_OPENMP=OFF
CODON_BUILD_ARGS=()
if [ "$CLEAN" -eq 1 ]; then
  CODON_BUILD_ARGS+=(--clean)
fi
"$ROOT_DIR/compile_codon_linux.sh" "${CODON_BUILD_ARGS[@]}"

msg "Building Sequre plugin against repo-local Codon"
CODON_PATH="$CODON_PATH" "$ROOT_DIR/compile_sequre.sh"

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
