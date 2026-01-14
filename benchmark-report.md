# Sequre Benchmark Report

**Date:** 2026-01-14
**Platform:** Linux 6.17.9-arch1-1
**Runner:** syqure (with compilation caching)

## Summary

| Benchmark | Status | Real Time | Actual Work | Notes |
|-----------|--------|-----------|-------------|-------|
| `--mpc` | PASS | 1m21.4s | ~2.5s | MPC operations only |
| `--mhe` | PASS | 1m23.3s | ~0.5s | MHE operations |
| `--lattiseq` | PASS | 1m41.1s | ~1.95s | Trusted dealer only (CP0) |
| `--king` | PASS | 1m31.4s | - | KING genetic kinship |
| `--pca` | PASS | 1m36.2s | - | PCA analysis |
| `--lin-alg` | PASS | 1m32.0s | ~6.4s | Linear algebra ops |
| `--gwas-with-norm` | PASS | 1m31.2s | - | GWAS with normalization |
| `--stdlib-builtin` | FAIL | 3m25.8s | - | Crash during Shechi L2 |
| `--mi` | FAIL | - | - | Crash after MHE init |
| `--gwas-without-norm` | FAIL | - | - | Crash during data sharing |
| `--credit-score` | FAIL | - | - | Missing data files |
| `--dti` | FAIL | - | - | OOM during MHE rot key gen |
| `--mnist` | FAIL | - | - | Missing torchvision |
| `--ablation` | PARTIAL | 6m15.6s | ~136s | OOM during matmul |

## Final Summary

**Passed:** 8/15 benchmarks
**Failed:** 7/15 benchmarks (4 OOM, 2 missing deps/data, 1 partial)

## Timing Analysis

Most benchmark time is spent on:
1. **JIT Compilation:** ~20s (cached after first run)
2. **MHE Key Generation:** ~15s (public key, relin key, rotation keys)
3. **MPC Network Setup:** ~3s

Actual cryptographic work is typically <10s for most benchmarks.

### syqure vs codon comparison

| Runner | `--mpc` Time |
|--------|--------------|
| syqure | 1m26.7s |
| codon | 1m43.7s |

syqure is ~17s faster due to compilation caching in `target/syqure-cache/`.

## Known Issues

### 1. `--stdlib-builtin` crashes during Shechi L2 test

**Description:**
The benchmark fails during the "Shechi L2" test which uses MPU (Multiparty Union) types with MHE operations.

**Symptoms:**
- "Sequre L2" (MPC-only) completes successfully (~14-22s)
- "Shechi L2" (MHE-based using MPU) crashes with socket connection error:
  ```
  ValueError: Socket connection broken for msg_len of 8
  ```

**Location:** `sequre/stdlib/sequre/network/common.codon:65:13`

---

### 2. `--mi` crashes during MHE initialization

**Description:**
The Multiple Imputation benchmark fails immediately after MHE key generation completes.

**Symptoms:**
- MHE initialization completes on all parties
- Immediately crashes with:
  ```
  Receive socket connection broken: Bad address
  ValueError: Socket connection broken for msg_len of 8
  ```

**Location:** `benchmark.codon:216` at `sync_parties` call

## Detailed Results

### `--mpc` (PASS)
```
MPC done in 2.37s at CP0
MPC done in 2.58s at CP1
MPC done in 2.58s at CP2
Total: 1m21.4s
```

### `--lattiseq` (PASS)
```
CP1, CP2: "Lattiseq is benchmarked only at trusted dealer"
CP0: Ran actual lattiseq operations (~1.95s)
Total: 1m41.1s
```

### `--lin-alg` (PASS)
```
Linear algebra done in 6.43s at CP0
Linear algebra done in 6.63s at CP1
Linear algebra done in 6.63s at CP2
Secure matrix multiplications: 2
Beaver partitions: 73
FP truncations: 36
Total: 1m32.0s
```

### `--king` (PASS)
```
Total: 1m31.4s
```

### `--pca` (PASS)
```
Total: 1m36.2s
```
