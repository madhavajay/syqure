#!/usr/bin/env bash
set -euo pipefail

# Unified build helper:
# - Builds Codon (macOS: --no-openmp)
# - Builds Sequre (macOS: --no-seq to skip Seq plugin)
# - Builds the Rust syqure CLI/library

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODON_PATH="${CODON_PATH:-$ROOT_DIR/codon/install}"
export CODON_PATH
export XZ_SOURCE_DIR="${XZ_SOURCE_DIR:-$ROOT_DIR/codon/build/_deps/xz-src}"

# Choose an LLVM prefix on macOS if not provided.
if [ -z "${LLVM_PREFIX:-}" ] && [ "$(uname -s)" = "Darwin" ]; then
  LLVM_PREFIX="$(brew --prefix llvm 2>/dev/null || true)"
  if [ -z "$LLVM_PREFIX" ]; then
    LLVM_PREFIX="/usr/local/opt/llvm"
  fi
  export LLVM_PREFIX
  export PATH="$LLVM_PREFIX/bin:$PATH"
fi

echo "==> Building Codon + Sequre prerequisites"
if [ -d "$ROOT_DIR/codon/install/lib/codon" ] && [ -d "$ROOT_DIR/codon/install/lib/codon/plugins/sequre" ]; then
  echo "Codon/Sequre already built; skipping rebuild."
else
  if [ "$(uname -s)" = "Darwin" ]; then
    SKIP_JUPYTER_KERNEL=1 "$ROOT_DIR/compile_codon.sh" --no-openmp
    SYQURE_SKIP_XZ=1 "$ROOT_DIR/compile_sequre.sh" --no-seq
  else
    "$ROOT_DIR/compile_codon.sh"
    "$ROOT_DIR/compile_sequre.sh"
  fi
fi

echo "==> Building syqure Rust workspace"
cd "$ROOT_DIR"
TRIPLE="$(rustc -vV | grep host: | awk '{print $2}')"
BUNDLE_OUT="$ROOT_DIR/syqure/bundles/${TRIPLE}.tar.zst"
mkdir -p "$(dirname "$BUNDLE_OUT")"
echo "==> Creating bundle $BUNDLE_OUT"
rm -f "$BUNDLE_OUT"

# Bundle a portable tree with the binary and Codon/Sequre libs
DIST_DIR="$ROOT_DIR/target/dist/syqure"
BIN_SRC="$ROOT_DIR/target/debug/syqure"
mkdir -p "$DIST_DIR/bin" "$DIST_DIR/lib" "$DIST_DIR/include"
if [ -x "$BIN_SRC" ]; then
  cp "$BIN_SRC" "$DIST_DIR/bin/"
fi
if [ -d "$CODON_PATH/lib/codon" ]; then
  rm -rf "$DIST_DIR/lib/codon"
  cp -R "$CODON_PATH/lib/codon" "$DIST_DIR/lib/"
  # Some Codon builds look for plugins at lib/codon/sequre/...; provide a symlink to plugins/sequre.
  if [ -d "$DIST_DIR/lib/codon/plugins/sequre" ] && [ ! -e "$DIST_DIR/lib/codon/sequre" ]; then
    (cd "$DIST_DIR/lib/codon" && ln -s "plugins/sequre" "sequre") || true
  fi
fi
# Include LLVM runtime libs (libc++/libc++abi) so downstream runs don't need Homebrew LLVM.
if [ -n "${LLVM_PREFIX:-}" ]; then
  rm -rf "$DIST_DIR/lib/llvm"
  mkdir -p "$DIST_DIR/lib/llvm"
  if [ -d "$LLVM_PREFIX/lib/c++" ]; then
    cp -R "$LLVM_PREFIX/lib/c++/." "$DIST_DIR/lib/llvm/"
  fi
  # Homebrew may place libunwind under lib/ or lib/unwind; copy whichever exists.
  if ls "$LLVM_PREFIX/lib/libunwind."* >/dev/null 2>&1; then
    cp "$LLVM_PREFIX"/lib/libunwind.* "$DIST_DIR/lib/llvm/" || true
  elif ls "$LLVM_PREFIX/lib/unwind/libunwind."* >/dev/null 2>&1; then
    cp "$LLVM_PREFIX"/lib/unwind/libunwind.* "$DIST_DIR/lib/llvm/" || true
  fi
fi
# If libunwind still missing, drop in a copy/symlink from system locations so rpaths resolve.
if [ ! -f "$DIST_DIR/lib/llvm/libunwind.1.dylib" ]; then
  for cand in /usr/lib/libunwind.1.dylib /usr/lib/libunwind.dylib /usr/lib/system/libunwind.dylib; do
    if [ -f "$cand" ]; then
      cp "$cand" "$DIST_DIR/lib/llvm/libunwind.1.dylib" || ln -s "$cand" "$DIST_DIR/lib/llvm/libunwind.1.dylib" || true
      break
    fi
  done
fi
# Also drop a libunwind.dylib alias if we have a source.
if [ ! -f "$DIST_DIR/lib/llvm/libunwind.dylib" ] && [ -f "$DIST_DIR/lib/llvm/libunwind.1.dylib" ]; then
  ln -s "libunwind.1.dylib" "$DIST_DIR/lib/llvm/libunwind.dylib" || true
fi
# Include headers so downstream builds (Rust checks) can compile without rebuilding Codon.
if [ -d "$CODON_PATH/include" ]; then
  rm -rf "$DIST_DIR/include"
  mkdir -p "$DIST_DIR/include"
  cp -R "$CODON_PATH/include/." "$DIST_DIR/include/"
fi
# Also ship LLVM headers from the bundled toolchain.
if [ -d "$ROOT_DIR/codon/llvm-project/install/include" ]; then
  mkdir -p "$DIST_DIR/include"
  cp -R "$ROOT_DIR/codon/llvm-project/install/include/." "$DIST_DIR/include/"
fi

tar -C "$DIST_DIR" -c . | zstd -19 -o "$BUNDLE_OUT"

export SYQURE_BUNDLE_FILE="$BUNDLE_OUT"
cargo build -p syqure

echo "==> Done. You can now run:"
echo "    cargo run -p syqure -- example/two_party_sum_simple.codon"
