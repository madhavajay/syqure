#!/usr/bin/env bash
# Build Sequre and its dependencies (LLVM, Codon, Seq) on Linux (macOS best effort).
# Environment overrides:
#   SEQURE_PATH         : repo root (default: script location)
#   SEQURE_LLVM_PATH    : LLVM build/install dir (default: $SEQURE_PATH/codon-llvm)
#   SEQURE_CODON_PATH   : Codon build/install dir (default: $SEQURE_PATH/codon)
#   SEQURE_SEQ_PATH     : Seq-lang build/install dir (default: $SEQURE_PATH/codon-seq)
#   CMAKE               : cmake binary (default: cmake)
#   NINJA_BIN           : ninja binary (default: ninja)
#   CC / CXX            : C/C++ compilers (default: clang/clang++)
#   BUILD_TYPE          : Debug/Release/RelWithDebInfo (default: Release)
#   ENABLE_ASAN         : set to 1 to build Codon/Seq/Sequre with ASAN

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DO_CLEAN=false
BUILD_TYPE="${BUILD_TYPE:-Release}"
ENABLE_ASAN="${ENABLE_ASAN:-0}"
SKIP_SEQ="${SKIP_SEQ:-0}"
for arg in "$@"; do
    case "$arg" in
        --clean) DO_CLEAN=true ;;
        --debug) BUILD_TYPE="Debug" ;;
        --relwithdebinfo) BUILD_TYPE="RelWithDebInfo" ;;
        --asan) ENABLE_ASAN=1 ;;
        --no-seq) SKIP_SEQ=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

# Default to the embedded Sequre source tree under this repo.
SEQURE_PATH="${SEQURE_PATH:-$ROOT_DIR/sequre}"
# Keep toolchain defaults anchored at the repo root so they point to the shared builds.
SEQURE_LLVM_PATH="${SEQURE_LLVM_PATH:-$ROOT_DIR/codon-llvm}"
SEQURE_LLVM_TARGETS="${SEQURE_LLVM_TARGETS:-all}"
if [ -z "${SEQURE_LLVM_PROJECTS:-}" ] && [ "$(uname -s)" = "Linux" ]; then
    SEQURE_LLVM_PROJECTS="clang"
fi
if [ -z "${SEQURE_LLVM_RUNTIMES:-}" ] && [ "$(uname -s)" = "Linux" ]; then
    SEQURE_LLVM_RUNTIMES="openmp"
fi
SEQURE_CODON_PATH="${SEQURE_CODON_PATH:-$ROOT_DIR/codon}"
SEQURE_SEQ_PATH="${SEQURE_SEQ_PATH:-$ROOT_DIR/codon-seq}"
# macOS: prefer the Homebrew gcc lib path if present so we can link libgfortran; Linux defaults to multiarch lib dir
if [ -z "${CODON_SYSTEM_LIBRARIES:-}" ]; then
    if [ "$(uname -s)" = "Linux" ]; then
        CODON_SYSTEM_LIBRARIES="/usr/lib/$(uname -m)-linux-gnu"
    else
        CODON_SYSTEM_LIBRARIES="/opt/homebrew/opt/gcc/lib/gcc/current"
    fi
fi
# Use the already-downloaded xz source from the Codon build to avoid extra network fetches
XZ_SOURCE_DIR="${XZ_SOURCE_DIR:-${SEQURE_CODON_PATH}/build/_deps/xz-src}"
CMAKE_BIN="${CMAKE:-cmake}"
NINJA_BIN="${NINJA_BIN:-ninja}"
LLVM_PREFIX="${LLVM_PREFIX:-/opt/homebrew/opt/llvm}"
# Explicitly propagate the LLVM headers so Codon/Seq builds can include llvm/Support/… headers.
if [ -z "${LLVM_INCLUDE_DIR:-}" ]; then
    if [ -d "${SEQURE_LLVM_PATH}/install/include" ]; then
        LLVM_INCLUDE_DIR="${SEQURE_LLVM_PATH}/install/include"
    elif [ -d "${LLVM_PREFIX}/include" ]; then
        LLVM_INCLUDE_DIR="${LLVM_PREFIX}/include"
    else
        LLVM_INCLUDE_DIR=""
    fi
fi
CC="${CC:-$LLVM_PREFIX/bin/clang}"
CXX="${CXX:-$LLVM_PREFIX/bin/clang++}"
COMMON_FLAGS="-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
OS_NAME="$(uname -s)"
if [ "$ENABLE_ASAN" = "1" ]; then
    SAN_FLAGS="-fsanitize=address -fno-omit-frame-pointer"
    C_FLAGS="$SAN_FLAGS"
    if [ "$OS_NAME" = "Darwin" ]; then
        CXX_FLAGS="$SAN_FLAGS -stdlib=libc++ -nostdinc++ -isystem $LLVM_PREFIX/include/c++/v1 -include cstdlib"
        LD_FLAGS="$SAN_FLAGS -nostdlib++ -L$LLVM_PREFIX/lib/c++ -Wl,-rpath,$LLVM_PREFIX/lib/c++ -lc++ -lc++abi"
    else
        CXX_FLAGS="$SAN_FLAGS"
        LD_FLAGS="$SAN_FLAGS"
    fi
else
    C_FLAGS=""
    if [ "$OS_NAME" = "Darwin" ]; then
        CXX_FLAGS="-stdlib=libc++ -nostdinc++ -isystem $LLVM_PREFIX/include/c++/v1 -include cstdlib"
        LD_FLAGS="-nostdlib++ -L$LLVM_PREFIX/lib/c++ -Wl,-rpath,$LLVM_PREFIX/lib/c++ -lc++ -lc++abi"
    else
        CXX_FLAGS=""
        LD_FLAGS=""
    fi
fi
# Add the LLVM headers explicitly so Codon’s headers (which include llvm/Support/…) resolve.
if [ -n "$LLVM_INCLUDE_DIR" ]; then
    C_FLAGS="$C_FLAGS -I${LLVM_INCLUDE_DIR}"
    CXX_FLAGS="$CXX_FLAGS -I${LLVM_INCLUDE_DIR}"
fi
export SEQURE_PATH SEQURE_LLVM_PATH SEQURE_CODON_PATH SEQURE_SEQ_PATH CODON_SYSTEM_LIBRARIES XZ_SOURCE_DIR

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 1
    fi
}

ensure_ninja() {
    if command -v "$NINJA_BIN" >/dev/null 2>&1; then
        return
    fi
    case "$(uname -s)" in
        Darwin)
            if command -v brew >/dev/null 2>&1; then
                echo "ninja not found; installing via Homebrew..."
                brew install ninja
            else
                echo "ninja not found and Homebrew is missing. Install Homebrew or set NINJA_BIN to your ninja path." >&2
                exit 1
            fi
            ;;
        Linux)
            echo "ninja not found. Install via your package manager (e.g., sudo apt-get install ninja-build or sudo yum install ninja-build), then re-run." >&2
            exit 1
            ;;
        *)
            echo "ninja not found and automatic install is not supported on this OS. Please install ninja manually." >&2
            exit 1
            ;;
    esac
}

ensure_gcc_libs_on_macos() {
    if [ "$(uname -s)" != "Darwin" ]; then
        return
    fi
    if [ -n "${CODON_SYSTEM_LIBRARIES:-}" ]; then
        return
    fi
    if ! command -v brew >/dev/null 2>&1; then
        echo "Homebrew not found; set CODON_SYSTEM_LIBRARIES to your libgfortran path (e.g., /opt/homebrew/opt/gcc/lib/gcc/current)." >&2
        return
    fi
    echo "Ensuring Homebrew gcc is installed for libgfortran..."
    brew install gcc
    export CODON_SYSTEM_LIBRARIES="$(brew --prefix gcc)/lib/gcc/current"
    echo "Set CODON_SYSTEM_LIBRARIES=${CODON_SYSTEM_LIBRARIES}"
}

ensure_libomp_on_macos() {
    if [ "$(uname -s)" != "Darwin" ]; then
        return
    fi
    if ! command -v brew >/dev/null 2>&1; then
        echo "Homebrew not found; install libomp manually if CMake complains about missing OpenMP runtime." >&2
        return
    fi
    if brew list --versions libomp >/dev/null 2>&1; then
        echo "libomp already present via Homebrew."
        return
    fi
    echo "Ensuring Homebrew libomp is installed..."
    brew install libomp || true
}

check_cmake_version() {
    if (echo a version 3.20.0; "$CMAKE_BIN" --version) | sort -Vk3 | tail -1 | grep -q cmake; then
        echo "CMake version ok."
    else
        echo "CMake >=3.20.0 required." >&2
        exit 1
    fi
}

clean_build_dirs() {
    echo "Cleaning build directories..."
    rm -rf "$SEQURE_PATH/build"
    rm -rf "$SEQURE_LLVM_PATH/build"
    rm -rf "$SEQURE_SEQ_PATH/build"
    rm -rf "$SEQURE_CODON_PATH/build"
    rm -rf "$SEQURE_CODON_PATH/build/cmake"
}

build_llvm() {
    if [ -d "${SEQURE_LLVM_PATH}/install/lib/cmake/llvm" ]; then
        echo "Found existing LLVM installation at ${SEQURE_LLVM_PATH}."
        return
    fi
    echo "Building LLVM into ${SEQURE_LLVM_PATH}..."
    rm -rf "$SEQURE_LLVM_PATH"
    echo "Cloning llvm-project (codon-17.0.6 tag) with retries..."
    for attempt in 1 2 3; do
        if git clone --depth 1 -b codon-17.0.6 https://github.com/exaloop/llvm-project "$SEQURE_LLVM_PATH"; then
            break
        fi
        echo "Clone attempt ${attempt} failed; retrying in 10s" >&2
        sleep 10
    done
    if [ ! -d "$SEQURE_LLVM_PATH/.git" ]; then
        echo "Clone failed; falling back to tarball download..." >&2
        mkdir -p "$SEQURE_LLVM_PATH"
        tmp_tar="$(mktemp /tmp/llvm-project.XXXXXX.tar.gz)"
        if curl -Lf "https://codeload.github.com/exaloop/llvm-project/tar.gz/codon-17.0.6" -o "$tmp_tar"; then
            tar -xzf "$tmp_tar" --strip-components=1 -C "$SEQURE_LLVM_PATH"
            rm -f "$tmp_tar"
        fi
    fi
    if [ ! -d "$SEQURE_LLVM_PATH/.git" ] && [ ! -d "$SEQURE_LLVM_PATH/llvm" ] && [ ! -f "$SEQURE_LLVM_PATH/CMakeLists.txt" ]; then
        echo "Error: failed to obtain exaloop/llvm-project (clone and tarball both failed)" >&2
        exit 1
    fi
    pushd "$SEQURE_LLVM_PATH" >/dev/null
    "$CMAKE_BIN" -S llvm -B build -G Ninja \
        -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_ENABLE_RTTI=ON \
        -DLLVM_ENABLE_ZLIB=OFF \
        -DLLVM_ENABLE_TERMINFO=OFF \
        -DLLVM_TARGETS_TO_BUILD="${SEQURE_LLVM_TARGETS}" \
        -DLLVM_ENABLE_PROJECTS="${SEQURE_LLVM_PROJECTS}" \
        -DLLVM_ENABLE_RUNTIMES="${SEQURE_LLVM_RUNTIMES}" \
        $COMMON_FLAGS
    "$CMAKE_BIN" --build build --config "${BUILD_TYPE}"
    "$CMAKE_BIN" --install build --prefix="$SEQURE_LLVM_PATH/install"
    popd >/dev/null
}

build_codon() {
    if [ -d "${SEQURE_CODON_PATH}/install" ]; then
        echo "Found existing Codon installation at ${SEQURE_CODON_PATH}."
        return
    fi
    echo "Building Codon into ${SEQURE_CODON_PATH}..."
    # Only clone if directory doesn't exist (preserve local modifications)
    if [ ! -d "$SEQURE_CODON_PATH" ]; then
        git clone https://github.com/exaloop/codon.git "$SEQURE_CODON_PATH"
    fi
    pushd "$SEQURE_CODON_PATH" >/dev/null
    # Skip OpenMP injection - using system LLVM 17 on Linux or the CMakeLists.txt already handles it
    # Don't override OMP_LIBRARY - let CMake find it from LLVM install
    "$CMAKE_BIN" -S . -B build -G Ninja \
        -DLLVM_DIR="${SEQURE_LLVM_PATH}/install/lib/cmake/llvm" \
        -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
        -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_CXX_COMPILER="$CXX" \
        -DCMAKE_C_FLAGS="$C_FLAGS" \
        -DCMAKE_CXX_FLAGS="$CXX_FLAGS" \
        -DCMAKE_EXE_LINKER_FLAGS="$LD_FLAGS" \
        -DCMAKE_SHARED_LINKER_FLAGS="$LD_FLAGS" \
        -DCODON_GPU=OFF \
        -DCODON_JUPYTER=OFF \
        $COMMON_FLAGS
    "$CMAKE_BIN" --build build --config "${BUILD_TYPE}"
    "$CMAKE_BIN" --install build --prefix="${SEQURE_CODON_PATH}/install"
    popd >/dev/null
}

build_seq() {
    if [ "$ENABLE_ASAN" = "1" ]; then
        echo "Skipping Seq build under ASAN (not required for Sequre diagnostics)."
        return
    fi
    if [ -d "${SEQURE_CODON_PATH}/install/lib/codon/plugins/seq" ]; then
        echo "Found existing Seq-lang installation at ${SEQURE_CODON_PATH}/install/lib/codon/plugins/seq."
        return
    fi
    echo "Building Seq-lang into ${SEQURE_SEQ_PATH}..."
    rm -rf "$SEQURE_SEQ_PATH"
    git clone https://github.com/exaloop/seq.git "$SEQURE_SEQ_PATH"
    pushd "$SEQURE_SEQ_PATH" >/dev/null
    "$CMAKE_BIN" -S . -B build -G Ninja \
        -DLLVM_DIR="${SEQURE_LLVM_PATH}/install/lib/cmake/llvm" \
        -DCODON_PATH="${SEQURE_CODON_PATH}/install" \
        -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
        -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_CXX_COMPILER="$CXX" \
        -DCMAKE_C_FLAGS="$C_FLAGS" \
        -DCMAKE_CXX_FLAGS="$CXX_FLAGS" \
        -DCMAKE_EXE_LINKER_FLAGS="$LD_FLAGS" \
        -DCMAKE_SHARED_LINKER_FLAGS="$LD_FLAGS" \
        $COMMON_FLAGS
    "$CMAKE_BIN" --build build --config "${BUILD_TYPE}"
    "$CMAKE_BIN" --install build --prefix="${SEQURE_CODON_PATH}/install/lib/codon/plugins/seq"
    popd >/dev/null
}

build_sequre() {
    echo "Building Sequre plugin..."
    pushd "$SEQURE_PATH" >/dev/null
    rm -rf build
    "$CMAKE_BIN" -S . -B build -G Ninja \
        -DLLVM_DIR="${SEQURE_LLVM_PATH}/install/lib/cmake/llvm" \
        -DCODON_PATH="${SEQURE_CODON_PATH}/install" \
        -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
        -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_CXX_COMPILER="$CXX" \
        -DCMAKE_C_FLAGS="$C_FLAGS" \
        -DCMAKE_CXX_FLAGS="$CXX_FLAGS" \
        -DCMAKE_EXE_LINKER_FLAGS="$LD_FLAGS" \
        -DCMAKE_SHARED_LINKER_FLAGS="$LD_FLAGS" \
        $COMMON_FLAGS
    "$CMAKE_BIN" --build build --config "${BUILD_TYPE}"
    "$CMAKE_BIN" --install build --prefix="${SEQURE_CODON_PATH}/install/lib/codon/plugins/sequre"
    popd >/dev/null
}

main() {
    if [ "$(uname -s)" != "Linux" ]; then
        echo "Warning: Sequre is supported on Linux; continuing anyway." >&2
    fi

    if $DO_CLEAN; then
        clean_build_dirs
    fi

    require_cmd git
    require_cmd "$CMAKE_BIN"
    ensure_ninja
    require_cmd "$NINJA_BIN"
    ensure_gcc_libs_on_macos
    ensure_libomp_on_macos
    check_cmake_version

    build_llvm
    build_codon
    if [ "$SKIP_SEQ" != "1" ]; then
        build_seq
    else
        echo "Skipping Seq build (SKIP_SEQ=1)."
    fi
    build_sequre

    echo "Done. Add Sequre to your PATH (example):"
    echo "  alias sequre=\"find . -name 'sock.*' -exec rm {} \\; && CODON_DEBUG=lt ${SEQURE_CODON_PATH}/install/bin/codon run --disable-opt=\\\"core-pythonic-list-addition-opt\\\" -plugin sequre\""
}

main "$@"
# Usage:
#   ./compile_sequre.sh            # normal build
#   ./compile_sequre.sh --clean    # remove prior build dirs before building
