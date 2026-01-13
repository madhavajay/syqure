#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CODON_PATH="${CODON_PATH:-$ROOT_DIR/codon/install}"
export XZ_SOURCE_DIR="${XZ_SOURCE_DIR:-$ROOT_DIR/codon/build/_deps/xz-src}"

WHEEL_OUT="${WHEEL_OUT:-$ROOT_DIR/target/wheels}"
BUNDLED_OUT="${BUNDLED_OUT:-$ROOT_DIR/target/wheels-bundled}"

if [[ "${SKIP_LIBS:-0}" != "1" ]]; then
  echo "==> Building Codon/Sequre libs and creating bundle (./build_libs.sh)"
  "$ROOT_DIR/build_libs.sh"
fi

TRIPLE="$(rustc -vV | awk '/host:/{print $2}')"
BUNDLE_OUT="$ROOT_DIR/syqure/bundles/${TRIPLE}.tar.zst"

if [[ ! -f "$BUNDLE_OUT" ]]; then
  echo "Error: Bundle not found at $BUNDLE_OUT" >&2
  exit 1
fi

if ! command -v maturin >/dev/null 2>&1; then
  echo "maturin not found; install with: pip install maturin" >&2
  exit 1
fi

if ! python3 -c "import wheel" >/dev/null 2>&1; then
  echo "python module 'wheel' not installed; install with: pip install wheel" >&2
  exit 1
fi

mkdir -p "$WHEEL_OUT" "$BUNDLED_OUT"

export SYQURE_SKIP_BUNDLE_UNPACK=1
echo "==> Building wheel without bundle unpack"
maturin build --release --manifest-path "$ROOT_DIR/python/Cargo.toml" --out "$WHEEL_OUT"

echo "==> Injecting bundle into wheel(s)"
for whl in "$WHEEL_OUT"/*.whl; do
  [[ -e "$whl" ]] || continue
  tmpdir="$(mktemp -d)"
  python3 -m wheel unpack "$whl" -d "$tmpdir"

  unpacked_dir="$(find "$tmpdir" -maxdepth 1 -type d -name 'syqure-*' | head -n 1)"
  if [[ -z "$unpacked_dir" ]]; then
    echo "Error: Could not find unpacked wheel dir in $tmpdir" >&2
    rm -rf "$tmpdir"
    exit 1
  fi

  pkg_dir="$(find "$unpacked_dir" -type d -name syqure | head -n 1)"
  if [[ -z "$pkg_dir" ]]; then
    echo "Error: Could not find package dir in $unpacked_dir" >&2
    rm -rf "$tmpdir"
    exit 1
  fi

  mkdir -p "$pkg_dir/lib"
  zstd -d -c "$BUNDLE_OUT" | tar -x -C "$pkg_dir/lib"
  python3 -m wheel pack "$unpacked_dir" -d "$BUNDLED_OUT"
  rm -rf "$tmpdir"
done

echo "==> Bundled wheel(s) available under $BUNDLED_OUT"
