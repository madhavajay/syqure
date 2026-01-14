# Known Issues

## Benchmark Issues

### `--stdlib-builtin` benchmark crashes during Shechi L2 test

**Status:** Open

**Description:**
The `--stdlib-builtin` benchmark fails during the "Shechi L2" test which uses MPU (Multiparty Union) types with MHE operations.

**Symptoms:**
- "Sequre L2" (MPC-only) completes successfully (~14-22s)
- "Shechi L2" (MHE-based using MPU) crashes with socket connection error
- One compute party exits early, causing remaining parties to fail with:
  ```
  ValueError: Socket connection broken for msg_len of 8
  ```

**Backtrace location:**
- `sequre/stdlib/sequre/network/common.codon:65:13`

**Workaround:**
Skip this benchmark and run others individually.

**Tested with:**
- `./benchmark.sh --benchmark --syqure --stdlib-builtin`

---

### `--mi` benchmark crashes during MHE initialization

**Status:** Open

**Description:**
The `--mi` (Multiple Imputation) benchmark fails immediately after MHE key generation completes. One compute party crashes, causing socket connection errors for the remaining parties.

**Symptoms:**
- MHE initialization completes on all parties ("MHE initialized.")
- Immediately crashes with socket connection error:
  ```
  Receive socket connection broken: Bad address
  ValueError: Socket connection broken for msg_len of 8
  ```

**Backtrace location:**
- `sequre/stdlib/sequre/network/common.codon:65:13`
- Fails at `sync_parties` call in `benchmark.codon:216`

**Workaround:**
Skip this benchmark and run others individually.

**Tested with:**
- `./benchmark.sh --benchmark --syqure --mi`

---

### `--gwas-without-norm` crashes during data sharing

**Status:** Open

**Description:**
The GWAS (without normalization) benchmark fails during the data sharing phase when trying to share gwas-geno data.

**Symptoms:**
- Successfully shares gwas-pheno on all parties
- Crashes during "Sharing gwas-geno" with:
  ```
  Receive socket connection broken: Bad address
  ValueError: Socket connection broken for msg_len of 96024008
  ```

**Backtrace location:**
- `sequre/applications/utils/data_sharing.codon:32:68`
- `benchmark.codon:702` calling `gwas_w_norm_wrapper`

**Workaround:**
Skip this benchmark and run others individually.

**Tested with:**
- `./benchmark.sh --benchmark --syqure --gwas-without-norm`

---

### `--credit-score` missing data files

**Status:** Open (Missing Data)

**Description:**
The credit score benchmark fails because required data files are not present.

**Symptoms:**
```
IOError: file data/credit_score/features.txt could not be opened
```

**Required files:**
- `data/credit_score/features.txt`

**Tested with:**
- `./benchmark.sh --benchmark --syqure --credit-score`

---

### `--dti` crashes during MHE rotation key generation

**Status:** Open

**Description:**
The DTI (Drug Target Interaction) benchmark fails during MHE collective rotation key generation.

**Symptoms:**
- MHE public key and relin key generation complete
- Crashes during rotation key generation with:
  ```
  Receive socket connection broken: Connection reset by peer
  ValueError: Socket connection broken for msg_len of 8
  ```

**Backtrace location:**
- `sequre/stdlib/sequre/mpc/mhe.codon:987` at `_collective_rot_key_gen`

**Note:** This crash occurs during MHE setup itself, unlike other benchmarks that crash after MHE init. May indicate DTI requires different MHE parameters or has higher memory requirements.

**Tested with:**
- `./benchmark.sh --benchmark --syqure --dti`

---

### `--mnist` missing Python dependency

**Status:** Open (Missing Dependency)

**Description:**
The MNIST benchmark fails because it requires the `torchvision` Python module.

**Symptoms:**
```
PyError: No module named 'torchvision'
```

**Fix:**
```bash
pip install torchvision
```

**Tested with:**
- `./benchmark.sh --benchmark --syqure --mnist`

---

### `--ablation` crashes mid-way (OOM)

**Status:** Open (OOM)

**Description:**
The ablation study benchmark partially completes but crashes during later tests due to memory exhaustion.

**Completed before crash:**
- `enc-fac-pri`: 135.9s (completed)
- `enc-fac`: 72.0s (partial)

**Symptoms:**
- Crashes with socket connection error during MHE matmul operations
- Likely OOM killing one of the compute parties

**Backtrace location:**
- `sequre/types/ciphertensor.codon` during `_matmul_v3` operation

**Tested with:**
- `./benchmark.sh --benchmark --syqure --ablation`
