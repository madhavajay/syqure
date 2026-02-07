#!/usr/bin/env bash
set -euo pipefail

# Build Codon/Sequre (with macOS-safe flags) and emit a bundle tar.zst
# containing libcodonc/libcodonrt, the Sequre plugin, and the Codon stdlib.
# If the syqure binary is already built, it is copied alongside.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODON_PATH="${CODON_PATH:-$ROOT_DIR/codon/install}"
export CODON_PATH
export XZ_SOURCE_DIR="${XZ_SOURCE_DIR:-$ROOT_DIR/codon/build/_deps/xz-src}"

echo "==> Building Codon + Sequre prerequisites (libs only)"
if [ "$(uname -s)" = "Darwin" ]; then
  if [ -z "${LLVM_PREFIX:-}" ]; then
    LLVM_PREFIX="$(brew --prefix llvm 2>/dev/null || true)"
  fi
  if [ -z "$LLVM_PREFIX" ] || [ ! -x "$LLVM_PREFIX/bin/clang" ]; then
    LLVM_PREFIX="/usr/local/opt/llvm"
  fi
  if [ ! -x "$LLVM_PREFIX/bin/clang" ] && command -v xcrun >/dev/null 2>&1; then
    # Fallback to Xcode clang
    LLVM_PREFIX="$(xcode-select --print-path)/Toolchains/XcodeDefault.xctoolchain/usr"
  fi
  export LLVM_PREFIX
  export CC="${CC:-$LLVM_PREFIX/bin/clang}"
  export CXX="${CXX:-$LLVM_PREFIX/bin/clang++}"
  export PATH="$LLVM_PREFIX/bin:$PATH"
  if [ "${SYQURE_SKIP_CODON:-0}" != "1" ]; then
    SKIP_JUPYTER_KERNEL=1 "$ROOT_DIR/compile_codon.sh" --no-openmp
  else
    echo "==> Skipping Codon build (SYQURE_SKIP_CODON=1)"
  fi
  if [ "${SYQURE_SKIP_SEQUER:-0}" != "1" ]; then
    SYQURE_SKIP_XZ=1 "$ROOT_DIR/compile_sequre.sh" --no-seq
  else
    echo "==> Skipping Sequre plugin build (SYQURE_SKIP_SEQUER=1)"
  fi
else
  if [ "${SYQURE_SKIP_CODON:-0}" != "1" ]; then
    "$ROOT_DIR/compile_codon.sh"
  else
    echo "==> Skipping Codon build (SYQURE_SKIP_CODON=1)"
  fi
  if [ "${SYQURE_SKIP_SEQUER:-0}" != "1" ]; then
    "$ROOT_DIR/compile_sequre.sh"
  else
    echo "==> Skipping Sequre plugin build (SYQURE_SKIP_SEQUER=1)"
  fi
fi

# Prepare a dist layout for bundling
DIST_DIR="$ROOT_DIR/target/dist/syqure"
BIN_SRC="$ROOT_DIR/target/release/syqure"
if [ ! -x "$BIN_SRC" ]; then
  BIN_SRC="$ROOT_DIR/target/debug/syqure"
fi
mkdir -p "$DIST_DIR/bin" "$DIST_DIR/lib"

if [ -x "$BIN_SRC" ]; then
  echo "==> Copying existing syqure binary into dist"
  cp "$BIN_SRC" "$DIST_DIR/bin/"
fi

echo "==> Copying Codon/Sequre libs into dist"
rm -rf "$DIST_DIR/lib/codon"
# Dereference symlinks so stdlib is bundled as real files.
# Prune broken symlinks in CODON_PATH to avoid copy failures (e.g. missing libgmp).
if [ -d "$CODON_PATH/lib/codon" ]; then
  find -L "$CODON_PATH/lib/codon" -type l -print -delete 2>/dev/null || true
  for f in "$CODON_PATH/lib/codon"/libgmp.*; do
    if [ -L "$f" ] && [ ! -e "$f" ]; then
      echo "==> Removing broken symlink: $f"
      rm -f "$f"
    fi
  done
fi
cp -R -L "$CODON_PATH/lib/codon" "$DIST_DIR/lib/"
# If libgmp is missing in CODON_PATH, fall back to bundled macOS binaries.
if [ ! -f "$DIST_DIR/lib/codon/libgmp.dylib" ] || [ ! -f "$DIST_DIR/lib/codon/libgmp.so" ]; then
  FALLBACK_GMP_DIR="$ROOT_DIR/bin/macos-arm64/codon/lib/codon"
  if [ -d "$FALLBACK_GMP_DIR" ]; then
    echo "==> Falling back to libgmp from $FALLBACK_GMP_DIR"
    cp -f "$FALLBACK_GMP_DIR"/libgmp.* "$DIST_DIR/lib/codon/" 2>/dev/null || true
  fi
fi
# Always replace stdlib with source checkout to avoid stale/broken symlinks.
if [ -d "$ROOT_DIR/codon/stdlib" ]; then
  echo "==> Refreshing bundled stdlib from source"
  rm -rf "$DIST_DIR/lib/codon/stdlib"
  cp -R "$ROOT_DIR/codon/stdlib" "$DIST_DIR/lib/codon/"
fi
# Always replace Sequre plugin stdlib from source checkout when available.
SEQUER_STDLIB_SRC="$ROOT_DIR/sequre/stdlib"
SEQUER_STDLIB_DST="$DIST_DIR/lib/codon/plugins/sequre/stdlib"
if [ -d "$SEQUER_STDLIB_SRC" ]; then
  echo "==> Refreshing bundled Sequre stdlib from source"
  rm -rf "$SEQUER_STDLIB_DST"
  mkdir -p "$(dirname "$SEQUER_STDLIB_DST")"
  cp -R "$SEQUER_STDLIB_SRC" "$SEQUER_STDLIB_DST"
fi

# Create a per-target bundle
TRIPLE="$(rustc -vV | awk '/host:/{print $2}')"
BUNDLE_OUT="$ROOT_DIR/syqure/bundles/${TRIPLE}.tar.zst"
mkdir -p "$(dirname "$BUNDLE_OUT")"
echo "==> Creating bundle $BUNDLE_OUT"
rm -f "$BUNDLE_OUT"
tar -C "$DIST_DIR" -c . | zstd -19 -o "$BUNDLE_OUT"

echo "==> Done. Bundle stored at $BUNDLE_OUT"
