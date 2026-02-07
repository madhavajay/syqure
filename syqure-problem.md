# Syqure Problem Analysis

## Working State
- **Branch**: `main` at `6e9d9dc`
- **sequre submodule**: `12303cd` ("adding changes")
- **codon submodule**: `c1da4f9` (same on both branches)
- `cargo run -p syqure -- example/two_party_sum_simple.codon` **works**

## Broken State
- **Branch**: `madhava/symlink` at `84e7835`
- **sequre submodule**: HEAD expects `d3bdcdb`, but checked out at `22ace23`
- Segfault during MHE rotation key generation, then socket errors

## What Changed (6e9d9dc → madhava/symlink)

| Commit | Date | What |
|--------|------|------|
| `edbb9e7` | Jan 29 | **Swapped ~31k lines of duplicated sequre stdlib for symlinks** |
| `f60f433` | Jan 30 | Adding examples |
| `295d3e9` | Feb 6 | Disabled OutputCapture in bridge.cc to prevent fork() crash |
| `45116cb` | Feb 7 | Added `resolve_codon_root()` path resolution logic |
| `84e7835` | Feb 7 | Updated sequre submodule pointer to `d3bdcdb` |

## Root Cause: Stale Bundle Cache

### How the runtime resolves codon/sequre files:
1. `default_codon_path()` → returns `codon/install` (no CODON_PATH env set)
2. `normalize_codon_root("codon/install")` → checks `codon/install/stdlib` → **doesn't exist**
3. Falls back to `ensure_bundle()` → extracts embedded `aarch64-apple-darwin.tar.zst` to `~/.cache/syqure/`
4. **Runtime uses cached bundle files, NOT the sequre submodule directly**

### The bundle is stale:
- The bundle at `syqure/bundles/aarch64-apple-darwin.tar.zst` is compiled into the Rust binary at build time
- The cached extraction has **178-line** `file_transport.codon`
- Current sequre submodule has **195-line** version (with hotlink transport additions)
- `hotlink_transport.codon` is **missing from ALL 9 cache entries**
- Cached `constants.codon` has no `HOTLINK_TRANSPORT` constant

### The symlink doesn't help at runtime:
- `bin/macos-arm64/codon/lib/codon/plugins/sequre/stdlib` → symlink to `../../../../../../../sequre/stdlib`
- This symlink is only useful for local dev, NOT for the bundle
- The bundle extraction to `~/.cache/syqure/` has real files (dereferenced at bundle-creation time)
- But the bundle was created from an older version of sequre

## Secondary Issues

### 1. OutputCapture + fork() (fixed in 295d3e9)
- Codon's `@local` decorator uses `fork()` to spawn MPC parties
- OutputCapture's pipe threads + dup2 redirects caused forked children to crash (SIGABRT)
- **Fix**: OutputCapture disabled, output goes directly to stdout/stderr
- This fix is already in the branch

### 2. Sequre submodule mismatch
- `git ls-tree HEAD sequre` → expects `d3bdcdb`
- `git submodule status` → checked out at `22ace23` (different branch)
- `d3bdcdb` (Feb 7, "rebuilding hotlink") is newer than `22ace23` (Jan 29, "reduce overhead")
- They diverged from common ancestor `12303cd`

### 3. Default transport is TCP (not file)
- `constants.codon`: `TRANSPORT = os.getenv("SEQURE_TRANSPORT", default="tcp")`
- The basic test uses TCP sockets, not file transport
- So the file transport / hotlink changes shouldn't directly cause the segfault
- **The segfault is in MHE (crypto) code**, suggesting a library/linking issue or stale compiled code

## What Was Fixed

1. **`runner.rs`** — Added dev mode path resolution: `bin/<platform>/codon/lib/codon` checked before bundle fallback
2. **`settings.codon`** — Reverted `import os` + `os.getenv()` for ports to hardcoded (comms.codon handles env overrides at runtime)
3. **`hotlink_transport.codon`** — Replaced with stub. The full implementation's C imports (`send`, `recv`, `socket`, `connect`, `close`) + `sockaddr_un`/`sockaddr_in` usage corrupts Codon JIT even when code is never called (HOTLINK_TRANSPORT=False). Needs investigation into Codon's JIT handling of unused-but-compiled C FFI bindings.

## Key Files

| File | Purpose |
|------|---------|
| `syqure/src/runner.rs:156-180` | `resolve_codon_root()` - decides which codon/sequre files to use |
| `syqure/src/bundle.rs` | Bundle extraction to `~/.cache/syqure/` |
| `syqure/src/ffi/bridge.cc:229-283` | `sy_codon_run()` - OutputCapture disabled |
| `syqure/bundles/aarch64-apple-darwin.tar.zst` | Embedded bundle (needs rebuild) |
| `bin/macos-arm64/codon/lib/codon/plugins/sequre/stdlib` | Symlink → `sequre/stdlib` |
| `sequre/stdlib/sequre/network/file_transport.codon` | Current version (195 lines, with hotlink) |
| `sequre/stdlib/sequre/constants.codon` | Transport config (default: tcp) |
