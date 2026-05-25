#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-history-home.XXXXXX")"
    export HOME
}

teardown_file() {
    if [[ "$HOME" == "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        rm -rf "$HOME"
    fi
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
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
    [[ "$output" == *"Mole History"* ]]
    [[ "$output" == *"purge"* ]]
    [[ "$output" == *"1 items, 10KB"* ]]
    [[ "$output" == *"clean"* ]]
    [[ "$output" == *"removed 1, trashed 1, skipped 1, failed 1"* ]]
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
    [[ "$output" == *"purge"* ]]
    [[ "$output" != *"clean      2026-05-24 10:00:00"* ]]
    [[ "$output" == *"/tmp/build"* ]]
    [[ "$output" != *"/tmp/Old App.app"* ]]
}

@test "mo history --limit accepts decimal values with leading zeros" {
    write_history_logs

    run env HOME="$HOME" "$PROJECT_ROOT/mole" history --limit 0001
    [ "$status" -eq 0 ]
    [[ "$output" == *"purge"* ]]
    [[ "$output" != *"clean      2026-05-24 10:00:00"* ]]
    [[ "$output" != *"value too great for base"* ]]
}

@test "mo history handles empty logs" {
    : > "$HOME/Library/Logs/mole/operations.log"

    run env HOME="$HOME" "$PROJECT_ROOT/mole" history
    [ "$status" -eq 0 ]
    [[ "$output" == *"No operation history yet"* ]]
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
    [[ "$output" == *"clean      2026-05-24 10:00:00, 0 items, 0B"* ]]
    [[ "$output" == *"removed 1, ended malformed summary"* ]]
    [[ "$output" != *"malformed summary items"* ]]
}

@test "mo history does not create logs when none exist" {
    rm -rf "$HOME/Library"

    run env HOME="$HOME" "$PROJECT_ROOT/mole" history
    [ "$status" -eq 0 ]
    [[ "$output" == *"No operation history yet"* ]]
    [ ! -e "$HOME/Library/Logs/mole/operations.log" ]
    [ ! -e "$HOME/Library/Logs/mole/mole.log" ]
}

@test "mo history early dispatch respects source guard" {
    # shellcheck disable=SC2016
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc -c '
set -euo pipefail
set -- history
MOLE_TEST_MODE=1
MOLE_SKIP_MAIN=1
source "$PROJECT_ROOT/mole"
echo sourced
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"sourced"* ]]
    [[ "$output" != *"Mole History"* ]]
}

@test "mo history early dispatch keeps global debug flag behavior" {
    run env HOME="$HOME" "$PROJECT_ROOT/mole" --debug history --limit 0001
    [ "$status" -eq 0 ]
    [[ "$output" == *"Mole History"* ]]
    [[ "$output" != *"Unknown option"* ]]

    run env HOME="$HOME" "$PROJECT_ROOT/mole" history --debug --limit 0001
    [ "$status" -eq 0 ]
    [[ "$output" == *"Mole History"* ]]
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
    [[ "$output" == *"Invalid value for --limit"* ]]

    run env HOME="$HOME" "$PROJECT_ROOT/mole" history --limit 500
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid value for --limit"* ]]

    run env HOME="$HOME" "$PROJECT_ROOT/mole" history --limit 999999999999999999999999
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid value for --limit"* ]]
    [[ "$output" != *"value too great for base"* ]]
}
