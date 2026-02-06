# Sequre Workspace

For macOS builds, compile Codon with:
```bash
./compile_codon.sh --no-openmp
```

To build Sequre (skip the Seq plugin on macOS):
```bash
./compile_sequre.sh --no-seq
```

Quick test run:
```bash
./sequre.sh example/two_party_sum_simple.codon
```

## Syqure (Rust harness)

A Rust workspace scaffolded with:
- `syqure`: library for invoking Codon + Sequre (via CLI calls today, C++ FFI ready via `cxx`) and a `syqure` CLI binary.

Build everything with Cargo:
```bash
cargo build -p syqure
```
Run a program (uses `CODON_PATH` or `./codon/install` by default):
```bash
cargo run -p syqure -- example/two_party_sum_simple.codon
```
Use `--build-only` to emit a binary without running it, or `--release` for optimized builds.

The Rust crate links directly against Codon via a `cxx` bridge (`syqure/src/ffi/*`), exposing lightweight FFI that mirrors `codon run`/`codon build` without shelling out. Point `SYQURE_CPP_INCLUDE`/`SYQURE_CPP_LIB_DIRS` to custom Codon/Sequre builds if needed; by default it uses `codon/install/include` and `codon/install/lib/codon`.

Build everything (macOS enforces `--no-openmp` for Codon and `--no-seq` for Sequre):
```bash
./build.sh
```

## Known Issues

### macOS: `fork()` crash with `OutputCapture` (SIGABRT)

The `@local` decorator in Codon uses `fork()` to spawn MPC parties. If `OutputCapture` in `bridge.cc` is active (pipe threads + `dup2` redirects), the forked child inherits dead threads and corrupt fd state, causing:

```
"crashed on child side of fork pre-exec" (SIGABRT / signal 6)
```

**Root cause**: `OutputCapture` creates pipe reader threads before `compiler->getLLVMVisitor()->run()`. When Codon's `@local` calls `fork()`, POSIX only clones the calling thread — the pipe reader threads are dead in the child, and the dup2'd file descriptors are invalid.

**Fix options**:
1. Remove/disable `OutputCapture` around `sy_codon_run` in `bridge.cc` (simplest — output goes to real stdout/stderr)
2. Stop `OutputCapture` before `run()` and restart after (output during JIT won't be captured)
3. Change Codon runtime to use `posix_spawn` instead of `fork` (deep change in `codon` submodule)

**Workaround**: The `SYQURE_FORCE_EXIT` env var (default on in `madhava/symlink`) calls `std::process::exit(0)` to kill lingering Codon threads on exit.
