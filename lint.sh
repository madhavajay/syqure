#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "==> cargo fmt (check)"
cargo fmt --all -- --check

echo "==> cargo clippy (warnings as errors)"
cargo clippy --workspace --all-targets --no-deps -- -D warnings

echo "✓ Rust lint checks passed"