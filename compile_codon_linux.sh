#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Configuration (override by exporting CODON_DIR/LLVM_OVERRIDE/BUILD_TYPE)
CODON_DIR="${CODON_DIR:-$SCRIPT_DIR/codon}"
INSTALL_DIR="$CODON_DIR/install"
BIN_DIR="${BIN_DIR:-$SCRIPT_DIR/bin}"
LLVM_OVERRIDE="${LLVM_OVERRIDE:-}"
LLVM_BRANCH="${LLVM_BRANCH:-codon-17.0.6}"
BUILD_TYPE="${BUILD_TYPE:-Release}"
LLVM_TARGETS="${LLVM_TARGETS:-X86}"
LLVM_BUILD_DYLIB="ON"
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
    rm -rf "$CODON_DIR/llvm-project"
    rm -rf "$CODON_DIR/build"
    rm -rf "$CODON_DIR/jupyter/build"
    rm -rf "$CODON_DIR/install"
    echo "Clean complete, continuing with build..."
elif [ "$CLEAN" -eq 1 ]; then
    echo "=== Cleaning build directories ==="
    rm -rf "$CODON_DIR/llvm-project/build"
    rm -rf "$CODON_DIR/build"
    rm -rf "$CODON_DIR/jupyter/build"
    rm -rf "$CODON_DIR/install"
    echo "Clean complete, continuing with build..."
fi

CORES="$(command -v nproc >/dev/null 2>&1 && nproc || getconf _NPROCESSORS_ONLN)"
GENERATOR="${CMAKE_GENERATOR:-Ninja}"
if ! command -v ninja >/dev/null 2>&1; then
    GENERATOR="Unix Makefiles"
fi

cd "$CODON_DIR"

# Step 1: Choose or build LLVM (Codon's fork)
REBUILD_LLVM=0
if [ -n "$LLVM_OVERRIDE" ] && [ -d "$LLVM_OVERRIDE" ]; then
    LLVM_DIR="$LLVM_OVERRIDE"
    echo "=== Using LLVM override at $LLVM_DIR ==="
elif [ -d "$CODON_DIR/llvm-project/install/lib/cmake/llvm" ]; then
    if [ "$LLVM_BUILD_DYLIB" = "ON" ] && ! ls "$CODON_DIR/llvm-project/install/lib"/libLLVM*.so* >/dev/null 2>&1; then
        echo "=== LLVM install missing libLLVM.so; rebuilding with LLVM_BUILD_DYLIB=ON ==="
        rm -rf "$CODON_DIR/llvm-project/build"
        rm -rf "$CODON_DIR/llvm-project/install"
        REBUILD_LLVM=1
    else
        LLVM_DIR="$CODON_DIR/llvm-project/install/lib/cmake/llvm"
        echo "=== LLVM already built, using $LLVM_DIR ==="
    fi
else
    REBUILD_LLVM=1
fi

if [ "$REBUILD_LLVM" -eq 1 ]; then
    echo "=== Building LLVM from source (this takes 30-60 min) ==="
    if [ ! -d "llvm-project/.git" ]; then
        rm -rf llvm-project
        echo "Cloning llvm-project (${LLVM_BRANCH}) with retries..."
        for attempt in 1 2 3; do
            if git clone -b "$LLVM_BRANCH" --depth 1 https://github.com/exaloop/llvm-project; then
                break
            fi
            echo "Clone attempt ${attempt} failed; retrying in 10s" >&2
            sleep 10
        done
        if [ ! -d "llvm-project/.git" ]; then
            echo "git clone failed, trying to fetch tarball..." >&2
            mkdir -p llvm-project
            tmp_tar="$(mktemp -t llvm-project-XXXXXX.tar.gz)"
            if curl -L "https://codeload.github.com/exaloop/llvm-project/tar.gz/${LLVM_BRANCH}" -o "$tmp_tar"; then
                tar -xzf "$tmp_tar" --strip-components=1 -C llvm-project
                rm -f "$tmp_tar"
            fi
        fi
        if [ ! -d "llvm-project/.git" ] && [ ! -d "llvm-project/llvm" ] && [ ! -f "llvm-project/CMakeLists.txt" ]; then
            echo "Error: failed to obtain exaloop/llvm-project (clone and tarball both failed)" >&2
            exit 1
        fi
    fi
    cmake -S llvm-project/llvm -B llvm-project/build -G "$GENERATOR" \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF \
        -DLLVM_ENABLE_RTTI=ON \
        -DLLVM_ENABLE_ZLIB=OFF \
        -DLLVM_ENABLE_TERMINFO=OFF \
        -DLLVM_BUILD_LLVM_DYLIB="$LLVM_BUILD_DYLIB" \
        -DLLVM_LINK_LLVM_DYLIB="$LLVM_BUILD_DYLIB" \
        -DLLVM_TARGETS_TO_BUILD="$LLVM_TARGETS" \
        -DCMAKE_C_COMPILER="${CC:-clang}" \
        -DCMAKE_CXX_COMPILER="${CXX:-clang++}"
    cmake --build llvm-project/build -j"$CORES"
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
cmake -S . -B build -G "$GENERATOR" \
    -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DLLVM_DIR="$LLVM_DIR" \
    -DLLVM_LINK_LLVM_DYLIB="$LLVM_BUILD_DYLIB" \
    -DCODON_ENABLE_OPENMP="${OPENMP_FLAG}" \
    -DCMAKE_C_COMPILER="${CC:-clang}" \
    -DCMAKE_CXX_COMPILER="${CXX:-clang++}"
cmake --build build --config "${BUILD_TYPE}" -j"$CORES"
cmake --install build --prefix="$INSTALL_DIR"

# Step 2.5: Copy install into repo-local bin (isolated from ~/.codon)
echo "=== Copying Codon install to ${BIN_DIR}/codon ==="
rm -rf "${BIN_DIR}/codon"
mkdir -p "$BIN_DIR"
cp -a "$INSTALL_DIR" "${BIN_DIR}/codon"

# Step 3: Build Jupyter plugin
echo "=== Building Jupyter Plugin (${BUILD_TYPE}) ==="
OPENSSL_ROOT_DIR="${OPENSSL_ROOT_DIR:-$(openssl version -d 2>/dev/null | awk -F'\"' '{print $2}')}"
OPENSSL_CRYPTO_LIBRARY="${OPENSSL_CRYPTO_LIBRARY:-/usr/lib/libssl.so}"
LIBUUID_LIBRARY="${LIBUUID_LIBRARY:-}"
LIBUUID_INCLUDE_DIR="${LIBUUID_INCLUDE_DIR:-}"
if [ -z "$LIBUUID_LIBRARY" ]; then
    if command -v pkg-config >/dev/null 2>&1; then
        uuid_libdir="$(pkg-config --variable=libdir uuid 2>/dev/null || true)"
        if [ -n "$uuid_libdir" ] && [ -f "$uuid_libdir/libuuid.so" ]; then
            LIBUUID_LIBRARY="$uuid_libdir/libuuid.so"
        fi
    fi
fi
if [ -z "$LIBUUID_LIBRARY" ]; then
    for dir in /usr/lib /usr/lib64 /lib /lib64; do
        if [ -f "$dir/libuuid.so" ]; then
            LIBUUID_LIBRARY="$dir/libuuid.so"
            break
        fi
    done
fi
if [ -z "$LIBUUID_INCLUDE_DIR" ] && [ -f /usr/include/uuid/uuid.h ]; then
    LIBUUID_INCLUDE_DIR="/usr/include"
fi
cmake -S jupyter -B jupyter/build -G "$GENERATOR" \
    -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCODON_ENABLE_OPENMP="${OPENMP_FLAG}" \
    -DCMAKE_C_COMPILER="${CC:-clang}" \
    -DCMAKE_CXX_COMPILER="${CXX:-clang++}" \
    -DLLVM_DIR="$LLVM_DIR" \
    -DCODON_PATH="$INSTALL_DIR" \
    -DOPENSSL_ROOT_DIR="$OPENSSL_ROOT_DIR" \
    -DOPENSSL_CRYPTO_LIBRARY="$OPENSSL_CRYPTO_LIBRARY" \
    ${LIBUUID_LIBRARY:+-DLIBUUID_LIBRARY="$LIBUUID_LIBRARY"} \
    ${LIBUUID_INCLUDE_DIR:+-DLIBUUID_INCLUDE_DIR="$LIBUUID_INCLUDE_DIR"}
cmake --build jupyter/build --config "${BUILD_TYPE}" -j"$CORES"
cmake --install jupyter/build --prefix="$INSTALL_DIR"

# Step 4: Install Jupyter kernel (optional)
if [ "$SKIP_JUPYTER_KERNEL" = "1" ]; then
    echo "=== Skipping Jupyter Kernel install (SKIP_JUPYTER_KERNEL=1) ==="
else
    echo "=== Installing Jupyter Kernel ==="
    KERNEL_DIR="$HOME/.local/share/jupyter/kernels/codon"
    mkdir -p "$KERNEL_DIR"
    if ! cat > "$KERNEL_DIR/kernel.json" << KERNEL
{
    "display_name": "Codon",
    "argv": [
        "$INSTALL_DIR/bin/codon",
        "jupyter",
        "{connection_file}"
    ],
    "language": "python"
}
KERNEL
    then
        echo "Warning: failed to write Jupyter kernel spec; continuing." >&2
    else
        echo "Jupyter kernel installed to: $KERNEL_DIR"
    fi
fi

echo ""
echo "=== Done! ==="
