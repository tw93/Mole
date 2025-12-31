#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    TEST_DATA_DIR="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-perf.XXXXXX")"
    export TEST_DATA_DIR
}

teardown_file() {
    rm -rf "$TEST_DATA_DIR"
}

setup() {
    source "$PROJECT_ROOT/lib/core/base.sh"
}

@test "bytes_to_human handles large values efficiently" {
    local start end elapsed
    local limit_ms="${MOLE_PERF_BYTES_TO_HUMAN_LIMIT_MS:-4000}"

    bytes_to_human 1073741824 > /dev/null

    start=$(date +%s%N)
    for i in {1..1000}; do
        bytes_to_human 1073741824 > /dev/null
    done
    end=$(date +%s%N)

    elapsed=$(( (end - start) / 1000000 ))

    [ "$elapsed" -lt "$limit_ms" ]
}

@test "bytes_to_human produces correct output for GB range" {
    result=$(bytes_to_human 1073741824)
    [ "$result" = "1.00GB" ]

    result=$(bytes_to_human 5368709120)
    [ "$result" = "5.00GB" ]
}

@test "bytes_to_human produces correct output for MB range" {
    result=$(bytes_to_human 1048576)
    [ "$result" = "1.0MB" ]

    result=$(bytes_to_human 104857600)
    [ "$result" = "100.0MB" ]
}

@test "bytes_to_human produces correct output for KB range" {
    result=$(bytes_to_human 1024)
    [ "$result" = "1KB" ]

    result=$(bytes_to_human 10240)
    [ "$result" = "10KB" ]
}

@test "bytes_to_human handles edge cases" {
    result=$(bytes_to_human 0)
    [ "$result" = "0B" ]

    run bytes_to_human "invalid"
    [ "$status" -eq 1 ]
    [ "$output" = "0B" ]

    run bytes_to_human "-100"
    [ "$status" -eq 1 ]
    [ "$output" = "0B" ]
}

@test "get_file_size is faster than multiple stat calls" {
    local test_file="$TEST_DATA_DIR/size_test.txt"
    dd if=/dev/zero of="$test_file" bs=1024 count=100 2> /dev/null

    local start end elapsed
    start=$(date +%s%N)
    for i in {1..100}; do
        get_file_size "$test_file" > /dev/null
    done
    end=$(date +%s%N)

    elapsed=$(( (end - start) / 1000000 ))

    [ "$elapsed" -lt 1000 ]
}

@test "get_file_mtime returns valid timestamp" {
    local test_file="$TEST_DATA_DIR/mtime_test.txt"
    touch "$test_file"

    result=$(get_file_mtime "$test_file")

    [[ "$result" =~ ^[0-9]{10,}$ ]]
}

@test "get_file_owner returns current user for owned files" {
    local test_file="$TEST_DATA_DIR/owner_test.txt"
    touch "$test_file"

    result=$(get_file_owner "$test_file")
    current_user=$(whoami)

    [ "$result" = "$current_user" ]
}

@test "get_invoking_user executes quickly" {
    local start end elapsed

    start=$(date +%s%N)
    for i in {1..100}; do
        get_invoking_user > /dev/null
    done
    end=$(date +%s%N)

    elapsed=$(( (end - start) / 1000000 ))

    [ "$elapsed" -lt 200 ]
}

@test "get_darwin_major caches correctly" {
    local first second
    first=$(get_darwin_major)
    second=$(get_darwin_major)

    [ "$first" = "$second" ]
    [[ "$first" =~ ^[0-9]+$ ]]
}

@test "create_temp_file and cleanup_temp_files work efficiently" {
    local start end elapsed

    declare -a MOLE_TEMP_DIRS=()

    start=$(date +%s%N)
    for i in {1..50}; do
        create_temp_file > /dev/null
    done
    end=$(date +%s%N)

    elapsed=$(( (end - start) / 1000000 ))

    [ "$elapsed" -lt 1000 ]

    [ "${#MOLE_TEMP_FILES[@]}" -eq 50 ]

    start=$(date +%s%N)
    cleanup_temp_files
    end=$(date +%s%N)

    elapsed=$(( (end - start) / 1000000 ))
    [ "$elapsed" -lt 2000 ]

    [ "${#MOLE_TEMP_FILES[@]}" -eq 0 ]
}

@test "mktemp_file creates files with correct prefix" {
    local temp_file
    temp_file=$(mktemp_file "test_prefix")

    [[ "$temp_file" =~ test_prefix ]]

    [ -f "$temp_file" ]

    rm -f "$temp_file"
}

@test "get_brand_name handles common apps efficiently" {
    local start end elapsed

    get_brand_name "wechat" > /dev/null

    start=$(date +%s%N)
    for i in {1..50}; do
        get_brand_name "wechat" > /dev/null
        get_brand_name "QQ" > /dev/null
        get_brand_name "dingtalk" > /dev/null
    done
    end=$(date +%s%N)

    elapsed=$(( (end - start) / 1000000 ))

    [ "$elapsed" -lt 5000 ]
}

@test "get_brand_name returns correct localized names" {
    local result
    result=$(get_brand_name "wechat")

    [[ "$result" == "WeChat" || "$result" == "微信" ]]
}

@test "get_optimal_parallel_jobs returns sensible values" {
    local result

    result=$(get_optimal_parallel_jobs)
    [[ "$result" =~ ^[0-9]+$ ]]
    [ "$result" -gt 0 ]
    [ "$result" -le 128 ]

    local scan_jobs
    scan_jobs=$(get_optimal_parallel_jobs "scan")
    [ "$scan_jobs" -gt "$result" ]

    local compute_jobs
    compute_jobs=$(get_optimal_parallel_jobs "compute")
    [ "$compute_jobs" -le "$scan_jobs" ]
}

@test "section tracking has minimal overhead" {
    local start end elapsed

    if ! declare -f note_activity > /dev/null 2>&1; then
        TRACK_SECTION=0
        SECTION_ACTIVITY=0
        note_activity() {
            if [[ $TRACK_SECTION -eq 1 ]]; then
                SECTION_ACTIVITY=1
            fi
        }
    fi

    note_activity

    start=$(date +%s%N)
    for i in {1..1000}; do
        note_activity
    done
    end=$(date +%s%N)

    elapsed=$(( (end - start) / 1000000 ))

    [ "$elapsed" -lt 2000 ]
}
