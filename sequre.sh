#!/usr/bin/env bash
set -euo pipefail

# Usage: ./sequre.sh path/to/example.codon [-- program args]
# Thin wrapper that delegates to the Rust CLI (syqure) so we share its bundling/linking fixes.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"

if [ $# -lt 1 ]; then
  echo "Usage: $0 <file.codon> [-- extra program args]" >&2
  exit 1
fi

TARGET="$1"; shift || true

# Clean stale sockets (syqure also does this, but it is cheap).
find "$ROOT_DIR" -name 'sock.*' -exec rm {} \; 2>/dev/null || true

# Prefer an existing debug build; fall back to cargo run so the caller gets logs.
SYQURE_BIN="$ROOT_DIR/target/debug/syqure"
if [ -x "$SYQURE_BIN" ]; then
  exec "$SYQURE_BIN" "$TARGET" "$@"
fi

exec cargo run -p syqure -- "$TARGET" "$@"
