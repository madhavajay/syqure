#!/usr/bin/env bash
# Build and install the Codon Jupyter kernel.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JUPYTER_DIR="$ROOT/codon/jupyter"
BUILD_DIR="$JUPYTER_DIR/build"

# Optional prebuilt plugin to avoid recompiling (override with CODON_JUPYTER_DYLIB)
# Prefer a prebuilt dylib in the repo root (avoids network fetch).
DEFAULT_PREBUILT="$ROOT/libcodon_jupyter.dylib"
PREBUILT_DYLIB="${CODON_JUPYTER_DYLIB:-$DEFAULT_PREBUILT}"

PREFIX="${CODON_PREFIX:-}"
# Default to the top-level install prefix if not provided
if [[ -z "$PREFIX" ]]; then
  PREFIX="$ROOT/codon/install"
fi
# Optional: where to install the kernelspec; default is Jupyter's user dir.
KERNEL_INSTALL_PREFIX="${KERNEL_INSTALL_PREFIX:-}"

if ! command -v jupyter >/dev/null 2>&1; then
  echo "jupyter not found on PATH; please install Jupyter first." >&2
  exit 1
fi

if [[ -f "$PREBUILT_DYLIB" ]]; then
  echo "Using prebuilt Jupyter plugin: $PREBUILT_DYLIB"
  mkdir -p "$PREFIX/lib/codon"
  cp "$PREBUILT_DYLIB" "$PREFIX/lib/codon/libcodon_jupyter.dylib"
else
  echo "Configuring Codon Jupyter plugin..."
  cmake -S "$JUPYTER_DIR" -B "$BUILD_DIR" \
    -DCODON_PATH="$PREFIX" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX/lib/codon" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5

  echo "Building codon_jupyter..."
  cmake --build "$BUILD_DIR" --target codon_jupyter

  echo "Installing codon_jupyter into the Codon prefix..."
  cmake --install "$BUILD_DIR"
fi

# Determine where the Codon install lives (CMake defaults to codon/install).
if [[ -z "${CODON_PREFIX:-}" && -f "$BUILD_DIR/CMakeCache.txt" ]]; then
  PREFIX="$(grep '^CODON_PATH:' "$BUILD_DIR/CMakeCache.txt" | cut -d= -f2-)"
fi

CODON_BIN="$PREFIX/bin/codon"
if [[ ! -x "$CODON_BIN" ]]; then
  echo "codon executable not found at $CODON_BIN; adjust CODON_PREFIX or rebuild Codon." >&2
  exit 1
fi

KERNEL_DIR="$(mktemp -d)"
mkdir -p "$KERNEL_DIR"
cat >"$KERNEL_DIR/kernel.json" <<EOF
{
    "display_name": "Codon",
    "argv": [
        "$CODON_BIN",
        "jupyter",
        "{connection_file}"
    ],
    "language": "python"
}
EOF

echo "Installing Jupyter kernelspec..."
if [[ -n "$KERNEL_INSTALL_PREFIX" ]]; then
  jupyter kernelspec install --name codon --prefix "$KERNEL_INSTALL_PREFIX" "$KERNEL_DIR"
else
  jupyter kernelspec install --user --name codon "$KERNEL_DIR"
fi

echo "Codon Jupyter kernel installed."
echo "You can verify with: jupyter kernelspec list | grep codon"
