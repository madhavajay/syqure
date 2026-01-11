#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="${IMAGE_NAME:-sequre-binary}"
DOCKERFILE="${DOCKERFILE:-$SCRIPT_DIR/docker/Dockerfile.sequre}"

if [ ! -d "$SCRIPT_DIR/bin/codon" ]; then
  echo "Error: missing bin/codon. Run ./compile_codon_linux.sh or copy codon/install into bin/codon first." >&2
  exit 1
fi

if [ ! -x "$SCRIPT_DIR/bin/codon/bin/codon" ]; then
  echo "Error: missing Codon binary at bin/codon/bin/codon." >&2
  exit 1
fi

if [ ! -f "$DOCKERFILE" ]; then
  echo "Error: Dockerfile not found at $DOCKERFILE." >&2
  exit 1
fi

docker build -f "$DOCKERFILE" -t "$IMAGE_NAME" "$SCRIPT_DIR"
