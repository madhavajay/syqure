#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Configuration (override by exporting CODON_DIR/LLVM_OVERRIDE/BUILD_TYPE)
CODON_DIR="${CODON_DIR:-$SCRIPT_DIR/codon}"
INSTALL_DIR="$CODON_DIR/install"
LLVM_OVERRIDE="${LLVM_OVERRIDE:-}"
BUILD_TYPE="${BUILD_TYPE:-Release}"
CLEAN=0
CLEAN_ALL=0
OPENMP_FLAG="${CODON_ENABLE_OPENMP:-ON}"
SKIP_JUPYTER_KERNEL="${SKIP_JUPYTER_KERNEL:-0}"

for arg in "$@"; do
    case "$arg" in
        --clean) CLEAN=1 ;;
        --clean-all) CLEAN_ALL=1 ;;
        --debug) BUILD_TYPE="Debug" ;;
        --relwithdebinfo) BUILD_TYPE="RelWithDebInfo" ;;
        --config=*) BUILD_TYPE="${arg#*=}" ;;
        --no-openmp) OPENMP_FLAG="OFF" ;;
        --openmp) OPENMP_FLAG="ON" ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

if [ "$CLEAN_ALL" -eq 1 ]; then
    echo "=== Cleaning everything including LLVM source ==="
    rm -rf "$CODON_DIR/llvm-project" 2>/dev/null || sudo rm -rf "$CODON_DIR/llvm-project"
    rm -rf "$CODON_DIR/build" 2>/dev/null || sudo rm -rf "$CODON_DIR/build"
    rm -rf "$CODON_DIR/jupyter/build" 2>/dev/null || sudo rm -rf "$CODON_DIR/jupyter/build"
    rm -rf "$CODON_DIR/install" 2>/dev/null || sudo rm -rf "$CODON_DIR/install"
    echo "Clean complete, continuing with build..."
elif [ "$CLEAN" -eq 1 ]; then
    echo "=== Cleaning build directories ==="
    rm -rf "$CODON_DIR/llvm-project/build" 2>/dev/null || sudo rm -rf "$CODON_DIR/llvm-project/build"
    rm -rf "$CODON_DIR/build" 2>/dev/null || sudo rm -rf "$CODON_DIR/build"
    rm -rf "$CODON_DIR/jupyter/build" 2>/dev/null || sudo rm -rf "$CODON_DIR/jupyter/build"
    rm -rf "$CODON_DIR/install" 2>/dev/null || sudo rm -rf "$CODON_DIR/install"
    echo "Clean complete, continuing with build..."
fi

# Detect architecture
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    LLVM_ARCH="arm64"
    HOMEBREW_PREFIX="/opt/homebrew"
else
    LLVM_ARCH="x86_64"
    HOMEBREW_PREFIX="/usr/local"
fi

# Detect OpenSSL path (Homebrew)
if [ -d "$HOMEBREW_PREFIX/opt/openssl" ]; then
    OPENSSL_ROOT="$HOMEBREW_PREFIX/opt/openssl"
else
    echo "Error: OpenSSL not found. Install with: brew install openssl"
    exit 1
fi

# Check for libgfortran
if [ -d "$HOMEBREW_PREFIX/opt/gcc/lib/gcc/current" ]; then
    export CODON_SYSTEM_LIBRARIES="$HOMEBREW_PREFIX/opt/gcc/lib/gcc/current"
else
    echo "Error: libgfortran not found. Install with: brew install gcc"
    exit 1
fi

echo "Architecture: $ARCH"
echo "Using OpenSSL: $OPENSSL_ROOT"
echo "Using libgfortran: $CODON_SYSTEM_LIBRARIES"
echo "OpenMP support: $OPENMP_FLAG"

cd "$CODON_DIR"

# Step 1: Choose or build LLVM (Codon's fork)
# Prefer an override (e.g., a shared codon-llvm install) if provided.
if [ -n "$LLVM_OVERRIDE" ] && [ -d "$LLVM_OVERRIDE" ]; then
    LLVM_DIR="$LLVM_OVERRIDE"
    echo "=== Using LLVM override at $LLVM_DIR ==="
# Skip codon-llvm (LLVM 20) - need older LLVM for Codon 0.17
# elif [ -d "$CODON_DIR/../codon-llvm/install/lib/cmake/llvm" ]; then
#     LLVM_DIR="$CODON_DIR/../codon-llvm/install/lib/cmake/llvm"
#     echo "=== Using sibling codon-llvm at $LLVM_DIR ==="
elif [ -d "$CODON_DIR/llvm-project/install/lib/cmake/llvm" ]; then
    LLVM_DIR="$CODON_DIR/llvm-project/install/lib/cmake/llvm"
    echo "=== LLVM already built, using $LLVM_DIR ==="
else
    echo "=== Building LLVM from source (this takes 30-60 min) ==="
    if [ ! -d "llvm-project/.git" ]; then
        rm -rf llvm-project
        # Use codon-17.0.6 tag (LLVM 17) for Codon 0.17.0 compatibility
        git clone -b codon-17.0.6 --depth 1 https://github.com/exaloop/llvm-project
    fi
    # Don't build OpenMP as part of LLVM - use Homebrew's libomp instead
    # This avoids the clang dependency for OpenMP tests
    cmake -S llvm-project/llvm -B llvm-project/build \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF \
        -DLLVM_ENABLE_RTTI=ON \
        -DLLVM_ENABLE_ZLIB=OFF \
        -DLLVM_ENABLE_ZSTD=OFF \
        -DLLVM_TARGETS_TO_BUILD="host"
    cmake --build llvm-project/build -j$(sysctl -n hw.ncpu)
    cmake --install llvm-project/build --prefix=llvm-project/install
    LLVM_DIR="$CODON_DIR/llvm-project/install/lib/cmake/llvm"
fi

# Verify LLVM exists
if [ ! -d "$LLVM_DIR" ]; then
    echo "Error: LLVM cmake dir not found at $LLVM_DIR"
    exit 1
fi

# Step 2: Build Codon
echo "=== Building Codon (${BUILD_TYPE}) ==="
mkdir -p build
# Respect LLVM_PREFIX from environment (set by build.sh), or use default
if [ -z "${LLVM_PREFIX:-}" ]; then
    LLVM_PREFIX="/opt/homebrew/opt/llvm"
fi
# Use nostdlib++ to avoid mixing system and Homebrew libc++
cmake -S . -B build \
    -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DLLVM_DIR="$LLVM_DIR" \
    -DCODON_ENABLE_OPENMP="${OPENMP_FLAG}" \
    -DCMAKE_C_COMPILER="$LLVM_PREFIX/bin/clang" \
    -DCMAKE_CXX_COMPILER="$LLVM_PREFIX/bin/clang++" \
    -DCMAKE_CXX_FLAGS="-stdlib=libc++ -nostdinc++ -isystem $LLVM_PREFIX/include/c++/v1 -include cstdlib -Wno-error=character-conversion" \
    -DCMAKE_EXE_LINKER_FLAGS="-nostdlib++ -L$LLVM_PREFIX/lib/c++ -Wl,-rpath,$LLVM_PREFIX/lib/c++ -lc++ -lc++abi" \
    -DCMAKE_SHARED_LINKER_FLAGS="-nostdlib++ -L$LLVM_PREFIX/lib/c++ -Wl,-rpath,$LLVM_PREFIX/lib/c++ -lc++ -lc++abi"
cmake --build build --config "${BUILD_TYPE}" -j$(sysctl -n hw.ncpu)
cmake --install build --prefix="$INSTALL_DIR"

# Step 3: Build Jupyter plugin
echo "=== Building Jupyter Plugin (${BUILD_TYPE}) ==="
OPENSSL_ROOT_DIR="$OPENSSL_ROOT" cmake -S jupyter -B jupyter/build \
    -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCODON_ENABLE_OPENMP="${OPENMP_FLAG}" \
    -DCMAKE_C_COMPILER="$LLVM_PREFIX/bin/clang" \
    -DCMAKE_CXX_COMPILER="$LLVM_PREFIX/bin/clang++" \
    -DCMAKE_CXX_FLAGS="-stdlib=libc++ -nostdinc++ -isystem $LLVM_PREFIX/include/c++/v1 -include cstdlib" \
    -DCMAKE_EXE_LINKER_FLAGS="-nostdlib++ -L$LLVM_PREFIX/lib/c++ -Wl,-rpath,$LLVM_PREFIX/lib/c++ -lc++ -lc++abi" \
    -DCMAKE_SHARED_LINKER_FLAGS="-nostdlib++ -L$LLVM_PREFIX/lib/c++ -Wl,-rpath,$LLVM_PREFIX/lib/c++ -lc++ -lc++abi" \
    -DLLVM_DIR="$LLVM_DIR" \
    -DCODON_PATH="$INSTALL_DIR"
cmake --build jupyter/build --config "${BUILD_TYPE}" -j$(sysctl -n hw.ncpu)
cmake --install jupyter/build --prefix="$INSTALL_DIR"

# Step 4: Install Jupyter kernel (optional)
if [ "$SKIP_JUPYTER_KERNEL" = "1" ]; then
    echo "=== Skipping Jupyter Kernel install (SKIP_JUPYTER_KERNEL=1) ==="
else
    echo "=== Installing Jupyter Kernel ==="
    KERNEL_DIR="$HOME/Library/Jupyter/kernels/codon"
    mkdir -p "$KERNEL_DIR"
    if ! cat > "$KERNEL_DIR/kernel.json" << EOF
{
    "display_name": "Codon",
    "argv": [
        "$INSTALL_DIR/bin/codon",
        "jupyter",
        "{connection_file}"
    ],
    "language": "python"
}
EOF
    then
        echo "Warning: failed to write Jupyter kernel spec; continuing." >&2
    else
        echo "Jupyter kernel installed to: $KERNEL_DIR"
    fi
fi

echo ""
echo "=== Done! ==="
echo "Codon installed to: $INSTALL_DIR/bin/codon"
echo ""
echo "Add to PATH with:"
echo "  export PATH=\"$INSTALL_DIR/bin:\$PATH\""
