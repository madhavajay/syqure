#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <image.tar.gz>" >&2
  exit 1
fi

ARCHIVE="$1"

if [ ! -f "$ARCHIVE" ]; then
  echo "File not found: $ARCHIVE" >&2
  exit 1
fi

echo "Loading image from ${ARCHIVE}"
gzip -dc "$ARCHIVE" | docker load
echo "Done."
