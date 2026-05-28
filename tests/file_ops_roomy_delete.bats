#!/usr/bin/env bats

# Tests for roomy_delete in lib/core/file_ops.sh.
# Exercises permanent mode (default), trash mode (via ROOMY_TEST_TRASH_DIR
# so Finder is never invoked), dry-run, and the deletions log.

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT
}

setup() {
    SANDBOX="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-roomy-delete.XXXXXX")"
    export SANDBOX
    export ROOMY_DELETE_LOG="$SANDBOX/deletions.log"
    export ROOMY_TEST_TRASH_DIR="$SANDBOX/Trash"
    export ROOMY_TEST_NO_AUTH=1
    unset ROOMY_DELETE_MODE
    unset ROOMY_DRY_RUN
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
source "$PROJECT_ROOT/lib/core/common.sh"
EOF
}

@test "roomy_delete defaults to permanent mode and removes the target" {
    local victim="$SANDBOX/victim"
    mkdir -p "$victim"
    : > "$victim/keep.txt"

    run bash --noprofile --norc <<EOF
$(prelude)
roomy_delete "$victim"
EOF

    [ "$status" -eq 0 ]
    [[ ! -e "$victim" ]]
    # Trash dir must remain empty in permanent mode.
    [[ -z "$(ls -A "$ROOMY_TEST_TRASH_DIR" 2> /dev/null || true)" ]]
}

@test "roomy_delete trash mode moves the target instead of rm -rf" {
    local victim="$SANDBOX/victim_trash"
    mkdir -p "$victim"
    printf 'payload' > "$victim/data.txt"

    run bash --noprofile --norc <<EOF
$(prelude)
export ROOMY_DELETE_MODE=trash
roomy_delete "$victim"
EOF

    [ "$status" -eq 0 ]
    [[ ! -e "$victim" ]]
    # Something landed in the stub trash dir.
    [[ -n "$(ls -A "$ROOMY_TEST_TRASH_DIR" 2> /dev/null || true)" ]]
}

@test "safe_remove honors trash mode for clean-safe deletion" {
    local victim="$SANDBOX/safe_remove_trash"
    mkdir -p "$victim"
    printf 'payload' > "$victim/data.txt"

    run bash --noprofile --norc <<EOF
$(prelude)
export ROOMY_DELETE_MODE=trash
safe_remove "$victim" true
EOF

    [ "$status" -eq 0 ]
    [[ ! -e "$victim" ]]
    [[ -n "$(ls -A "$ROOMY_TEST_TRASH_DIR" 2> /dev/null || true)" ]]

    local status_col
    status_col=$(awk -F'\t' 'END { print $4 }' "$ROOMY_DELETE_LOG")
    [ "$status_col" = "ok" ]
}

@test "safe_remove strict trash mode skips permanent fallback" {
    local victim="$SANDBOX/safe_remove_strict_trash"
    mkdir -p "$victim"
    printf 'payload' > "$victim/data.txt"

    run bash --noprofile --norc <<EOF
$(prelude)
export ROOMY_DELETE_MODE=trash
export ROOMY_TRASH_STRICT=1
export ROOMY_TRASH_NO_APPLESCRIPT=1
export ROOMY_TEST_TRASH_DIR="/dev/null/not-a-trash-dir"
safe_remove "$victim" true
EOF

    [ "$status" -ne 0 ]
    [[ -e "$victim/data.txt" ]]

    local status_col
    status_col=$(awk -F'\t' 'END { print $4 }' "$ROOMY_DELETE_LOG")
    [ "$status_col" = "trash-unavailable" ]
}

@test "roomy_delete moves sudo-required paths to invoking user Trash" {
    local victim="$SANDBOX/victim_sudo_trash"
    local fake_bin="$SANDBOX/bin"
    local fake_home="$SANDBOX/home"
    local trace="$SANDBOX/trace.log"

    mkdir -p "$fake_bin" "$fake_home"
    mkdir -p "$victim"
    printf 'payload' > "$victim/data.txt"

    cat > "$fake_bin/trash" <<'SH'
#!/bin/bash
printf 'trash %s\n' "$*" >> "$ROOMY_TEST_TRACE"
exit 99
SH
    cat > "$fake_bin/sudo" <<'SH'
#!/bin/bash
printf 'sudo %s\n' "$*" >> "$ROOMY_TEST_TRACE"
"$@"
SH
    cat > "$fake_bin/osascript" <<'SH'
#!/bin/bash
printf 'osascript %s\n' "$*" >> "$ROOMY_TEST_TRACE"
exit 98
SH
    chmod +x "$fake_bin/trash" "$fake_bin/sudo" "$fake_bin/osascript"

    run bash --noprofile --norc <<EOF
$(prelude)
unset ROOMY_TEST_TRASH_DIR
unset ROOMY_TEST_NO_AUTH
export ROOMY_DELETE_MODE=trash
export PATH="$fake_bin:\$PATH"
export HOME="$fake_home"
export ROOMY_TEST_TRACE="$trace"
roomy_delete "$victim" true
EOF

    [ "$status" -eq 0 ]
    [[ ! -e "$victim" ]]
    [[ -d "$fake_home/.Trash/$(basename "$victim")" ]]
    [[ "$(grep -c '^sudo mv ' "$trace" 2> /dev/null || true)" -eq 1 ]]
    [[ "$(grep -c '^sudo trash ' "$trace" 2> /dev/null || true)" -eq 0 ]]
    [[ "$(grep -c '^trash ' "$trace" 2> /dev/null || true)" -eq 0 ]]
    [[ "$(grep -c '^osascript ' "$trace" 2> /dev/null || true)" -eq 0 ]]

    local status_col
    status_col=$(awk -F'\t' 'END { print $4 }' "$ROOMY_DELETE_LOG")
    [ "$status_col" = "ok" ]
}

@test "roomy_delete refuses symlinked invoking user Trash for sudo-required paths" {
    local victim="$SANDBOX/victim_sudo_symlink_trash"
    local fake_bin="$SANDBOX/bin"
    local fake_home="$SANDBOX/home"
    local redirected="$SANDBOX/redirected"
    local trace="$SANDBOX/trace.log"

    mkdir -p "$fake_bin" "$fake_home" "$redirected" "$victim"
    printf 'payload' > "$victim/data.txt"
    ln -s "$redirected" "$fake_home/.Trash"

    cat > "$fake_bin/sudo" <<'SH'
#!/bin/bash
printf 'sudo %s\n' "$*" >> "$ROOMY_TEST_TRACE"
"$@"
SH
    chmod +x "$fake_bin/sudo"

    run bash --noprofile --norc <<EOF
$(prelude)
unset ROOMY_TEST_TRASH_DIR
unset ROOMY_TEST_NO_AUTH
export ROOMY_DELETE_MODE=trash
export PATH="$fake_bin:\$PATH"
export HOME="$fake_home"
export ROOMY_TEST_TRACE="$trace"
roomy_delete "$victim" true
EOF

    [ "$status" -eq 0 ]
    [[ ! -e "$victim" ]]
    [[ -z "$(ls -A "$redirected" 2> /dev/null || true)" ]]
    [[ "$(grep -c '^sudo mv ' "$trace" 2> /dev/null || true)" -eq 0 ]]

    local status_col
    status_col=$(awk -F'\t' 'END { print $4 }' "$ROOMY_DELETE_LOG")
    [ "$status_col" = "trash-fallback-rm" ]
}

@test "roomy_delete uses unique Trash name for sudo-required path conflicts" {
    local victim="$SANDBOX/conflict_app"
    local fake_bin="$SANDBOX/bin"
    local fake_home="$SANDBOX/home"
    local trace="$SANDBOX/trace.log"

    mkdir -p "$fake_bin" "$fake_home/.Trash" "$victim"
    printf 'payload' > "$victim/data.txt"
    mkdir -p "$fake_home/.Trash/$(basename "$victim")"

    cat > "$fake_bin/sudo" <<'SH'
#!/bin/bash
printf 'sudo %s\n' "$*" >> "$ROOMY_TEST_TRACE"
"$@"
SH
    chmod +x "$fake_bin/sudo"

    run bash --noprofile --norc <<EOF
$(prelude)
unset ROOMY_TEST_TRASH_DIR
unset ROOMY_TEST_NO_AUTH
export ROOMY_DELETE_MODE=trash
export PATH="$fake_bin:\$PATH"
export HOME="$fake_home"
export ROOMY_TEST_TRACE="$trace"
roomy_delete "$victim" true
EOF

    [ "$status" -eq 0 ]
    [[ ! -e "$victim" ]]
    [[ -d "$fake_home/.Trash/$(basename "$victim")" ]]
    [[ -n "$(find "$fake_home/.Trash" -mindepth 1 -maxdepth 1 -name "$(basename "$victim").*" -print -quit)" ]]
    [[ "$(grep -c '^sudo mv -n ' "$trace" 2> /dev/null || true)" -eq 1 ]]

    local status_col
    status_col=$(awk -F'\t' 'END { print $4 }' "$ROOMY_DELETE_LOG")
    [ "$status_col" = "ok" ]
}

@test "roomy_delete writes a tab-separated log line per call" {
    local victim="$SANDBOX/logged"
    : > "$victim"

    run bash --noprofile --norc <<EOF
$(prelude)
roomy_delete "$victim"
EOF

    [ "$status" -eq 0 ]
    [[ -s "$ROOMY_DELETE_LOG" ]]

    # Expect 5 tab-separated fields: timestamp, mode, size_kb, status, path.
    local fields
    fields=$(awk -F'\t' 'END { print NF }' "$ROOMY_DELETE_LOG")
    [ "$fields" -eq 5 ]

    # Status column must be "ok" for a successful permanent delete.
    local status_col
    status_col=$(awk -F'\t' 'END { print $4 }' "$ROOMY_DELETE_LOG")
    [ "$status_col" = "ok" ]
}

@test "roomy_delete dry-run does not touch the filesystem but still logs" {
    local victim="$SANDBOX/dry"
    : > "$victim"

    run bash --noprofile --norc <<EOF
$(prelude)
export ROOMY_DRY_RUN=1
roomy_delete "$victim"
EOF

    [ "$status" -eq 0 ]
    [[ -e "$victim" ]]

    local status_col
    status_col=$(awk -F'\t' 'END { print $4 }' "$ROOMY_DELETE_LOG")
    [ "$status_col" = "dry-run" ]
}

@test "roomy_delete records a forensic log entry for rejected paths" {
    run bash --noprofile --norc <<EOF
$(prelude)
roomy_delete "/tmp/../etc/hosts"
EOF

    [ "$status" -ne 0 ]
    # Rejection IS logged (security-relevant), with status="rejected" and size=0.
    # Audit trails need to distinguish refused-by-policy from never-attempted.
    [[ -s "$ROOMY_DELETE_LOG" ]]
    local status_col size_col
    status_col=$(awk -F'\t' 'END { print $4 }' "$ROOMY_DELETE_LOG")
    size_col=$(awk -F'\t' 'END { print $3 }' "$ROOMY_DELETE_LOG")
    [ "$status_col" = "rejected" ]
    [ "$size_col" = "0" ]
}

@test "roomy_delete refuses symlinks that point at protected system paths" {
    local link_path="$SANDBOX/system-link"
    ln -s "/System" "$link_path"

    run bash --noprofile --norc <<EOF
$(prelude)
export ROOMY_DELETE_MODE=trash
roomy_delete "$link_path"
EOF

    [ "$status" -ne 0 ]
    [[ -L "$link_path" ]]
    [[ "$(readlink "$link_path")" = "/System" ]]

    local status_col size_col
    status_col=$(awk -F'\t' 'END { print $4 }' "$ROOMY_DELETE_LOG")
    size_col=$(awk -F'\t' 'END { print $3 }' "$ROOMY_DELETE_LOG")
    [ "$status_col" = "rejected" ]
    [ "$size_col" = "0" ]
}

@test "roomy_delete is a no-op on a non-existent path" {
    run bash --noprofile --norc <<EOF
$(prelude)
roomy_delete "$SANDBOX/does-not-exist"
EOF

    [ "$status" -eq 0 ]
    [[ ! -s "$ROOMY_DELETE_LOG" ]]
}

@test "roomy_delete trash failure falls back to permanent rm" {
    local victim="$SANDBOX/fallback_target"
    : > "$victim"

    # Pointing ROOMY_TEST_TRASH_DIR at a non-writable parent forces the stub
    # trash move to fail, exercising the fallback path.
    local blocked="$SANDBOX/blocked/Trash"
    mkdir -p "$(dirname "$blocked")"
    chmod 0555 "$(dirname "$blocked")"

    run bash --noprofile --norc <<EOF
$(prelude)
export ROOMY_DELETE_MODE=trash
export ROOMY_TEST_TRASH_DIR="$blocked"
roomy_delete "$victim"
EOF

    chmod 0755 "$(dirname "$blocked")"

    [ "$status" -eq 0 ]
    [[ ! -e "$victim" ]]

    local status_col
    status_col=$(awk -F'\t' 'END { print $4 }' "$ROOMY_DELETE_LOG")
    [ "$status_col" = "trash-fallback-rm" ]
    # User explicitly asked NOT to permanent-delete; fallback must surface.
    [[ "$output" == *"Trash unavailable"* ]]
}

@test "roomy_delete records 'unknown' (not 0) when size measurement fails" {
    # Override get_path_size_kb to simulate a measurement failure (non-numeric
    # output, non-zero exit). The actual delete still goes through safe_remove
    # so the file is removed; only the log size column should differ.
    local victim="$SANDBOX/measureless"
    : > "$victim"

    run bash --noprofile --norc <<EOF
$(prelude)
get_path_size_kb() { echo "ERR"; return 1; }
roomy_delete "$victim"
EOF

    [ "$status" -eq 0 ]
    [[ ! -e "$victim" ]]
    local size_col
    size_col=$(awk -F'\t' 'END { print $3 }' "$ROOMY_DELETE_LOG")
    [ "$size_col" = "unknown" ]
}

@test "roomy_delete warns once per session when audit log is unwritable" {
    local victim="$SANDBOX/log_blocked"
    : > "$victim"
    local broken_log_dir="$SANDBOX/no_write/logs"
    mkdir -p "$(dirname "$broken_log_dir")"
    chmod 0555 "$(dirname "$broken_log_dir")"

    run bash --noprofile --norc <<EOF
set -euo pipefail
export ROOMY_DELETE_LOG="$broken_log_dir/deletions.log"
export ROOMY_TEST_TRASH_DIR="$ROOMY_TEST_TRASH_DIR"
export ROOMY_TEST_NO_AUTH=1
source "$PROJECT_ROOT/lib/core/common.sh"
roomy_delete "$victim"
# Second call in the same shell must NOT print again.
: > "$SANDBOX/second_victim"
roomy_delete "$SANDBOX/second_victim"
EOF

    chmod 0755 "$(dirname "$broken_log_dir")"

    [ "$status" -eq 0 ]
    # Warning visible exactly once.
    local warn_count
    warn_count=$(printf '%s\n' "$output" | grep -c "deletions audit log unavailable" || true)
    [ "$warn_count" = "1" ]
}
