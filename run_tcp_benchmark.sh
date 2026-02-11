#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

EXAMPLE=""
RUNS="1"
SKIP_MHE=0
SYQURE_EXTRA_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-mhe-setup) SKIP_MHE=1; shift ;;
        --runs) RUNS="$2"; shift 2 ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *)
            if [ -z "$EXAMPLE" ]; then
                EXAMPLE="$1"
            else
                RUNS="$1"
            fi
            shift
            ;;
    esac
done

EXAMPLE="${EXAMPLE:-example/allele_freq_benchmark_he.codon}"

if [ "$SKIP_MHE" = "1" ]; then
    SYQURE_EXTRA_ARGS=(--skip-mhe-setup)
fi

LOG_DIR="${SCRIPT_DIR}/benchmark_results"

mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BASENAME=$(basename "$EXAMPLE" .codon)
RAW_LOG="${LOG_DIR}/${BASENAME}_${TIMESTAMP}.log"
SUMMARY="${LOG_DIR}/${BASENAME}_${TIMESTAMP}_summary.txt"

echo "Benchmark: ${EXAMPLE}"
echo "Runs: ${RUNS}"
echo "Log: ${RAW_LOG}"
echo ""

export SEQURE_CP_IPS="127.0.0.1,127.0.0.1,127.0.0.1"

run_once() {
    local run_id=$1
    local tmplog
    tmplog=$(mktemp)

    cleanup() {
        kill $PID0 $PID1 $PID2 2>/dev/null || true
        wait $PID0 $PID1 $PID2 2>/dev/null || true
    }
    trap cleanup RETURN

    cd "$SCRIPT_DIR"

    local wall_start
    wall_start=$(python3 -c "import time; print(f'{time.time():.6f}')")

    cargo run -p syqure -- ${SYQURE_EXTRA_ARGS[@]+"${SYQURE_EXTRA_ARGS[@]}"} "${EXAMPLE}" -- 0 2>&1 | sed 's/^/[CP0] /' >> "$tmplog" &
    PID0=$!
    sleep 0.5
    cargo run -p syqure -- ${SYQURE_EXTRA_ARGS[@]+"${SYQURE_EXTRA_ARGS[@]}"} "${EXAMPLE}" -- 1 2>&1 | sed 's/^/[CP1] /' >> "$tmplog" &
    PID1=$!
    cargo run -p syqure -- ${SYQURE_EXTRA_ARGS[@]+"${SYQURE_EXTRA_ARGS[@]}"} "${EXAMPLE}" -- 2 2>&1 | sed 's/^/[CP2] /' >> "$tmplog" &
    PID2=$!

    wait $PID0 $PID1 $PID2 || true
    trap - RETURN

    local wall_end
    wall_end=$(python3 -c "import time; print(f'{time.time():.6f}')")
    local wall_elapsed
    wall_elapsed=$(python3 -c "print(f'{$wall_end - $wall_start:.4f}')")

    echo "--- RUN ${run_id} (wall=${wall_elapsed}s) ---" >> "$RAW_LOG"
    cat "$tmplog" >> "$RAW_LOG"
    echo "" >> "$RAW_LOG"

    echo "WALL_TIME ${wall_elapsed}" >> "$tmplog"
    cat "$tmplog"
    rm -f "$tmplog"
}

extract_metrics() {
    local log_file=$1
    local party=$2

    grep "^\[CP${party}\] METRIC " "$log_file" | sed "s/^\[CP${party}\] METRIC //"
}

format_summary() {
    local log_file=$1

    echo "============================================="
    echo "  BENCHMARK SUMMARY"
    echo "  Example: ${EXAMPLE}"
    echo "  Date: $(date)"
    echo "  Runs: ${RUNS}"
    echo "============================================="
    echo ""

    for party in 1 2; do
        echo "--- CP${party} Metrics ---"
        if grep -q "\[CP${party}\] METRIC " "$log_file" 2>/dev/null; then
            extract_metrics "$log_file" "$party" | while IFS=' ' read -r key value; do
                case "$key" in
                    mode) printf "  %-30s %s\n" "Mode:" "$value" ;;
                    setup_time_s) printf "  %-30s %s s\n" "Setup time (MHE keygen):" "$value" ;;
                    encryption_time_s) printf "  %-30s %s s\n" "Encryption time:" "$value" ;;
                    secret_sharing_time_s) printf "  %-30s %s s\n" "Secret sharing time:" "$value" ;;
                    communication_time_s) printf "  %-30s %s s\n" "Communication time:" "$value" ;;
                    compute_time_s) printf "  %-30s %s s\n" "Computation time:" "$value" ;;
                    reveal_time_s) printf "  %-30s %s s\n" "Reveal/decrypt time:" "$value" ;;
                    total_time_s) printf "  %-30s %s s\n" "Total time:" "$value" ;;
                    mhe_setup_bytes) printf "  %-30s %s bytes\n" "MHE setup bytes:" "$value" ;;
                    mhe_setup_sends) printf "  %-30s %s\n" "MHE setup send msgs:" "$value" ;;
                    mhe_setup_receives) printf "  %-30s %s\n" "MHE setup recv msgs:" "$value" ;;
                    compute_bytes) printf "  %-30s %s bytes\n" "Compute bytes sent:" "$value" ;;
                    compute_sends) printf "  %-30s %s\n" "Compute send msgs:" "$value" ;;
                    compute_receives) printf "  %-30s %s\n" "Compute recv msgs:" "$value" ;;
                    total_bytes) printf "  %-30s %s bytes\n" "Total bytes:" "$value" ;;
                    total_sends) printf "  %-30s %s\n" "Total send msgs:" "$value" ;;
                    total_receives) printf "  %-30s %s\n" "Total recv msgs:" "$value" ;;
                    compute_mb) printf "  %-30s %s MB\n" "Compute MB:" "$value" ;;
                    total_mb) printf "  %-30s %s MB\n" "Total MB:" "$value" ;;
                    throughput_mb_per_s) printf "  %-30s %s MB/s\n" "Throughput:" "$value" ;;
                    throughput_msgs_per_s) printf "  %-30s %s msgs/s\n" "Message rate:" "$value" ;;
                    *) printf "  %-30s %s\n" "${key}:" "$value" ;;
                esac
            done
        else
            echo "  (no metrics captured)"
        fi
        echo ""
    done

    wall_time=$(grep "WALL_TIME" "$log_file" | tail -1 | awk '{print $2}')
    if [ -n "${wall_time:-}" ]; then
        echo "--- Wall Clock ---"
        printf "  %-30s %s s\n" "Total wall time:" "$wall_time"
        echo ""
    fi
}

ALL_OUTPUT=$(mktemp)

for i in $(seq 1 "$RUNS"); do
    echo "==> Run $i/$RUNS..."
    run_once "$i" >> "$ALL_OUTPUT"
    echo ""
done

format_summary "$ALL_OUTPUT" | tee "$SUMMARY"

echo ""
echo "Raw log:  ${RAW_LOG}"
echo "Summary:  ${SUMMARY}"

rm -f "$ALL_OUTPUT"
