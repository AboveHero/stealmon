#!/usr/bin/env bash
#
# stealmon.sh - simple CPU steal time logger for Linux
#
# Collects CPU steal percentage at a fixed interval from /proc/stat
# and logs timestamp, current steal%, run-average, and run-peak.
#
# Intended to be run as a long-lived service (e.g. via systemd).
#

set -u
set -o pipefail

# -------------------------
# Configuration (defaults)
# -------------------------

INTERVAL_SECONDS="${INTERVAL_SECONDS:-5}"          # sample interval
LOG_DIR="${LOG_DIR:-/var/log/stealmon}"           # log directory
LOG_FILE_BASENAME="${LOG_FILE_BASENAME:-stealmon}"
MAX_LOG_SIZE_BYTES="${MAX_LOG_SIZE_BYTES:-10485760}" # 10 MiB default
RETENTION_FILES="${RETENTION_FILES:-5}"           # number of rotated logs to keep
CPU_MODE="${CPU_MODE:-all}"                       # "all" or "0,1" for specific CPUs

# -------------------------
# Internal state
# -------------------------

TOTAL_SAMPLES=0
SUM_STEAL=0
PEAK_STEAL=0

# -------------------------
# Helpers
# -------------------------

err() {
    printf '[%s] ERROR: %s\n' "$(date -Is)" "$*" >&2
}

info() {
    printf '[%s] INFO: %s\n' "$(date -Is)" "$*" >&2
}

usage() {
    cat <<EOF
stealmon.sh - CPU steal time logger

Environment variables:

  INTERVAL_SECONDS     Sampling interval in seconds (default: 5)
  LOG_DIR              Directory for logs (default: /var/log/stealmon)
  LOG_FILE_BASENAME    Log file base name (default: stealmon)
  MAX_LOG_SIZE_BYTES   Rotate log when size exceeds this (default: 10485760 = 10 MiB)
  RETENTION_FILES      Number of rotated logs to keep (default: 5)
  CPU_MODE             "all" (aggregate) or comma-separated CPU IDs (e.g., "0,1")

Examples:

  INTERVAL_SECONDS=1 LOG_DIR=/tmp/stealmon ./stealmon.sh
  CPU_MODE=0 ./stealmon.sh

EOF
}

# -------------------------
# Log rotation
# -------------------------

rotate_logs_if_needed() {
    local log_file="$1"

    if [[ ! -f "$log_file" ]]; then
        return 0
    fi

    local size
    size=$(stat -c%s "$log_file" 2>/dev/null || echo 0)

    if [[ "$size" -lt "$MAX_LOG_SIZE_BYTES" ]]; then
        return 0
    fi

    info "Rotating log $log_file (size=${size}B > ${MAX_LOG_SIZE_BYTES}B)"

    if [[ "$RETENTION_FILES" -gt 0 ]]; then
        rm -f "${log_file}.${RETENTION_FILES}" 2>/dev/null || true

        local i
        for (( i=RETENTION_FILES-1; i>=1; i-- )); do
            if [[ -f "${log_file}.${i}" ]]; then
                mv "${log_file}.${i}" "${log_file}.$((i+1))"
            fi
        done

        mv "$log_file" "${log_file}.1"
    else
        : > "$log_file"
    fi
}

# -------------------------
# Steal calculation helpers
# -------------------------

read_proc_stat_line() {
    local cpu_id="$1"

    if [[ "$cpu_id" == "all" ]]; then
        awk '/^cpu / {print}' /proc/stat
    else
        awk -v id="$cpu_id" '$1 == ("cpu" id) {print}' /proc/stat
    fi
}

parse_cpu_line_totals() {
    awk '
    {
        total = $2 + $3 + $4 + $5 + $6 + $7 + $8 + $9 + $10 + $11;
        steal = $9;
        print total, steal;
    }'
}

get_steal_percent_once() {
    local mode="$1"
    local interval="$2"

    local cpu_list=()
    if [[ "$mode" == "all" ]]; then
        cpu_list=("all")
    else
        IFS=',' read -r -a cpu_list <<< "$mode"
    fi

    local -a t1_totals=()
    local -a t1_steals=()
    local -a t2_totals=()
    local -a t2_steals=()

    local idx=0
    local line

    for cpu in "${cpu_list[@]}"; do
        line=$(read_proc_stat_line "$cpu") || continue
        read -r total steal <<< "$(printf '%s\n' "$line" | parse_cpu_line_totals)"
        t1_totals[$idx]=$total
        t1_steals[$idx]=$steal
        ((idx++))
    done

    sleep "$interval"

    idx=0
    for cpu in "${cpu_list[@]}"; do
        line=$(read_proc_stat_line "$cpu") || continue
        read -r total steal <<< "$(printf '%s\n' "$line" | parse_cpu_line_totals)"
        t2_totals[$idx]=$total
        t2_steals[$idx]=$steal
        ((idx++))
    done

    local count="${#t1_totals[@]}"
    if [[ "$count" -eq 0 ]]; then
        echo "0"
        return 0
    fi

    local sum_pct=0

    for (( i=0; i<count; i++ )); do
        local dt=$(( t2_totals[$i] - t1_totals[$i] ))
        local ds=$(( t2_steals[$i] - t1_steals[$i] ))

        if (( dt <= 0 )); then
            continue
        fi

        local pct
        pct=$(awk -v ds="$ds" -v dt="$dt" 'BEGIN { if (dt <= 0) print 0; else printf "%.2f", (100.0 * ds / dt) }')
        sum_pct=$(awk -v a="$sum_pct" -v b="$pct" 'BEGIN { printf "%.2f", a + b }')
    done

    local avg
    avg=$(awk -v s="$sum_pct" -v c="$count" 'BEGIN { if (c <= 0) print 0; else printf "%.2f", s / c }')
    echo "$avg"
}

# -------------------------
# Main
# -------------------------

main() {
    if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
        usage
        exit 0
    fi

    if [[ ! -r /proc/stat ]]; then
        err "/proc/stat is not readable"
        exit 1
    fi

    mkdir -p "$LOG_DIR" || {
        err "Failed to create log dir: $LOG_DIR"
        exit 1
    }

    local log_file="${LOG_DIR}/${LOG_FILE_BASENAME}.log"

    info "Starting stealmon: interval=${INTERVAL_SECONDS}s log=${log_file} cpu_mode=${CPU_MODE}"

    if [[ ! -f "$log_file" ]]; then
        printf "# timestamp iso8601 | steal_pct | run_avg_steal_pct | run_peak_steal_pct | samples\n" >> "$log_file"
    fi

    while true; do
        rotate_logs_if_needed "$log_file"

        local steal
        steal=$(get_steal_percent_once "$CPU_MODE" "$INTERVAL_SECONDS") || steal="0"

        TOTAL_SAMPLES=$((TOTAL_SAMPLES + 1))
        SUM_STEAL=$(awk -v sum="$SUM_STEAL" -v s="$steal" 'BEGIN { printf "%.2f", sum + s }')

        local avg
        avg=$(awk -v sum="$SUM_STEAL" -v n="$TOTAL_SAMPLES" 'BEGIN { if (n <= 0) print 0; else printf "%.2f", sum / n }')

        local peak
        peak=$(awk -v cur="$steal" -v old="$PEAK_STEAL" 'BEGIN { if (cur > old) printf "%.2f", cur; else printf "%.2f", old }')
        PEAK_STEAL="$peak"

        local ts
        ts="$(date -Is)"

        printf "%s | %s | %s | %s | %s\n" "$ts" "$steal" "$avg" "$peak" "$TOTAL_SAMPLES" >> "$log_file"
    done
}

main "$@"