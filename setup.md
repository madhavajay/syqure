# Setup

This repo uses Codon as the compiler and Sequre as a Codon plugin.
You can either use the Codon v0.17.0 binary or a custom Codon build with the C++ API
enabled (recommended for the Rust wrapper and Jupyter plugin).

## Prereqs

Install build tools (Arch example):

```bash
sudo pacman -S --needed cmake ninja clang git
```

## Install Codon v0.17.0 (Linux binary)

```bash
mkdir -p $HOME/.codon
curl -L https://github.com/exaloop/codon/releases/download/v0.17.0/codon-$(uname -s | awk '{print tolower($0)}')-$(uname -m).tar.gz | tar zxvf - -C $HOME/.codon --strip-components=1
```

Add Codon to your PATH (zsh example):

```bash
echo 'export PATH="$HOME/.codon/bin:$PATH"' >> ~/.zshrc
```

Verify:

```bash
~/.codon/bin/codon --version
```

## Build Codon from source (Linux, custom API-enabled build)

This builds Codon + Jupyter plugin and copies the install into `bin/codon` so it is
isolated from `~/.codon`. The script always builds LLVM as a shared library so the Rust
wrapper can link against a single LLVM (avoids duplicate LLVM command line registration):

```bash
./compile_codon_linux.sh
```

Note: `all.sh` sets `CODON_ENABLE_OPENMP=OFF` because this environment blocks OpenMP's shared
memory registration (SHM2) and causes runtime failures. If you need OpenMP, rebuild with
`CODON_ENABLE_OPENMP=ON` and ensure `/dev/shm` is writable.

Set `CODON_PATH` to use the custom build:

```bash
export CODON_PATH="$PWD/bin/codon"
```

## Build and install the Sequre plugin

From the repo root (defaults to `bin/codon` if it exists):

```bash
CODON_PATH="$PWD/bin/codon" ./compile_sequre.sh
```

This script:
- clones and builds the Codon LLVM fork (under `sequre/codon-llvm`)
- builds and installs Sequre into `CODON_PATH/lib/codon/plugins/sequre`

Note on ABI mismatch:
If `codon run` fails with an undefined symbol like `NE_MAGIC_NAMEB5cxx11`, the plugin was built with the wrong C++ std::string ABI. Codon v0.17.0 uses the old ABI, so the script auto-detects the ABI from `libcodonc.so` and rebuilds with the matching flag. Re-run `./compile_sequre.sh` after a Codon update.

Note on GMP path:
Sequre loads GMP via `GMP_PATH`. On some systems it is set to a repo-local path that does not exist. The fix is to use the system library name so `dlopen` can resolve it:
`GMP_PATH = "libgmp.so"` in `sequre/stdlib/sequre/constants.codon`. If you already installed the plugin, update the installed copy too at `~/.codon/lib/codon/plugins/sequre/stdlib/sequre/constants.codon` and re-run.

## Python shared library (libpython.so)

Some tests/benchmarks import Python (e.g., MNIST) and require `libpython.so` to be discoverable at runtime. Use the helper script:

```bash
./install_libpython.sh
```

The script installs Python via pacman (Arch) and creates a user-local symlink at `~/.local/lib/libpython.so`. If needed, add:

```bash
export LD_LIBRARY_PATH="$HOME/.local/lib:$LD_LIBRARY_PATH"
```

The script will also append that line to `~/.zshrc` if it is not already present.

## Stale socket cleanup

Local runs use `sock.*` files for IPC between parties. If a run crashes, stale sockets can block new runs with errors like “Address already in use”.

Clean them before retrying:

```bash
rm -f ./sock.*
```

## Docker (binary-only)

The Dockerfile uses `bin/codon` from this repo (no download). Ensure `bin/codon`
exists (from `./compile_codon_linux.sh` or by copying `codon/install` to `bin/codon`).

```bash
./build_docker.sh
docker run --rm -it sequre-binary ./sequre.sh example/two_party_sum_simple.codon
```

## Optional: use prebuilt Codon bundle in repo

If you already have a prebuilt Codon bundle tarball, you can extract it into
`bin/codon` and skip building:

```bash
mkdir -p bin
tar -C bin -I zstd -xf docker/binaries/codon-install-linux-x86_64.tar.zst
```

## Bundle prebuilt Codon/Sequre (no rebuild)

If you already have a Codon install (e.g., `~/.codon`) and a compiled Sequre plugin,
create the Rust bundle without rebuilding:

```bash
CODON_PATH="$PWD/bin/codon" ./bin_libs.sh
```

Note: `bin_libs.sh` prefers LLVM headers from `codon/llvm-project/install/include` and
bundles `libLLVM.so*` from `codon/llvm-project/install/lib` when available. The Rust
build now avoids linking LLVM by default to prevent duplicate registrations; only set
`SYQURE_LINK_LLVM_SHARED=1` or `SYQURE_LINK_LLVM_STATIC=1` if you explicitly want LLVM
linked into the syqure binary. The bundle may grow large because it includes LLVM
headers to build the Rust C++ bridge.
If size is a concern, we may prune to only the required LLVM headers, but doing so requires
tracking the specific header dependencies.

If you see a SIGSEGV early in startup (often in LLVM command line registration), you
likely linked a second LLVM copy into the Rust binary. Fix by unsetting the LLVM link
flags and rebuilding the Rust crate:

```bash
unset SYQURE_LINK_LLVM_SHARED SYQURE_LINK_LLVM_STATIC
cargo clean -p syqure
cargo build -p syqure
```

You can override defaults with env vars:

```bash
SEQURE_PATH=/path/to/sequre \
CODON_PATH=/path/to/codon \
LLVM_PATH=/path/to/codon-llvm \
SEQ_PATH=/path/to/codon-seq \
./compile_sequre.sh
```

If you need the Seq plugin, opt in:

```bash
BUILD_SEQ=1 ./compile_sequre.sh
```

## One-command build/run

Use the repo script for an end-to-end build and run:

```bash
./all.sh
```

This caches the extracted bundle under `target/syqure-cache` for faster iteration.
When you need a clean rebuild:

```bash
./all.sh --clean
```
