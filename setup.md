# Setup

This repo uses Codon as the compiler and Sequre as a Codon plugin.
Use the Codon v0.17.0 binary, then build and install the Sequre plugin.

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

## Build and install the Sequre plugin

From the repo root:

```bash
./compile_sequre.sh
```

This script:
- clones and builds the Codon LLVM fork (under `sequre/codon-llvm`)
- builds and installs Sequre into `~/.codon/lib/codon/plugins/sequre`

Note on ABI mismatch:
If `codon run` fails with an undefined symbol like `NE_MAGIC_NAMEB5cxx11`, the plugin was built with the wrong C++ std::string ABI. Codon v0.17.0 uses the old ABI, so the script now auto-detects the ABI from `libcodonc.so` and rebuilds with the matching flag. Re-run `./compile_sequre.sh` after a Codon update.

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

Use the prebuilt Codon v0.17.0 release plus the locally-built Sequre plugin:

```bash
docker build -f docker/Dockerfile.sequre -t sequre-binary .
docker run --rm -it sequre-binary ./sequre.sh example/two_party_sum_simple.codon
```

## Bundle prebuilt Codon/Sequre (no rebuild)

If you already have a Codon install (e.g., `~/.codon`) and a compiled Sequre plugin,
create the Rust bundle without rebuilding:

```bash
CODON_PATH=$HOME/.codon ./bin_libs.sh
```

Note: the bundle may grow large because it includes LLVM headers to build the Rust C++ bridge.
If size is a concern, we may prune to only the required LLVM headers, but doing so requires
tracking the specific header dependencies.

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
