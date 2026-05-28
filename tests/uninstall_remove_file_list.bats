#!/usr/bin/env bats

# Tests for remove_file_list batching in lib/uninstall/batch.sh.
# Exercises the batched Trash path (single _roomy_move_to_trash_batch call for
# eligible files) and the fallback when the batch helper fails.

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT
}

setup() {
    SANDBOX="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-uninstall-batch.XXXXXX")"
    export SANDBOX
    export ROOMY_DELETE_LOG="$SANDBOX/deletions.log"
    export ROOMY_TEST_TRASH_DIR="$SANDBOX/Trash"
    export ROOMY_TEST_NO_AUTH=1
    export ROOMY_DELETE_MODE=trash
    unset ROOMY_DRY_RUN
    HOME="$SANDBOX/home"
    mkdir -p "$HOME"
    export HOME
}

teardown() {
    rm -rf "$SANDBOX"
}

prelude() {
    cat <<EOF
set -euo pipefail
export ROOMY_DELETE_LOG="$ROOMY_DELETE_LOG"
export ROOMY_TEST_TRASH_DIR="$ROOMY_TEST_TRASH_DIR"
export ROOMY_TEST_NO_AUTH=1
export ROOMY_DELETE_MODE=trash
export HOME="$HOME"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
EOF
}

@test "remove_file_list batches eligible Trash moves into a single helper call" {
    local f1="$SANDBOX/a.plist"
    local f2="$SANDBOX/b.plist"
    local f3="$SANDBOX/c.plist"
    local f4="$SANDBOX/d.plist"
    local f5="$SANDBOX/e.plist"
    : > "$f1"
    : > "$f2"
    : > "$f3"
    : > "$f4"
    : > "$f5"
    local list
    printf -v list '%s\n%s\n%s\n%s\n%s' "$f1" "$f2" "$f3" "$f4" "$f5"

    local count_file="$SANDBOX/batch_calls"
    : > "$count_file"

    # Stub the batch helper to (1) record how many times it was called and
    # how many paths each call covered, (2) emulate the real test-harness
    # behavior by mv'ing each path into ROOMY_TEST_TRASH_DIR. This lets the
    # test assert both "called once" and "every file landed in trash".
    run bash --noprofile --norc <<EOF
$(prelude)
_roomy_move_to_trash_batch() {
    mkdir -p "\$ROOMY_TEST_TRASH_DIR"
    printf 'call %d\n' "\$#" >> "$count_file"
    local p dest
    for p in "\$@"; do
        dest="\$ROOMY_TEST_TRASH_DIR/\$(basename "\$p").stub.\$RANDOM"
        mv "\$p" "\$dest" 2>/dev/null || return 1
    done
    return 0
}
remove_file_list "$list" "false"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"5"* ]] # remove_file_list echoes count

    # All five files moved to the stub trash dir.
    local in_trash
    in_trash=$(find "$ROOMY_TEST_TRASH_DIR" -type f | wc -l | tr -d ' ')
    [ "$in_trash" -eq 5 ]
    for f in "$f1" "$f2" "$f3" "$f4" "$f5"; do
        [[ ! -e "$f" ]]
    done

    # Single batch invocation, with all five paths.
    local call_count
    call_count=$(wc -l < "$count_file" | tr -d ' ')
    [ "$call_count" -eq 1 ]
    grep -q '^call 5$' "$count_file"

    # Audit log records one ok line per moved path.
    local ok_lines
    ok_lines=$(awk -F'\t' '$4 == "ok" && $2 == "trash"' "$ROOMY_DELETE_LOG" | wc -l | tr -d ' ')
    [ "$ok_lines" -eq 5 ]
}

@test "remove_file_list falls through to per-file path when batch helper fails" {
    local f1="$SANDBOX/x.plist"
    local f2="$SANDBOX/y.plist"
    : > "$f1"
    : > "$f2"
    local list
    printf -v list '%s\n%s' "$f1" "$f2"

    local trace="$SANDBOX/trace"
    : > "$trace"

    # Stub the batch helper to fail, and stub roomy_delete to record per-file
    # invocations and act on the file. This proves the fallback path runs once
    # per file rather than silently dropping the batch.
    run bash --noprofile --norc <<EOF
$(prelude)
_roomy_move_to_trash_batch() { return 1; }
roomy_delete() {
    printf 'roomy_delete %s\n' "\$1" >> "$trace"
    rm -f "\$1"
    return 0
}
remove_file_list "$list" "false"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"2"* ]]

    [[ ! -e "$f1" ]]
    [[ ! -e "$f2" ]]

    local fallback_calls
    fallback_calls=$(wc -l < "$trace" | tr -d ' ')
    [ "$fallback_calls" -eq 2 ]
    grep -qF "roomy_delete $f1" "$trace"
    grep -qF "roomy_delete $f2" "$trace"
}

@test "remove_file_list routes broken symlinks through per-file deletion" {
    local link="$SANDBOX/broken-link.plist"
    ln -s "$SANDBOX/missing-target.plist" "$link"
    local list="$link"

    local trace="$SANDBOX/trace"
    : > "$trace"

    run bash --noprofile --norc <<EOF
$(prelude)
_roomy_move_to_trash_batch() {
    echo "unexpected batch call" >&2
    return 1
}
roomy_delete() {
    printf 'roomy_delete %s %s\n' "\$1" "\$2" >> "$trace"
    rm "\$1"
    return 0
}
remove_file_list "$list" "false"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"1"* ]]
    [[ ! -e "$link" && ! -L "$link" ]]
    grep -qF "roomy_delete $link false" "$trace"
}

@test "_roomy_move_to_trash_batch returns 1 when trash CLI is missing under ROOMY_TEST_NO_AUTH" {
    local f1="$SANDBOX/p.plist"
    : > "$f1"

    # Drop ROOMY_TEST_TRASH_DIR so we exercise the real helper path; the
    # ROOMY_TEST_NO_AUTH guard must fail closed before any AppleScript runs.
    run bash --noprofile --norc <<EOF
set -euo pipefail
export ROOMY_TEST_NO_AUTH=1
unset ROOMY_TEST_TRASH_DIR
source "$PROJECT_ROOT/lib/core/common.sh"
_roomy_move_to_trash_batch "$f1"
EOF

    [ "$status" -ne 0 ]
    [[ -e "$f1" ]]
}

@test "remove_file_list with sudo paths bypasses batching and routes per-file" {
    local f1="$SANDBOX/sudo_a.plist"
    local f2="$SANDBOX/sudo_b.plist"
    : > "$f1"
    : > "$f2"
    local list
    printf -v list '%s\n%s' "$f1" "$f2"

    local batch_count="$SANDBOX/batch_count"
    local fallback_count="$SANDBOX/fallback_count"
    : > "$batch_count"
    : > "$fallback_count"

    run bash --noprofile --norc <<EOF
$(prelude)
_roomy_move_to_trash_batch() {
    printf '1\n' >> "$batch_count"
    return 0
}
roomy_delete() {
    printf '%s\n' "\$1" >> "$fallback_count"
    rm -f "\$1"
    return 0
}
remove_file_list "$list" "true"
EOF

    [ "$status" -eq 0 ]

    # Sudo path must avoid the batch helper entirely.
    [[ ! -s "$batch_count" ]]

    local n
    n=$(wc -l < "$fallback_count" | tr -d ' ')
    [ "$n" -eq 2 ]
}
