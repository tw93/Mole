#!/usr/bin/env bats

# Tests for get_path_size_kb in lib/core/file_ops.sh.
# Exercises the stat fast-path for regular files / symlinks and the du
# fallback for directories, plus error and edge cases. Numbers chosen to
# reveal rounding bugs (KB ceiling) and to confirm symlinks are NOT
# followed.

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT
}

setup() {
    SANDBOX="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-fileops-size.XXXXXX")"
    export SANDBOX
    export ROOMY_TEST_NO_AUTH=1
}

teardown() {
    rm -rf "$SANDBOX"
}

prelude() {
    cat << EOF
set -euo pipefail
export ROOMY_TEST_NO_AUTH=1
source "$PROJECT_ROOT/lib/core/common.sh"
EOF
}

@test "get_path_size_kb returns 0 for empty path" {
    run bash --noprofile --norc << EOF
$(prelude)
get_path_size_kb ""
EOF
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "get_path_size_kb returns 0 for non-existent path" {
    run bash --noprofile --norc << EOF
$(prelude)
get_path_size_kb "$SANDBOX/does-not-exist"
EOF
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "get_path_size_kb returns 0 for empty file" {
    : > "$SANDBOX/empty"
    run bash --noprofile --norc << EOF
$(prelude)
get_path_size_kb "$SANDBOX/empty"
EOF
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "get_path_size_kb rounds up sub-KB files to 1 KB" {
    # 500 bytes is < 1 KB; ceiling rounding should report 1.
    dd if=/dev/zero of="$SANDBOX/small" bs=500 count=1 2> /dev/null
    run bash --noprofile --norc << EOF
$(prelude)
get_path_size_kb "$SANDBOX/small"
EOF
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "get_path_size_kb reports exact 1 KB for 1024-byte file" {
    dd if=/dev/zero of="$SANDBOX/onek" bs=1024 count=1 2> /dev/null
    run bash --noprofile --norc << EOF
$(prelude)
get_path_size_kb "$SANDBOX/onek"
EOF
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "get_path_size_kb rounds up odd byte counts" {
    # 50000 bytes / 1024 = 48.83..., ceiling is 49.
    dd if=/dev/zero of="$SANDBOX/odd" bs=50000 count=1 2> /dev/null
    run bash --noprofile --norc << EOF
$(prelude)
get_path_size_kb "$SANDBOX/odd"
EOF
    [ "$status" -eq 0 ]
    [ "$output" = "49" ]
}

@test "get_path_size_kb does not follow symlinks" {
    # 100 KB target, symlink should report its own (tiny) size, not 100 KB.
    dd if=/dev/zero of="$SANDBOX/target" bs=1024 count=100 2> /dev/null
    ln -s "$SANDBOX/target" "$SANDBOX/link"

    target_kb=$(bash --noprofile --norc << EOF
$(prelude)
get_path_size_kb "$SANDBOX/target"
EOF
)
    link_kb=$(bash --noprofile --norc << EOF
$(prelude)
get_path_size_kb "$SANDBOX/link"
EOF
)

    [ "$target_kb" = "100" ]
    # Symlink path strings are short, so link size rounds to 1 KB or 0.
    # Either is acceptable; what must NOT happen is the link reporting the
    # 100 KB target size.
    [ "$link_kb" -lt 10 ]
}

@test "get_path_size_kb still returns 0 for broken symlinks" {
    ln -s "$SANDBOX/missing" "$SANDBOX/broken"
    run bash --noprofile --norc << EOF
$(prelude)
get_path_size_kb "$SANDBOX/broken"
EOF
    [ "$status" -eq 0 ]
    # -e on a broken symlink returns false, so the early return triggers.
    [ "$output" = "0" ]
}

@test "get_path_size_kb sums directory contents recursively" {
    mkdir -p "$SANDBOX/dir/sub"
    dd if=/dev/zero of="$SANDBOX/dir/a" bs=1024 count=10 2> /dev/null
    dd if=/dev/zero of="$SANDBOX/dir/sub/b" bs=1024 count=20 2> /dev/null

    run bash --noprofile --norc << EOF
$(prelude)
get_path_size_kb "$SANDBOX/dir"
EOF
    [ "$status" -eq 0 ]
    # Should be at least the sum of the two files (30 KB). Filesystem
    # overhead may push it slightly higher, so use >= rather than ==.
    [ "$output" -ge 30 ]
}

@test "get_path_size_kb handles whitespace in paths" {
    local quirky="$SANDBOX/dir with spaces"
    mkdir -p "$quirky"
    dd if=/dev/zero of="$quirky/payload" bs=1024 count=5 2> /dev/null

    run bash --noprofile --norc << EOF
$(prelude)
get_path_size_kb "$quirky/payload"
EOF
    [ "$status" -eq 0 ]
    [ "$output" = "5" ]
}
