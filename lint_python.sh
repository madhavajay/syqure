#!/usr/bin/env bash
set -euo pipefail

# Lint and format Python code using ruff
#
# Usage:
#   ./lint_python.sh          # Check for lint errors
#   ./lint_python.sh --fix    # Fix auto-fixable issues
#   ./lint_python.sh --format # Format code

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$ROOT_DIR/.venv-maturin"

FIX=false
FORMAT=false

for arg in "$@"; do
    case "$arg" in
        --fix) FIX=true ;;
        --format) FORMAT=true ;;
    esac
done

# Setup venv with ruff
setup_ruff() {
    if ! command -v uv >/dev/null 2>&1; then
        echo "==> Installing uv..."
        curl -LsSf https://astral.sh/uv/install.sh | sh
        export PATH="$HOME/.cargo/bin:$PATH"
    fi

    if [ ! -d "$VENV_DIR" ]; then
        echo "==> Creating venv at $VENV_DIR"
        uv venv "$VENV_DIR"
    fi

    source "$VENV_DIR/bin/activate"

    if ! python -c "import ruff" 2>/dev/null; then
        echo "==> Installing ruff..."
        uv pip install ruff
    fi
}

setup_ruff

cd "$ROOT_DIR/python"

if [ "$FORMAT" = true ]; then
    echo "==> Formatting Python code..."
    ruff format syqure/
    echo "==> Done!"
elif [ "$FIX" = true ]; then
    echo "==> Fixing lint issues..."
    ruff check --fix syqure/
    ruff format syqure/
    echo "==> Done!"
else
    echo "==> Checking Python code..."
    ruff check syqure/
    ruff format --check syqure/
    echo "==> All checks passed!"
fi
