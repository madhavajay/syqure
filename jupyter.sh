#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Setting up Jupyter environment..."

# Create/clear venv
uv venv --clear

# Install Jupyter and dependencies
echo "Installing Jupyter and dependencies..."
uv pip install -U jupyter jupyterlab ipykernel

# Build and install syqure Python package
echo "Building and installing syqure..."
./install-python.sh

echo "Starting Jupyter Lab..."
source .venv/bin/activate
jupyter lab --notebook-dir=notebooks
