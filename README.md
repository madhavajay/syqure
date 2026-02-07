# Sequre Workspace

Rust wrapper around the Codon/Sequre MPC compiler. Compiles and runs `.codon` source files with the Sequre plugin for secure multi-party computation.

## Quick Start

```bash
cargo run -p syqure -- example/two_party_sum_simple.codon
```

For macOS builds, compile Codon with:
```bash
./compile_codon.sh --no-openmp
```

To build Sequre (skip the Seq plugin on macOS):
```bash
./compile_sequre.sh --no-seq
```

Build everything (macOS enforces `--no-openmp` for Codon and `--no-seq` for Sequre):
```bash
./build.sh
```

Use `--build-only` to emit a binary without running it, or `--release` for optimized builds.

## Codon/Sequre Path Resolution

The runtime needs to find Codon's stdlib, plugins (sequre), and shared libraries. Path resolution has two modes:

### Dev Mode (local development)

When running from the repo root via `cargo run`, the binary looks for precompiled Codon at:

```
bin/<platform>/codon/lib/codon/
├── stdlib/           # Codon standard library
├── plugins/
│   └── sequre/
│       ├── plugin.toml
│       └── stdlib/   # SYMLINK → ../../../../../../../../sequre/stdlib
├── libcodonrt.dylib
├── libcodonc.dylib
└── libgmp.dylib
```

The `plugins/sequre/stdlib` symlink points to the `sequre/` git submodule, so edits to sequre source files are reflected immediately without rebuilding anything.

**Resolution order** (in `syqure/src/runner.rs` `default_codon_path()`):
1. `CODON_PATH` env var (explicit override)
2. `<exe_dir>/lib/codon` (production install next to binary)
3. `bin/<platform>/codon/lib/codon` (dev mode, requires both `stdlib/` and `plugins/`)
4. `codon/install` (legacy fallback)

### Production Mode (installed binary)

When no local path is found, the embedded bundle (`syqure/bundles/<target>.tar.zst`) is extracted to `~/.cache/syqure/<bundle-name>/<hash>/lib/codon/`. The bundle has all files baked in as real copies (symlinks dereferenced at bundle-creation time).

### Debug

Set `SYQURE_DEBUG=1` to see which path was resolved:

```bash
SYQURE_DEBUG=1 cargo run -p syqure -- example/two_party_sum_simple.codon
# syqure: codon_root=bin/macos-arm64/codon/lib/codon      ← dev mode
# syqure: codon_root=/Users/.../.cache/syqure/.../lib/codon  ← production mode
```

## Architecture

```
syqure/
├── src/
│   ├── bin/syqure.rs    # CLI entry point
│   ├── runner.rs        # Path resolution + compile/run orchestration
│   ├── bundle.rs        # Bundle extraction to ~/.cache/syqure/
│   ├── ffi.rs           # Rust↔C++ FFI bridge definition (cxx)
│   └── ffi/
│       ├── bridge.cc    # C++ bridge: calls codon::Compiler to JIT-compile and run
│       └── bridge.h
├── bundles/             # Prebuilt platform bundles (embedded at compile time)
└── build.rs             # Build script: finds bundle, sets rpaths, compiles C++ bridge
```

The Rust crate links directly against Codon via a `cxx` bridge (`syqure/src/ffi/*`), exposing lightweight FFI that mirrors `codon run`/`codon build` without shelling out. Point `SYQURE_CPP_INCLUDE`/`SYQURE_CPP_LIB_DIRS` to custom Codon/Sequre builds if needed.

## Known Issues

### macOS: `fork()` crash with `OutputCapture` (SIGABRT)

Codon's `@local` decorator uses `fork()` to spawn MPC parties. The OutputCapture class (pipe-based stdout/stderr capture) caused forked children to crash with SIGABRT ("crashed on child side of fork pre-exec") because the pipe reader threads + dup2 redirects are inherited by the child.

**Root cause**: `OutputCapture` creates pipe reader threads before `compiler->getLLVMVisitor()->run()`. When Codon's `@local` calls `fork()`, POSIX only clones the calling thread — the pipe reader threads are dead in the child, and the dup2'd file descriptors are invalid.

**Current fix**: OutputCapture is disabled in `bridge.cc`; program output goes directly to stdout/stderr. The `SYQURE_FORCE_EXIT` env var calls `std::process::exit(0)` to kill lingering Codon threads on exit.

### hotlink_transport.codon stubbed out

The full hotlink transport implementation (Unix socket / TCP framed IPC for the `SEQURE_TRANSPORT=hotlink` mode) is currently replaced with a no-op stub. The full implementation's C FFI imports (`send`, `recv`, `socket`, `connect`, `close`) and `sockaddr_un`/`sockaddr_in` struct usage corrupt the Codon JIT compiler at compile time — even when the code path is never executed at runtime (default transport is TCP). This causes segfaults during MPC party setup after fork().

Investigation tracked in `syqure-problem.md`.

### settings.codon: no os.getenv at module level

`sequre/stdlib/sequre/settings.codon` must NOT use `import os` or `os.getenv()` at module scope. Codon evaluates module-level expressions before `fork()`, and this interaction causes segfaults on macOS. Runtime env overrides for ports (`SEQURE_COMMUNICATION_PORT`, `SEQURE_DATA_SHARING_PORT`) are handled in `comms.codon` `__setup_channels()` instead.

### clean_sockets() removes all sock.* files

`runner.rs` `clean_sockets()` walks the working directory and removes all files matching `sock.*` on every run. If another syqure instance is using socket files in the same directory tree, this will break it. Be careful running multiple instances from the same repo.

## Environment Variables

| Variable | Purpose |
|---|---|
| `CODON_PATH` | Override Codon stdlib path |
| `CODON_PLUGIN_PATH` | Override plugin search path |
| `SYQURE_DEBUG=1` | Print path resolution info |
| `SYQURE_SKIP_BUNDLE=1` | Skip bundle extraction, use local path even if incomplete |
| `SYQURE_BUNDLE_FILE` | Override embedded bundle path |
| `SYQURE_BUNDLE_CACHE` | Override bundle cache directory |
| `SYQURE_FORCE_EXIT` | Force `std::process::exit(0)` on completion (kills lingering threads) |
| `SYQURE_CPP_INCLUDE` | Custom Codon/Sequre header include path |
| `SYQURE_CPP_LIB_DIRS` | Custom Codon/Sequre library search paths (colon-separated) |
| `SEQURE_TRANSPORT` | Transport mode: `tcp` (default), `file`, `hotlink` (stubbed) |
| `SEQURE_COMMUNICATION_PORT` | Override MPC communication base port (default: 9000) |
| `SEQURE_DATA_SHARING_PORT` | Override data sharing port (default: 9999) |
| `SEQURE_TCP_PROXY` | Enable TCP proxy mode for MPC connections |
| `SEQURE_CP_IPS` | Comma-separated party IP addresses |
