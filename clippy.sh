#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Enforce formatting for the whole workspace
cargo fmt --all

# Lint everything (lib + binary), treat warnings as errors
cargo clippy --fix --allow-dirty --workspace --all-targets --all-features --no-deps -- -D warnings
