#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detect OS and architecture
detect_platform() {
  local os arch
  case "$(uname -s)" in
    Linux)  os="linux" ;;
    Darwin) os="macos" ;;
    *)      os="linux" ;;
  esac
  case "$(uname -m)" in
    x86_64)        arch="x86" ;;
    aarch64|arm64) arch="arm64" ;;
    *)             arch="x86" ;;
  esac
  echo "${os}-${arch}"
}

PLATFORM_ID="$(detect_platform)"

# Cleanup function to free ports and remove socket files (not processes - too dangerous)
cleanup_ports() {
  find "$SCRIPT_DIR" -name 'sock.*' -delete 2>/dev/null || true
  # Kill any process holding ports 9001-9003
  for port in 9001 9002 9003; do
    fuser -k "${port}/tcp" 2>/dev/null || true
  done
}

# Cleanup before starting
cleanup_ports
sleep 0.5

CODON_BIN="${CODON_BIN:-${SCRIPT_DIR}/bin/${PLATFORM_ID}/codon/bin/codon}"
SYQURE_BIN="${SYQURE_BIN:-${SCRIPT_DIR}/target/debug/syqure}"
SYQURE_BUNDLE_FILE="${SYQURE_BUNDLE_FILE:-${SCRIPT_DIR}/syqure/bundles/$(rustc -vV | awk '/host:/{print $2}').tar.zst}"
SYQURE_BUNDLE_CACHE="${SYQURE_BUNDLE_CACHE:-${SCRIPT_DIR}/target/syqure-cache}"
IMAGE_NAME="${IMAGE_NAME:-syqure-cli}"

MODE=""
BACKEND=""
EXAMPLE=""
BENCH_FLAGS=()
SKIP_MHE=0

usage() {
  cat <<EOF
Usage: $0 <mode> [backend] [options]

Modes:
  --syqure <example.codon>      Build and run example via syqure binary (timed)
  --codon <example.codon>       Run example via codon binary with sequre plugin (timed)
  --docker <example.codon>      Run example via docker container (timed)
  --benchmark [backend] [flags] Run sequre benchmark suite

Backends (for --benchmark mode, default: --codon):
  --syqure   Run benchmarks via syqure binary
  --codon    Run benchmarks via codon binary (default)
  --docker   Run benchmarks via docker container

Benchmark flags (use with --benchmark):
  --all              Run all benchmarks
  --lattiseq         Crypto operations timing
  --mpc              MPC operations
  --mhe              MHE operations
  --king             KING genetic kinship
  --pca              PCA
  --gwas-with-norm   GWAS with normalization
  --gwas-without-norm GWAS without normalization
  --credit-score     Credit score inference
  --dti              Drug target interaction
  --mnist            MNIST classification
  --ablation         Ablation study

General flags:
  --skip-mhe-setup   Skip MHE key generation (faster, but only for MPC-only workloads)

Examples:
  $0 --syqure example/two_party_sum_simple.codon
  $0 --codon example/two_party_sum_simple.codon
  $0 --docker example/two_party_sum_simple.codon
  $0 --syqure --skip-mhe-setup example/two_party_sum_simple.codon
  $0 --benchmark --all
  $0 --benchmark --codon --lattiseq --mpc
  $0 --benchmark --syqure --lattiseq
  $0 --benchmark --docker --lattiseq
  $0 --benchmark --mpc --skip-mhe-setup
EOF
}

# Parse arguments
while [ $# -gt 0 ]; do
  case "$1" in
    --benchmark) MODE="benchmark"; shift ;;
    --syqure)
      if [ "$MODE" = "benchmark" ]; then
        BACKEND="syqure"
      else
        MODE="syqure"
      fi
      shift
      ;;
    --codon)
      if [ "$MODE" = "benchmark" ]; then
        BACKEND="codon"
      else
        MODE="codon"
      fi
      shift
      ;;
    --docker)
      if [ "$MODE" = "benchmark" ]; then
        BACKEND="docker"
      else
        MODE="docker"
      fi
      shift
      ;;
    -h|--help)  usage; exit 0 ;;
    --skip-mhe-setup) SKIP_MHE=1; shift ;;
    --all|--lattiseq|--lattiseq-mult3|--mpc|--mhe|--king|--pca|--mi|\
    --gwas-with-norm|--gwas-without-norm|--credit-score|--dti|--mnist|\
    --ablation|--lin-alg|--stdlib-builtin)
      BENCH_FLAGS+=("$1")
      shift
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      EXAMPLE="$1"
      shift
      ;;
  esac
done

run_example_syqure() {
  if [ -z "$EXAMPLE" ]; then
    echo "Missing example file" >&2
    usage
    exit 1
  fi
  if [ ! -f "$EXAMPLE" ]; then
    echo "Example file not found: $EXAMPLE" >&2
    exit 1
  fi

  echo "==> Building syqure..."
  cargo build -p syqure

  local extra_args=()
  if [ "$SKIP_MHE" = "1" ]; then
    extra_args+=(-- --skip-mhe-setup)
  fi

  echo "==> Running syqure (timed)..."
  export SYQURE_BUNDLE_FILE
  export SYQURE_BUNDLE_CACHE
  time "$SYQURE_BIN" "$EXAMPLE" "${extra_args[@]}"
}

run_example_codon() {
  if [ -z "$EXAMPLE" ]; then
    echo "Missing example file" >&2
    usage
    exit 1
  fi
  if [ ! -f "$EXAMPLE" ]; then
    echo "Example file not found: $EXAMPLE" >&2
    exit 1
  fi
  if [ ! -x "$CODON_BIN" ]; then
    echo "Codon binary not found: $CODON_BIN" >&2
    exit 1
  fi

  local extra_args=()
  if [ "$SKIP_MHE" = "1" ]; then
    extra_args+=(--skip-mhe-setup)
  fi

  echo "==> Running codon with sequre plugin (timed)..."
  time "$CODON_BIN" run -plugin sequre "$EXAMPLE" "${extra_args[@]}"
}

run_example_docker() {
  if [ -z "$EXAMPLE" ]; then
    echo "Missing example file" >&2
    usage
    exit 1
  fi
  if [ ! -f "$EXAMPLE" ]; then
    echo "Example file not found: $EXAMPLE" >&2
    exit 1
  fi

  local extra_args=()
  if [ "$SKIP_MHE" = "1" ]; then
    extra_args+=(-- --skip-mhe-setup)
  fi

  echo "==> Running via docker (timed)..."
  time docker run --rm \
    -v "${SCRIPT_DIR}/example:/workspace/example:ro" \
    "$IMAGE_NAME" syqure "/workspace/example/$(basename "$EXAMPLE")" "${extra_args[@]}"
}

run_benchmark_codon() {
  if [ ! -x "$CODON_BIN" ]; then
    echo "Codon binary not found: $CODON_BIN" >&2
    exit 1
  fi

  local extra_flags=()
  if [ "$SKIP_MHE" = "1" ]; then
    extra_flags+=(--skip-mhe-setup)
  fi

  echo "==> Running sequre benchmark suite (codon)..."
  echo "    Flags: ${BENCH_FLAGS[*]} ${extra_flags[*]}"
  echo ""

  cd "$SCRIPT_DIR/sequre"
  time "$CODON_BIN" run -plugin sequre \
    scripts/invoke.codon run-benchmarks --local "${BENCH_FLAGS[@]}" "${extra_flags[@]}"
}

run_benchmark_syqure() {
  echo "==> Building syqure..."
  cargo build -p syqure

  local extra_flags=()
  if [ "$SKIP_MHE" = "1" ]; then
    extra_flags+=(--skip-mhe-setup)
  fi

  echo "==> Running sequre benchmark suite (syqure)..."
  echo "    Flags: ${BENCH_FLAGS[*]} ${extra_flags[*]}"
  echo ""

  export SYQURE_BUNDLE_FILE
  export SYQURE_BUNDLE_CACHE
  cd "$SCRIPT_DIR/sequre"
  time "$SYQURE_BIN" scripts/invoke.codon -- run-benchmarks --local "${BENCH_FLAGS[@]}" "${extra_flags[@]}"
}

run_benchmark_docker() {
  local extra_flags=()
  if [ "$SKIP_MHE" = "1" ]; then
    extra_flags+=(--skip-mhe-setup)
  fi

  echo "==> Running sequre benchmark suite (docker)..."
  echo "    Flags: ${BENCH_FLAGS[*]} ${extra_flags[*]}"
  echo ""

  time docker run --rm \
    -v "${SCRIPT_DIR}/sequre:/workspace/sequre:ro" \
    -w /workspace/sequre \
    "$IMAGE_NAME" syqure scripts/invoke.codon -- run-benchmarks --local "${BENCH_FLAGS[@]}" "${extra_flags[@]}"
}

run_benchmark() {
  if [ ${#BENCH_FLAGS[@]} -eq 0 ]; then
    echo "No benchmark flags specified. Use --all or specific flags like --lattiseq, --mpc, etc." >&2
    usage
    exit 1
  fi

  # Default to codon backend
  if [ -z "$BACKEND" ]; then
    BACKEND="codon"
  fi

  case "$BACKEND" in
    syqure) run_benchmark_syqure ;;
    codon)  run_benchmark_codon ;;
    docker) run_benchmark_docker ;;
  esac
}

if [ -z "$MODE" ]; then
  echo "Missing mode (--syqure, --codon, --docker, or --benchmark)" >&2
  usage
  exit 1
fi

case "$MODE" in
  syqure)    run_example_syqure ;;
  codon)     run_example_codon ;;
  docker)    run_example_docker ;;
  benchmark) run_benchmark ;;
esac
