#!/usr/bin/env bash
set -euo pipefail

# Build and package a self-contained Python wheel that bundles Codon/Sequre libs
# using the same bundle approach as the Rust syqure CLI.
#
# Usage:
#   ./build_python.sh          # Build release wheel
#   ./build_python.sh --dev    # Development install (editable)
#   ./build_python.sh --test   # Build and run tests
#   ./build_python.sh --shell  # Enter venv shell

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$ROOT_DIR/.venv-maturin"

# Parse args
DEV_MODE=false
TEST_MODE=false
SHELL_MODE=false
SKIP_LIBS=false

for arg in "$@"; do
    case "$arg" in
        --dev) DEV_MODE=true ;;
        --test) TEST_MODE=true; DEV_MODE=true ;;
        --shell) SHELL_MODE=true ;;
        --skip-libs) SKIP_LIBS=true ;;
    esac
done

# 1) Setup venv with uv
setup_venv() {
    if ! command -v uv >/dev/null 2>&1; then
        echo "==> Installing uv..."
        curl -LsSf https://astral.sh/uv/install.sh | sh
        export PATH="$HOME/.cargo/bin:$PATH"
    fi

    if [ ! -d "$VENV_DIR" ]; then
        echo "==> Creating venv at $VENV_DIR"
        uv venv "$VENV_DIR"
    fi

    # Activate venv
    source "$VENV_DIR/bin/activate"

    # Install maturin if needed
    if ! command -v maturin >/dev/null 2>&1; then
        echo "==> Installing maturin..."
        uv pip install maturin
    fi
}

# 2) Detect or build bundle
setup_bundle() {
    TRIPLE="$(rustc -vV | grep host: | awk '{print $2}')"
    BUNDLE_OUT="$ROOT_DIR/syqure/bundles/${TRIPLE}.tar.zst"

    if [ -f "$BUNDLE_OUT" ]; then
        echo "==> Using existing bundle: $BUNDLE_OUT"
    elif [ "$SKIP_LIBS" = true ]; then
        echo "Error: Bundle not found at $BUNDLE_OUT and --skip-libs specified" >&2
        exit 1
    else
        echo "==> Building Codon/Sequre libs and creating bundle..."
        export CODON_PATH="${CODON_PATH:-$ROOT_DIR/codon/install}"
        "$ROOT_DIR/build_libs.sh"

        if [ ! -f "$BUNDLE_OUT" ]; then
            echo "Error: Bundle not found at $BUNDLE_OUT after build" >&2
            exit 1
        fi
    fi

    export SYQURE_BUNDLE_FILE="$BUNDLE_OUT"
}

# 3) Build wheel
build_wheel() {
    cd "$ROOT_DIR"

    if [ "$DEV_MODE" = true ]; then
        echo "==> Development install (maturin develop)"
        maturin develop --manifest-path python/Cargo.toml
    else
        echo "==> Building release wheel"
        maturin build --release --manifest-path python/Cargo.toml
        echo "==> Wheel(s) available under target/wheels"
    fi
}

# 4) Run tests
run_tests() {
    echo "==> Running Python tests"
    python -c "
import syqure
print('syqure version:', syqure.version())
print()
print('syqure.info():')
import pprint
pprint.pprint(syqure.info())
print()
print('Testing import and basic functionality...')
print('All tests passed!')
"
}

# Main
setup_venv

if [ "$SHELL_MODE" = true ]; then
    echo "==> Entering venv shell (exit to leave)"
    echo "    VENV: $VENV_DIR"
    echo "    Run: python -c 'import syqure; print(syqure.info())'"
    exec "$SHELL" -i
fi

setup_bundle
build_wheel

if [ "$TEST_MODE" = true ]; then
    run_tests
fi

echo ""
echo "==> Done!"
echo "    Activate venv: source $VENV_DIR/bin/activate"
echo "    Test: python -c 'import syqure; print(syqure.version())'"
