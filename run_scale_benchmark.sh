#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE="he"
SIZES=(1 10 100 1000 10000)
DATA_DIR="${SCRIPT_DIR}/benchmark_data"
LOG_DIR="${SCRIPT_DIR}/benchmark_results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

usage() {
    cat <<EOF
Usage: $0 [--he|--smpc|--both] [--sizes "1 10 100"]

Options:
  --he           Run HE benchmark only (default)
  --smpc         Run SMPC benchmark only (with --skip-mhe-setup)
  --both         Run both HE and SMPC
  --sizes "..."  Space-separated list of sizes (default: "1 10 100 1000 10000")
  --generate     Regenerate input data
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --he) MODE="he"; shift ;;
        --smpc) MODE="smpc"; shift ;;
        --both) MODE="both"; shift ;;
        --sizes) IFS=' ' read -ra SIZES <<< "$2"; shift 2 ;;
        --generate) rm -rf "$DATA_DIR"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown: $1" >&2; usage; exit 1 ;;
    esac
done

mkdir -p "$LOG_DIR"

# Generate data if needed
if [ ! -d "$DATA_DIR" ]; then
    echo "Generating benchmark data..."
    python3 "${SCRIPT_DIR}/scripts/generate_benchmark_data.py"
    echo ""
fi

export SEQURE_CP_IPS="127.0.0.1,127.0.0.1,127.0.0.1"

run_single() {
    local example=$1
    local n=$2
    local extra_args=${3:-}
    local tmplog
    tmplog=$(mktemp)

    local pids_to_kill=()
    cleanup_run() {
        for p in "${pids_to_kill[@]}"; do
            kill "$p" 2>/dev/null || true
        done
        for p in "${pids_to_kill[@]}"; do
            wait "$p" 2>/dev/null || true
        done
    }
    trap cleanup_run RETURN

    export BENCHMARK_N="$n"
    export BENCHMARK_DATA_DIR="$DATA_DIR"

    cd "$SCRIPT_DIR"

    local wall_start
    wall_start=$(python3 -c "import time; print(f'{time.time():.6f}')")

    if [ -n "$extra_args" ]; then
        cargo run -p syqure -- $extra_args "${example}" -- 0 2>&1 | sed 's/^/[CP0] /' >> "$tmplog" &
    else
        cargo run -p syqure -- "${example}" -- 0 2>&1 | sed 's/^/[CP0] /' >> "$tmplog" &
    fi
    pids_to_kill+=($!)
    sleep 0.5

    if [ -n "$extra_args" ]; then
        cargo run -p syqure -- $extra_args "${example}" -- 1 2>&1 | sed 's/^/[CP1] /' >> "$tmplog" &
    else
        cargo run -p syqure -- "${example}" -- 1 2>&1 | sed 's/^/[CP1] /' >> "$tmplog" &
    fi
    pids_to_kill+=($!)

    if [ -n "$extra_args" ]; then
        cargo run -p syqure -- $extra_args "${example}" -- 2 2>&1 | sed 's/^/[CP2] /' >> "$tmplog" &
    else
        cargo run -p syqure -- "${example}" -- 2 2>&1 | sed 's/^/[CP2] /' >> "$tmplog" &
    fi
    pids_to_kill+=($!)

    for p in "${pids_to_kill[@]}"; do
        wait "$p" 2>/dev/null || true
    done
    trap - RETURN

    local wall_end
    wall_end=$(python3 -c "import time; print(f'{time.time():.6f}')")
    local wall_s
    wall_s=$(python3 -c "print(f'{$wall_end - $wall_start:.4f}')")

    echo "WALL_TIME ${wall_s}" >> "$tmplog"
    cat "$tmplog"
    rm -f "$tmplog"
}

get_metric() {
    local log=$1
    local key=$2
    grep "\[CP1\] METRIC ${key} " "$log" 2>/dev/null | head -1 | sed "s/.*METRIC ${key} //" || echo "-"
}

format_bytes() {
    local bytes=$1
    if [ "$bytes" = "-" ] || [ -z "$bytes" ]; then
        echo "-"
        return
    fi
    python3 -c "
b = int($bytes)
if b < 1024: print(f'{b} B')
elif b < 1048576: print(f'{b/1024:.1f} KB')
elif b < 1073741824: print(f'{b/1048576:.1f} MB')
else: print(f'{b/1073741824:.2f} GB')
"
}

run_suite() {
    local mode_label=$1
    local example=$2
    local extra_args=${3:-}
    local result_file="${LOG_DIR}/scale_${mode_label}_${TIMESTAMP}.txt"
    local raw_dir="${LOG_DIR}/scale_${mode_label}_${TIMESTAMP}_raw"
    mkdir -p "$raw_dir"

    echo ""
    echo "====================================================="
    echo "  ${mode_label} Scale Benchmark"
    echo "  Date: $(date)"
    echo "====================================================="
    echo ""

    # Header
    printf "| %-7s | %-10s | %-10s | %-10s | %-10s | %-12s | %-10s | %-6s | %-12s |\n" \
        "N" "Setup(s)" "Compute(s)" "Comm(s)" "Total(s)" "Data Sent" "Msgs" "Recvs" "Wall(s)"
    printf "|%s|%s|%s|%s|%s|%s|%s|%s|%s|\n" \
        "---------" "------------" "------------" "------------" "------------" "--------------" "------------" "--------" "--------------"

    local first_run=true
    for n in "${SIZES[@]}"; do
        if [ "$first_run" = true ]; then
            first_run=false
        else
            echo "  Waiting 10s for port TIME_WAIT cleanup..." >&2
            sleep 10
        fi
        echo "  Running N=${n}..." >&2
        local run_log
        run_log=$(mktemp)
        run_single "$example" "$n" "$extra_args" > "$run_log" 2>&1

        cp "$run_log" "${raw_dir}/n${n}.log"

        local setup_s=$(get_metric "$run_log" "setup_time_s")
        local compute_s=$(get_metric "$run_log" "compute_time_s")
        local total_s=$(get_metric "$run_log" "total_time_s")
        local comp_bytes=$(get_metric "$run_log" "compute_bytes")
        local comp_sends=$(get_metric "$run_log" "compute_sends")
        local comp_recvs=$(get_metric "$run_log" "compute_receives")
        local wall_s=$(grep "WALL_TIME" "$run_log" 2>/dev/null | tail -1 | awk '{print $2}')

        local comm_s="-"
        if grep -q "\[CP1\] METRIC communication_time_s" "$run_log" 2>/dev/null; then
            comm_s=$(get_metric "$run_log" "communication_time_s")
        elif grep -q "\[CP1\] METRIC secret_sharing_time_s" "$run_log" 2>/dev/null; then
            comm_s=$(get_metric "$run_log" "secret_sharing_time_s")
        fi

        local data_fmt=$(format_bytes "$comp_bytes")

        printf "| %-7s | %-10s | %-10s | %-10s | %-10s | %-12s | %-10s | %-6s | %-12s |\n" \
            "$n" "$setup_s" "$compute_s" "$comm_s" "$total_s" "$data_fmt" "$comp_sends" "$comp_recvs" "${wall_s:-"-"}"

        rm -f "$run_log"
    done

    echo ""

    # Also show MHE setup cost (same for all N in HE mode)
    if [ "$mode_label" = "HE" ]; then
        echo "Note: Setup time includes MHE key generation (~25s). This is a one-time cost."
        echo "      MHE setup transfers ~1.1 GB for collective key generation (pub + relin + 64 rotation keys)."
    else
        echo "Note: SMPC mode uses --skip-mhe-setup. Setup is MPC channel init only (~1.7s)."
    fi
    echo ""
}

{
    if [ "$MODE" = "he" ] || [ "$MODE" = "both" ]; then
        run_suite "HE" "example/allele_freq_scale_he.codon" ""
    fi

    if [ "$MODE" = "smpc" ] || [ "$MODE" = "both" ]; then
        run_suite "SMPC" "example/allele_freq_scale_smpc.codon" "--skip-mhe-setup"
    fi
} 2>&1 | tee "${LOG_DIR}/scale_${MODE}_${TIMESTAMP}_summary.txt"

echo ""
echo "Results saved to: ${LOG_DIR}/scale_${MODE}_${TIMESTAMP}_summary.txt"
