#!/usr/bin/env bash
# Benchmark the read-only uninstall application scan.
#
# Usage:
#   tests/performance_uninstall_scan.sh [runs]
#
# The benchmark calls scan_applications directly with bin/uninstall.sh sourced
# under a test harness. This isolates the UI's "collecting data" path from
# unrelated `--list` formatting and Homebrew-name lookup work while still using
# the same scanner code as the interactive uninstaller.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNS="${1:-5}"

if [[ ! "$RUNS" =~ ^[0-9]+$ || "$RUNS" -lt 1 ]]; then
    echo "runs must be a positive integer" >&2
    exit 2
fi

now_ms() {
    python3 - << 'PY'
import time
print(time.perf_counter_ns() // 1_000_000)
PY
}

tmp_dir="$(mktemp -d)"
cleanup() {
    rm -f "$tmp_dir"/* 2> /dev/null || true
    rmdir "$tmp_dir" 2> /dev/null || true
}
trap cleanup EXIT

uninstall_source="$tmp_dir/uninstall_source.sh"
awk -v script_dir="$REPO_ROOT/bin" '
    /^SCRIPT_DIR=/ {
        print "SCRIPT_DIR=\"" script_dir "\""
        next
    }
    /^main "\$@"/ {
        print "# main skipped by performance_uninstall_scan.sh"
        next
    }
    { print }
' "$REPO_ROOT/bin/uninstall.sh" > "$uninstall_source"

durations_file="$tmp_dir/durations"
: > "$durations_file"

printf 'run,duration_ms,app_count,status\n'

for ((run = 1; run <= RUNS; run++)); do
    out_file="$tmp_dir/out.$run"
    err_file="$tmp_dir/err.$run"
    start_ms="$(now_ms)"
    set +e
    ROOMY_TEST_NO_AUTH=1 bash -c '
        set -euo pipefail
        # shellcheck source=/dev/null
        source "$1"
        apps_file="$(scan_applications 2> /dev/null)"
        app_count="$(wc -l < "$apps_file" | tr -d "[:space:]")"
        rm -f "$apps_file"
        printf "%s\n" "$app_count"
    ' bash "$uninstall_source" > "$out_file" 2> "$err_file"
    status=$?
    set -e
    end_ms="$(now_ms)"
    duration_ms=$((end_ms - start_ms))

    app_count="$(cat "$out_file" 2> /dev/null || echo 0)"
    printf '%d,%d,%s,%d\n' "$run" "$duration_ms" "${app_count:-0}" "$status"
    printf '%d\n' "$duration_ms" >> "$durations_file"
done

python3 - "$durations_file" << 'PY'
import statistics
import sys
from pathlib import Path

values = [int(line) for line in Path(sys.argv[1]).read_text().splitlines() if line.strip()]
if not values:
    raise SystemExit(0)

print(
    "summary,"
    f"min_ms={min(values)},"
    f"median_ms={int(statistics.median(values))},"
    f"mean_ms={int(statistics.fmean(values))},"
    f"max_ms={max(values)},"
    f"runs={len(values)}"
)
PY
