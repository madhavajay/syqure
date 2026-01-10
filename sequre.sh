#!/usr/bin/env bash
set -euo pipefail

# Usage: ./sequre.sh path/to/example.codon [-- codon args]
# Pre-req: CODON_PATH points at your Codon install (defaults to ~/.codon).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODON_PATH_DEFAULT="$HOME/.codon"
CODON_PATH="${CODON_PATH:-$CODON_PATH_DEFAULT}"

if [ $# -lt 1 ]; then
  echo "Usage: $0 <file.codon> [-- extra codon args]" >&2
  exit 1
fi

TARGET="$1"; shift || true

# Clean stale sockets
find . -name 'sock.*' -exec rm {} \; 2>/dev/null || true

CMD=("${CODON_PATH}/bin/codon" run --disable-opt="core-pythonic-list-addition-opt" -plugin sequre "$TARGET")
if [ "$#" -gt 0 ]; then
  CMD+=("$@")
fi

export CODON_DEBUG=lt
exec "${CMD[@]}"
