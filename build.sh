#!/usr/bin/env bash
set -euo pipefail

# Unified build helper:
# - Builds Codon (macOS: --no-openmp)
# - Builds Sequre (macOS: --no-seq to skip Seq plugin)
# - Builds the Rust syqure CLI/library

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODON_PATH="${CODON_PATH:-$ROOT_DIR/codon/install}"
export CODON_PATH
export XZ_SOURCE_DIR="${XZ_SOURCE_DIR:-$ROOT_DIR/codon/build/_deps/xz-src}"

echo "==> Building Codon + Sequre prerequisites"
if [ "$(uname -s)" = "Darwin" ]; then
  SKIP_JUPYTER_KERNEL=1 "$ROOT_DIR/compile_codon.sh" --no-openmp
  SYQURE_SKIP_XZ=1 "$ROOT_DIR/compile_sequre.sh" --no-seq
else
  "$ROOT_DIR/compile_codon.sh"
  "$ROOT_DIR/compile_sequre.sh"
fi

echo "==> Building syqure Rust workspace"
cd "$ROOT_DIR"
cargo build -p syqure

echo "==> Done. You can now run:"
echo "    cargo run -p syqure -- example/two_party_sum_simple.codon"
