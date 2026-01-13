#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Configuration (override by exporting CODON_DIR/LLVM_OVERRIDE/BUILD_TYPE)
CODON_DIR="${CODON_DIR:-$SCRIPT_DIR/codon}"
INSTALL_DIR="$CODON_DIR/install"
ARCH_NAME="$(uname -m | tr '[:upper:]' '[:lower:]')"
ARCH_LABEL="$ARCH_NAME"
case "$ARCH_NAME" in
  arm64|aarch64) ARCH_LABEL="arm64" ;;
  x86_64|amd64|i386|i686) ARCH_LABEL="x86" ;;
esac
BIN_DIR_DEFAULT="$SCRIPT_DIR/bin/macos-$ARCH_LABEL"
BIN_DIR="${BIN_DIR:-$BIN_DIR_DEFAULT}"
LLVM_OVERRIDE="${LLVM_OVERRIDE:-}"
LLVM_BRANCH="${LLVM_BRANCH:-codon-17.0.6}"
BUILD_TYPE="${BUILD_TYPE:-Release}"
ARCH="$(uname -m | tr '[:upper:]' '[:lower:]')"
LLVM_TARGETS_DEFAULT="all"
case "$ARCH" in
  arm64|aarch64) LLVM_TARGETS_DEFAULT="AArch64" ;;
  x86_64|amd64) LLVM_TARGETS_DEFAULT="X86" ;;
esac
LLVM_TARGETS="${LLVM_TARGETS:-$LLVM_TARGETS_DEFAULT}"
LLVM_BUILD_DYLIB="ON"
CLEAN=0
CLEAN_ALL=0
OPENMP_FLAG="${CODON_ENABLE_OPENMP:-ON}"
SKIP_JUPYTER_KERNEL="${SKIP_JUPYTER_KERNEL:-0}"
SKIP_JUPYTER_BUILD="${SKIP_JUPYTER_BUILD:-0}"
FORCE_JUPYTER_BUILD="${FORCE_JUPYTER_BUILD:-0}"
CMAKE_POLICY_VERSION_MINIMUM="${CMAKE_POLICY_VERSION_MINIMUM:-3.5}"
CMAKE_POLICY_ARGS=("-DCMAKE_POLICY_VERSION_MINIMUM=$CMAKE_POLICY_VERSION_MINIMUM")
CC="${CC:-}"
CXX="${CXX:-}"
if [ -z "$CC" ]; then
    CC="/usr/bin/clang"
fi
if [ -z "$CXX" ]; then
    CXX="/usr/bin/clang++"
fi
export CC CXX
SDKROOT="${SDKROOT:-}"
if [ -z "$SDKROOT" ] && command -v xcrun >/dev/null 2>&1; then
    SDKROOT="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
fi
if [ -n "$SDKROOT" ]; then
    export SDKROOT
fi
CMAKE_OSX_SYSROOT_ARGS=()
if [ -n "$SDKROOT" ]; then
    CMAKE_OSX_SYSROOT_ARGS+=("-DCMAKE_OSX_SYSROOT=$SDKROOT")
fi

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

if command -v getconf >/dev/null 2>&1; then
    CORES="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
elif command -v sysctl >/dev/null 2>&1; then
    CORES="$(sysctl -n hw.ncpu 2>/dev/null || echo 1)"
else
    CORES=1
fi
GENERATOR="${CMAKE_GENERATOR:-Ninja}"
if ! command -v ninja >/dev/null 2>&1; then
    GENERATOR="Unix Makefiles"
fi

USE_LLVM_LIBCXX="${USE_LLVM_LIBCXX:-0}"
if [ "$USE_LLVM_LIBCXX" -eq 0 ]; then
    case "$CC:$CXX" in
        *"/opt/homebrew/opt/llvm/"*|*"/usr/local/opt/llvm/"*) USE_LLVM_LIBCXX=1 ;;
    esac
fi
LIBCXX_DIR=""
if [ "$USE_LLVM_LIBCXX" -eq 1 ]; then
    for candidate in /opt/homebrew/opt/llvm/lib/c++ /usr/local/opt/llvm/lib/c++; do
        if [ -d "$candidate" ]; then
            LIBCXX_DIR="$candidate"
            break
        fi
    done
fi
LIBCXX_LDFLAGS=""
if [ -n "$LIBCXX_DIR" ]; then
    LIBCXX_LDFLAGS="-L${LIBCXX_DIR} -Wl,-rpath,${LIBCXX_DIR}"
fi
CMAKE_LINK_ARGS=()
if [ -n "$LIBCXX_LDFLAGS" ]; then
    CMAKE_LINK_ARGS+=("-DCMAKE_SHARED_LINKER_FLAGS=$LIBCXX_LDFLAGS")
    CMAKE_LINK_ARGS+=("-DCMAKE_EXE_LINKER_FLAGS=$LIBCXX_LDFLAGS")
    CMAKE_LINK_ARGS+=("-DCMAKE_MODULE_LINKER_FLAGS=$LIBCXX_LDFLAGS")
fi

cd "$CODON_DIR"

# Step 1: Choose or build LLVM (Codon's fork)
REBUILD_LLVM=0
if [ -n "$LLVM_OVERRIDE" ] && [ -d "$LLVM_OVERRIDE" ]; then
    LLVM_DIR="$LLVM_OVERRIDE"
    echo "=== Using LLVM override at $LLVM_DIR ==="
elif [ -d "$CODON_DIR/llvm-project/install/lib/cmake/llvm" ]; then
    if [ "$LLVM_BUILD_DYLIB" = "ON" ] && ! ls "$CODON_DIR/llvm-project/install/lib"/libLLVM*.dylib >/dev/null 2>&1; then
        echo "=== LLVM install missing libLLVM.dylib; rebuilding with LLVM_BUILD_DYLIB=ON ==="
        rm -rf "$CODON_DIR/llvm-project/build"
        rm -rf "$CODON_DIR/llvm-project/install"
        REBUILD_LLVM=1
    else
        cache_cxx=""
        if command -v rg >/dev/null 2>&1; then
            cache_cxx="$(rg -n "^CMAKE_CXX_COMPILER:FILEPATH=" "$CODON_DIR/llvm-project/build/CMakeCache.txt" 2>/dev/null | head -n 1 | cut -d= -f2-)"
        else
            cache_cxx="$(grep -E "^CMAKE_CXX_COMPILER:FILEPATH=" "$CODON_DIR/llvm-project/build/CMakeCache.txt" 2>/dev/null | head -n 1 | cut -d= -f2-)"
        fi
        if [ -n "$cache_cxx" ] && [ "$cache_cxx" != "$CXX" ]; then
            echo "=== LLVM build compiler mismatch: cache=$cache_cxx expected=$CXX ==="
            echo "=== Cleaning LLVM build/install to reconfigure with the correct toolchain ==="
            rm -rf "$CODON_DIR/llvm-project/build"
            rm -rf "$CODON_DIR/llvm-project/install"
            REBUILD_LLVM=1
        else
            LLVM_DIR="$CODON_DIR/llvm-project/install/lib/cmake/llvm"
            echo "=== LLVM already built, using $LLVM_DIR ==="
        fi
    fi
else
    REBUILD_LLVM=1
fi

if [ "$REBUILD_LLVM" -eq 1 ]; then
    echo "=== Building LLVM from source (this takes 30-60 min) ==="
    if [ -d "llvm-project/.git" ] && [ ! -d "llvm-project/llvm" ]; then
        echo "=== llvm-project checkout missing llvm/; re-cloning ===" >&2
        rm -rf llvm-project
    fi
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
        -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_CXX_COMPILER="$CXX" \
        "${CMAKE_OSX_SYSROOT_ARGS[@]}" \
        "${CMAKE_POLICY_ARGS[@]}"
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
CPM_VERSION="0.32.3"
CPM_PATH="$CODON_DIR/build/cmake/CPM_${CPM_VERSION}.cmake"
if [ ! -s "$CPM_PATH" ]; then
    mkdir -p "$(dirname "$CPM_PATH")"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "https://github.com/TheLartians/CPM.cmake/releases/download/v${CPM_VERSION}/CPM.cmake" -o "$CPM_PATH" || true
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$CPM_PATH" "https://github.com/TheLartians/CPM.cmake/releases/download/v${CPM_VERSION}/CPM.cmake" || true
    fi
    if [ ! -s "$CPM_PATH" ]; then
        echo "Error: failed to download CPM.cmake to $CPM_PATH" >&2
        echo "Check network access or download it manually before rerunning." >&2
        exit 1
    fi
fi
patch_bdwgc_minimum() {
    local bdwgc_cmake="$CODON_DIR/build/_deps/bdwgc-src/CMakeLists.txt"
    if [ ! -f "$bdwgc_cmake" ]; then
        return 0
    fi
    python3 - <<'PY' "$bdwgc_cmake"
import re
import sys

path = sys.argv[1]
text = open(path, "r", encoding="utf-8").read()
m = re.search(r"cmake_minimum_required\(VERSION\s+([0-9]+)\.([0-9]+)", text)
if not m:
    sys.exit(0)
major, minor = int(m.group(1)), int(m.group(2))
if (major, minor) >= (3, 5):
    sys.exit(0)
new_text = re.sub(
    r"cmake_minimum_required\(VERSION\s+([0-9]+)\.([0-9]+)([^)]*)\)",
    "cmake_minimum_required(VERSION 3.5)",
    text,
    count=1,
)
if new_text != text:
    open(path, "w", encoding="utf-8").write(new_text)
    print("Patched bdwgc CMakeLists.txt to require CMake 3.5+ for CMake >=4.")
PY
}
patch_bdwgc_minimum
echo "=== Building Codon (${BUILD_TYPE}) ==="
mkdir -p build
cmake -S . -B build -G "$GENERATOR" \
    -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
    -DLLVM_DIR="$LLVM_DIR" \
    -DLLVM_LINK_LLVM_DYLIB="$LLVM_BUILD_DYLIB" \
    -DCODON_ENABLE_OPENMP="${OPENMP_FLAG}" \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_CXX_COMPILER="$CXX" \
    "${CMAKE_OSX_SYSROOT_ARGS[@]}" \
    "${CMAKE_POLICY_ARGS[@]}" \
    "${CMAKE_LINK_ARGS[@]}"
cmake --build build --config "${BUILD_TYPE}" -j"$CORES"
cmake --install build --prefix="$INSTALL_DIR"

# Step 2.5: Copy install into repo-local bin (isolated from ~/.codon)
echo "=== Copying Codon install to ${BIN_DIR}/codon ==="
rm -rf "${BIN_DIR}/codon"
mkdir -p "$BIN_DIR"
cp -a "$INSTALL_DIR" "${BIN_DIR}/codon"

# Step 3: Build Jupyter plugin
JUPYTER_LIB_PATH="$INSTALL_DIR/libcodon_jupyter.dylib"
if [ "$SKIP_JUPYTER_BUILD" = "1" ]; then
    echo "=== Skipping Jupyter Plugin build (SKIP_JUPYTER_BUILD=1) ==="
elif [ "$FORCE_JUPYTER_BUILD" != "1" ] && [ -f "$JUPYTER_LIB_PATH" ] && [ -f "$CODON_DIR/jupyter/build/libcodon_jupyter.dylib" ]; then
    echo "=== Jupyter Plugin already built; skipping (set FORCE_JUPYTER_BUILD=1 to rebuild) ==="
else
echo "=== Building Jupyter Plugin (${BUILD_TYPE}) ==="
OPENSSL_ROOT_DIR="${OPENSSL_ROOT_DIR:-}"
if [ -z "$OPENSSL_ROOT_DIR" ] && command -v brew >/dev/null 2>&1; then
    for formula in openssl@3 openssl@1.1; do
        prefix="$(brew --prefix "$formula" 2>/dev/null || true)"
        if [ -n "$prefix" ] && [ -d "$prefix" ]; then
            OPENSSL_ROOT_DIR="$prefix"
            break
        fi
    done
fi
if [ -z "$OPENSSL_ROOT_DIR" ]; then
    OPENSSL_ROOT_DIR="$(openssl version -d 2>/dev/null | awk -F'\"' '{print $2}')"
fi
OPENSSL_CRYPTO_LIBRARY="${OPENSSL_CRYPTO_LIBRARY:-}"
OPENSSL_SSL_LIBRARY="${OPENSSL_SSL_LIBRARY:-}"
OPENSSL_INCLUDE_DIR="${OPENSSL_INCLUDE_DIR:-}"

find_lib() {
    local libname="$1"
    local search_dirs=(
        "$OPENSSL_ROOT_DIR/lib"
        /usr/lib /usr/local/lib /opt/homebrew/lib
        /opt/homebrew/opt/openssl@3/lib /opt/homebrew/opt/openssl@1.1/lib
    )
    for dir in "${search_dirs[@]}"; do
        if [ -d "$dir" ]; then
            local match
            match=$(ls -1 "$dir"/${libname}.dylib "$dir"/${libname}.so* 2>/dev/null | head -n 1 || true)
            if [ -n "$match" ]; then
                echo "$match"
                return 0
            fi
        fi
    done
    return 1
}

if [ -z "$OPENSSL_CRYPTO_LIBRARY" ]; then
    OPENSSL_CRYPTO_LIBRARY="$(find_lib libcrypto || true)"
fi
if [ -z "$OPENSSL_SSL_LIBRARY" ]; then
    OPENSSL_SSL_LIBRARY="$(find_lib libssl || true)"
fi
if [ -z "$OPENSSL_INCLUDE_DIR" ] && [ -n "$OPENSSL_ROOT_DIR" ] && [ -d "$OPENSSL_ROOT_DIR/include" ]; then
    OPENSSL_INCLUDE_DIR="$OPENSSL_ROOT_DIR/include"
fi
LIBUUID_LIBRARY="${LIBUUID_LIBRARY:-}"
LIBUUID_INCLUDE_DIR="${LIBUUID_INCLUDE_DIR:-}"
if [ -z "$LIBUUID_LIBRARY" ]; then
    if command -v pkg-config >/dev/null 2>&1; then
        uuid_libdir="$(pkg-config --variable=libdir uuid 2>/dev/null || true)"
        if [ -n "$uuid_libdir" ]; then
            for ext in dylib so; do
                if [ -f "$uuid_libdir/libuuid.${ext}" ]; then
                    LIBUUID_LIBRARY="$uuid_libdir/libuuid.${ext}"
                    break
                fi
            done
        fi
    fi
fi
if [ -z "$LIBUUID_LIBRARY" ]; then
    for dir in /usr/lib /usr/local/lib /opt/homebrew/lib; do
        for ext in dylib so; do
            if [ -f "$dir/libuuid.${ext}" ]; then
                LIBUUID_LIBRARY="$dir/libuuid.${ext}"
                break
            fi
        done
        if [ -n "$LIBUUID_LIBRARY" ]; then
            break
        fi
    done
fi
if [ -z "$LIBUUID_INCLUDE_DIR" ] && [ -f /usr/include/uuid/uuid.h ]; then
    LIBUUID_INCLUDE_DIR="/usr/include"
fi
cmake -S jupyter -B jupyter/build -G "$GENERATOR" \
    -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
    -DCODON_ENABLE_OPENMP="${OPENMP_FLAG}" \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_CXX_COMPILER="$CXX" \
    -DLLVM_DIR="$LLVM_DIR" \
    -DCODON_PATH="$INSTALL_DIR" \
    "${CMAKE_OSX_SYSROOT_ARGS[@]}" \
    "${CMAKE_POLICY_ARGS[@]}" \
    "${CMAKE_LINK_ARGS[@]}" \
    ${OPENSSL_ROOT_DIR:+-DOPENSSL_ROOT_DIR="$OPENSSL_ROOT_DIR"} \
    ${OPENSSL_CRYPTO_LIBRARY:+-DOPENSSL_CRYPTO_LIBRARY="$OPENSSL_CRYPTO_LIBRARY"} \
    ${OPENSSL_SSL_LIBRARY:+-DOPENSSL_SSL_LIBRARY="$OPENSSL_SSL_LIBRARY"} \
    ${OPENSSL_INCLUDE_DIR:+-DOPENSSL_INCLUDE_DIR="$OPENSSL_INCLUDE_DIR"} \
    ${LIBUUID_LIBRARY:+-DLIBUUID_LIBRARY="$LIBUUID_LIBRARY"} \
    ${LIBUUID_INCLUDE_DIR:+-DLIBUUID_INCLUDE_DIR="$LIBUUID_INCLUDE_DIR"}
cmake --build jupyter/build --config "${BUILD_TYPE}" -j"$CORES"
cmake --install jupyter/build --prefix="$INSTALL_DIR"
fi

# Step 4: Install Jupyter kernel (optional)
if [ "$SKIP_JUPYTER_KERNEL" = "1" ]; then
    echo "=== Skipping Jupyter Kernel install (SKIP_JUPYTER_KERNEL=1) ==="
else
    echo "=== Installing Jupyter Kernel ==="
    KERNEL_DIR="$HOME/Library/Jupyter/kernels/codon"
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
