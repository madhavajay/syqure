#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="${IMAGE_NAME:-syqure-cli-files}"
DOCKERFILE="${DOCKERFILE:-$SCRIPT_DIR/docker/Dockerfile.syqure}"

IMAGE_NAME="$IMAGE_NAME" DOCKERFILE="$DOCKERFILE" "$SCRIPT_DIR/build_docker_syqure.sh"
