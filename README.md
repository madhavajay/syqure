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
