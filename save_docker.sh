#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <image> [output.tar.gz]" >&2
  exit 1
fi

IMAGE="$1"
OUTPUT="${2:-}"

if [ -z "$OUTPUT" ]; then
  safe_name="${IMAGE//[:\/]/_}"
  OUTPUT="${safe_name}.tar.gz"
fi

echo "Saving ${IMAGE} to ${OUTPUT}"
docker save "$IMAGE" | gzip -c > "$OUTPUT"
echo "Done."
