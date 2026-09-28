#!/usr/bin/env bats

load helpers/common

setup_file() {
    mole_test_setup_home history-home
}

teardown_file() {
    mole_test_teardown_home
}

setup() {
    if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
        return 1
    fi
    rm -rf "$HOME/Library"
    mkdir -p "$HOME/Library/Logs/mole"
}

write_history_logs() {
    cat > "$HOME/Library/Logs/mole/operations.log" <<'EOF'
# ========== clean session started at 2026-05-24 10:00:00 ==========
[2026-05-24 10:00:01] [clean] REMOVED /tmp/cache one (2KB)
[2026-05-24 10:00:02] [clean] TRASHED /tmp/Old App.app (4KB)
[2026-05-24 10:00:03] [clean] SKIPPED /tmp/protected (whitelist)
[2026-05-24 10:00:04] [clean] FAILED /tmp/fail (permission denied)
# ========== clean session ended at 2026-05-24 10:00:05, 2 items, 6KB ==========
# ========== purge session started at 2026-05-24 11:00:00 ==========
[2026-05-24 11:00:01] [purge] REMOVED /tmp/build (10KB)
# ========== purge session ended at 2026-05-24 11:00:02, 1 items, 10KB ==========
EOF

    printf '2026-05-24T10:00:02+0000\ttrash\t4\tok\t/tmp/Old App.app\n' > "$HOME/Library/Logs/mole/deletions.log"
    printf '2026-05-24T11:00:01+0000\tpermanent\t10\tdry-run\t/tmp/build\n' >> "$HOME/Library/Logs/mole/deletions.log"
}

@test "mo history summarizes operation sessions and deletion audit" {
    write_history_logs

    run env HOME="$HOME" "$PROJECT_ROOT/mole" history
    [ "$status" -eq 0 ]
    [[ "$output" == *"Mole History"* ]] || return 1
    [[ "$output" == *"purge"* ]] || return 1
    [[ "$output" == *"1 items, 10KB"* ]] || return 1
    [[ "$output" == *"clean"* ]] || return 1
    [[ "$output" == *"removed 1, trashed 1, skipped 1, failed 1"* ]] || return 1
    [[ "$output" == *"/tmp/Old App.app"* ]]
}

@test "mo history --json returns stable parseable fields" {
    write_history_logs

    run env HOME="$HOME" "$PROJECT_ROOT/mole" history --json
    [ "$status" -eq 0 ]

    printf '%s\n' "$output" | python3 -c '
import json
import sys

data = json.load(sys.stdin)
assert data["limit"] == 20
assert data["sessions"][0]["command"] == "purge"
assert data["sessions"][1]["command"] == "clean"
assert data["sessions"][1]["actions"]["trashed"] == 1
assert data["sessions"][1]["actions"]["failed"] == 1
assert data["deletions"][0]["mode"] == "permanent"
assert data["deletions"][0]["size_kb"] == 10
assert data["deletions"][1]["path"] == "/tmp/Old App.app"
'
}

@test "mo history preserves failed optimize task counts" {
    cat > "$HOME/Library/Logs/mole/operations.log" <<'EOF'
# ========== optimize session started at 2026-05-24 12:00:00 ==========
[2026-05-24 12:00:01] [optimize] TASK_FAILED disk_verify (task outcome)
[2026-05-24 12:00:02] [optimize] TASK_FAILED periodic_maintenance (task outcome)
# ========== optimize session ended at 2026-05-24 12:00:05, 3 items, 0B ==========
EOF

    run env HOME="$HOME" "$PROJECT_ROOT/mole" history
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    [[ "$output" == *"2 optimize tasks failed"* ]] || return 1

    run env HOME="$HOME" "$PROJECT_ROOT/mole" history --json
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    printf '%s\n' "$output" | python3 -c '
import json
import sys

data = json.load(sys.stdin)
assert data["sessions"][0]["command"] == "optimize"
assert data["sessions"][0]["items"] == 3
assert data["sessions"][0]["failed_tasks"] == 2
'
}

@test "operation logging writes the canonical failed task action" {
    local log_file="$HOME/Library/Logs/mole/task-outcome.log"
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" OPERATIONS_LOG_FILE="$log_file" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
log_operation optimize TASK_FAILED disk_verify "task outcome"
cat "$OPERATIONS_LOG_FILE"
EOF

    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    [[ "$output" == *"[optimize] TASK_FAILED disk_verify (task outcome)"* ]] || return 1
}

@test "mo history --json escapes unusual path characters" {
    : > "$HOME/Library/Logs/mole/operations.log"
    weird_path=$'/tmp/unicode-\xe9\x9b\xaa-quote"slash\\tab\tbackspace\bformfeed\fend'
    printf '2026-05-24T10:00:02+0000\ttrash\t4\tok\t%s\n' "$weird_path" > "$HOME/Library/Logs/mole/deletions.log"

    run env HOME="$HOME" "$PROJECT_ROOT/mole" history --json
    [ "$status" -eq 0 ]

    printf '%s\n' "$output" | python3 -c '
import json
import sys

data = json.load(sys.stdin)
assert data["deletions"][0]["path"] == "/tmp/unicode-\u96ea-quote\"slash\\tab\tbackspace\bformfeed\fend"
'
}

@test "mo history --limit caps sessions and deletion entries" {
    write_history_logs

    run env HOME="$HOME" "$PROJECT_ROOT/mole" history --limit 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"purge"* ]] || return 1
    [[ "$output" != *"clean      2026-05-24 10:00:00"* ]] || return 1
    [[ "$output" == *"/tmp/build"* ]] || return 1
    [[ "$output" != *"/tmp/Old App.app"* ]]
}

@test "mo history --limit accepts decimal values with leading zeros" {
    write_history_logs

    run env HOME="$HOME" "$PROJECT_ROOT/mole" history --limit 0001
    [ "$status" -eq 0 ]
    [[ "$output" == *"purge"* ]] || return 1
    [[ "$output" != *"clean      2026-05-24 10:00:00"* ]] || return 1
    [[ "$output" != *"value too great for base"* ]]
}

@test "mo history handles empty logs" {
    : > "$HOME/Library/Logs/mole/operations.log"

    run env HOME="$HOME" "$PROJECT_ROOT/mole" history
    [ "$status" -eq 0 ]
    [[ "$output" == *"No operation history yet"* ]] || return 1
    [[ "$output" == *"No deletion audit entries yet"* ]]
}

@test "mo history tolerates malformed session summaries" {
    cat > "$HOME/Library/Logs/mole/operations.log" <<'EOF'
# ========== clean session started at 2026-05-24 10:00:00 ==========
[2026-05-24 10:00:01] [clean] REMOVED /tmp/cache (2KB)
# ========== clean session ended at malformed summary ==========
EOF

    run env HOME="$HOME" "$PROJECT_ROOT/mole" history
    [ "$status" -eq 0 ]
    [[ "$output" == *"clean      2026-05-24 10:00:00, 0 items, 0B"* ]] || return 1
    [[ "$output" == *"removed 1, ended malformed summary"* ]] || return 1
    [[ "$output" != *"malformed summary items"* ]]
}

@test "mo history attributes interleaved sessions of different commands by command" {
    # A dry-run purge started while a real clean was still running.
    cat > "$HOME/Library/Logs/mole/operations.log" <<'EOF'
# ========== clean session started at 2026-05-24 10:00:00 ==========
[2026-05-24 10:00:01] [clean] REMOVED /tmp/one (1KB)
# ========== purge session started at 2026-05-24 10:01:00 ==========
[2026-05-24 10:01:01] [clean] REMOVED /tmp/two (1KB)
[2026-05-24 10:01:02] [clean] REMOVED /tmp/three (1KB)
# ========== purge session ended at 2026-05-24 10:02:00, 4 items, 8KB ==========
[2026-05-24 10:03:00] [clean] REMOVED /tmp/four (1KB)
# ========== clean session ended at 2026-05-24 10:04:00, 4 items, 4KB ==========
# ========== uninstall session started at 2026-05-24 11:00:00 ==========
[2026-05-24 11:00:01] [uninstall] TRASHED /tmp/Old.app (1KB)
EOF

    run env HOME="$HOME" "$PROJECT_ROOT/mole" history --json
    [ "$status" -eq 0 ] || return 1

    printf '%s\n' "$output" | python3 -c '
import json
import sys

sessions = json.load(sys.stdin)["sessions"]
assert [s["command"] for s in sessions] == ["uninstall", "purge", "clean"], sessions
uninstall, purge, clean = sessions
assert purge["actions"]["removed"] == 0, purge
assert clean["actions"]["removed"] == 4, clean
assert uninstall["actions"]["trashed"] == 1, uninstall
'
}

@test "mo history orders sessions started in the same second by their markers" {
    cat > "$HOME/Library/Logs/mole/operations.log" <<'EOF'
# ========== clean session started at 2026-05-24 10:00:00 ==========
# ========== purge session started at 2026-05-24 10:00:00 ==========
[2026-05-24 10:00:01] [purge] REMOVED /tmp/build (1KB)
# ========== purge session ended at 2026-05-24 10:00:02, 1 items, 1KB ==========
[2026-05-24 10:00:03] [clean] REMOVED /tmp/cache (1KB)
# ========== clean session ended at 2026-05-24 10:00:04, 1 items, 1KB ==========
EOF

    run env HOME="$HOME" "$PROJECT_ROOT/mole" history --json
    [ "$status" -eq 0 ] || return 1

    printf '%s\n' "$output" | python3 -c '
import json
import sys

sessions = json.load(sys.stdin)["sessions"]
assert [s["command"] for s in sessions] == ["purge", "clean"], sessions
assert sessions[0]["actions"]["removed"] == 1, sessions[0]
assert sessions[1]["actions"]["removed"] == 1, sessions[1]
'
}

@test "mo history still ends marker-less installer runs at the next session marker" {
    # mo installer logs operation lines but writes no session markers.
    cat > "$HOME/Library/Logs/mole/operations.log" <<'EOF'
[2026-05-02 10:00:01] [installer] TRASHED /tmp/first.dmg (1KB)
# ========== clean session started at 2026-05-05 10:00:00 ==========
[2026-05-05 10:00:01] [clean] REMOVED /tmp/cache (1KB)
# ========== clean session ended at 2026-05-05 10:01:00, 1 items, 1KB ==========
[2026-05-10 10:00:01] [installer] TRASHED /tmp/second.dmg (1KB)
EOF

    run env HOME="$HOME" "$PROJECT_ROOT/mole" history --json
    [ "$status" -eq 0 ] || return 1

    printf '%s\n' "$output" | python3 -c '
import json
import sys

sessions = json.load(sys.stdin)["sessions"]
assert [s["command"] for s in sessions] == ["installer", "clean", "installer"], sessions
assert sessions[0]["started_at"] == "2026-05-10 10:00:01", sessions[0]
assert sessions[0]["actions"]["trashed"] == 1, sessions[0]
assert sessions[2]["actions"]["trashed"] == 1, sessions[2]
'
}

@test "mo history does not create logs when none exist" {
    rm -rf "$HOME/Library"

    run env HOME="$HOME" "$PROJECT_ROOT/mole" history
    [ "$status" -eq 0 ]
    [[ "$output" == *"No operation history yet"* ]] || return 1
    [ ! -e "$HOME/Library/Logs/mole/operations.log" ]
    [ ! -e "$HOME/Library/Logs/mole/mole.log" ]
}

@test "mo history early dispatch respects source guard" {
    # shellcheck disable=SC2016
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc -c '
set -euo pipefail
set -- history
MOLE_TEST_MODE=1
MOLE_SKIP_MAIN=1
source "$PROJECT_ROOT/mole"
echo sourced
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"sourced"* ]] || return 1
    [[ "$output" != *"Mole History"* ]]
}

@test "mo history early dispatch keeps global debug flag behavior" {
    run env HOME="$HOME" "$PROJECT_ROOT/mole" --debug history --limit 0001
    [ "$status" -eq 0 ]
    [[ "$output" == *"Mole History"* ]] || return 1
    [[ "$output" != *"Unknown option"* ]] || return 1

    run env HOME="$HOME" "$PROJECT_ROOT/mole" history --debug --limit 0001
    [ "$status" -eq 0 ]
    [[ "$output" == *"Mole History"* ]] || return 1
    [[ "$output" != *"Unknown option"* ]]
}

@test "mo history rejects unknown options" {
    run env HOME="$HOME" "$PROJECT_ROOT/mole" history --bad-option
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown option for mo history"* ]]
}

@test "mo history rejects invalid limit values" {
    run env HOME="$HOME" "$PROJECT_ROOT/mole" history --limit nope
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid value for --limit"* ]] || return 1

    run env HOME="$HOME" "$PROJECT_ROOT/mole" history --limit 500
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid value for --limit"* ]] || return 1

    run env HOME="$HOME" "$PROJECT_ROOT/mole" history --limit 999999999999999999999999
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid value for --limit"* ]] || return 1
    [[ "$output" != *"value too great for base"* ]]
}
