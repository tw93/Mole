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

@test "operation log writers keep control characters inside one audit record" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
log_operation_session_start clean
log_operation clean SKIPPED $'/tmp/example\n[2026-10-07 12:00:00] [clean] REMOVED /tmp/not-removed' $'reason\r\033[2J\tend'
operation_log_command command clean
append_log_lines "$OPERATIONS_LOG_FILE" "[2026-10-07 12:00:00] [$command] REMOVED "$'/tmp/batch\n[2026-10-07 12:00:00] [clean] FAILED /tmp/forged'" (batch)"
log_operation_session_end clean 1 0
"$PROJECT_ROOT/mole" history --json
EOF
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | python3 -c '
import json,sys
s, = json.load(sys.stdin)["sessions"]
assert s["operation_count"] == 2, s
assert s["actions"]["removed"] == 1 and s["actions"]["skipped"] == 1, s
assert s["actions"]["failed"] == 0, s
'
    run python3 -c 'import pathlib,sys; b=pathlib.Path(sys.argv[1]).read_bytes(); assert b"\\n[2026" in b; assert not any(c < 32 and c != 10 or c == 127 for c in b)' "$HOME/Library/Logs/mole/operations.log"
    [ "$status" -eq 0 ]
}

@test "audit logs keep backslash names verbatim while control bytes stay escaped" {
    local log_dir="$HOME/Library/Logs/mole"
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 MOLE_DELETE_LOG="$log_dir/deletions.log" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
mkdir -p "$HOME/work"
for name in 'back\slash.txt' 'lit\n-backslash-n.txt' 'tail\'; do
    : > "$HOME/work/$name"
    mole_delete "$HOME/work/$name" || exit 1
    [[ ! -e "$HOME/work/$name" ]] || exit 1
done
kept="$HOME/work/ctl"$'\t'"x"
: > "$kept"
if mole_delete "$kept"; then exit 1; fi
[[ -f "$kept" ]] || exit 1
log_operation_session_start clean
log_operation clean SKIPPED 'lit\name' 'back\slash'
log_operation clean SKIPPED $'real\nname' $'tab\there'
log_operation_session_end clean 2 0
EOF
    [ "$status" -eq 0 ]

    # A literal backslash survives into the record; a real newline stays one record.
    run python3 -c '
import pathlib, sys
b = pathlib.Path(sys.argv[1]).read_bytes()
assert b"SKIPPED lit\\name (back\\slash)\n" in b, b
assert b"SKIPPED real\\nname (tab\\there)\n" in b, b
lines = [l for l in b.split(b"\n") if l]
assert len(lines) == 7, lines
assert all(l.startswith((b"[", b"# ==========")) for l in lines), lines
assert not any(c < 32 and c != 10 or c == 127 for c in b), b
' "$log_dir/operations.log"
    [ "$status" -eq 0 ]

    run env HOME="$HOME" MOLE_DELETE_LOG="$log_dir/deletions.log" "$PROJECT_ROOT/mole" history --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | WORK_DIR="$HOME/work" python3 -c '
import json, os, sys
work = os.environ["WORK_DIR"]
rows = {d["path"]: d["status"] for d in json.load(sys.stdin)["deletions"]}
for name in ("back\\slash.txt", "lit\\n-backslash-n.txt", "tail\\"):
    assert rows.get(work + "/" + name) == "ok", (name, rows)
assert rows.get(work + "/ctl\\tx") == "rejected", rows
'
}

@test "operation log escaping leaves no control byte for any byte value" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
for ((code = 1; code < 256; code++)); do
    printf -v octal '\\%03o' "$code"
    printf -v ch "$octal"
    append_log_line "$OPERATIONS_LOG_FILE" "${ch}"
    append_log_line "$OPERATIONS_LOG_FILE" "a${ch}b${ch}${ch}c"
    append_log_lines "$OPERATIONS_LOG_FILE" "x${ch}y" "${ch}"
done
EOF
    [ "$status" -eq 0 ]
    run python3 -c '
import pathlib, sys
b = pathlib.Path(sys.argv[1]).read_bytes()
assert b.count(b"\n") == 255 * 4, b.count(b"\n")
assert not any(c < 32 and c != 10 or c == 127 for c in b)
assert b"a\\x1bb\\x1b\\x1bc\n" in b and b"a\\nb\\n\\nc\n" in b and b"a\\tb\\t\\tc\n" in b
assert b"\n\\x7f\n" in b and b"\n\\x01\n" in b
assert b"\n\\\n" in b and b"a\\b\\\\c\n" in b, "backslash must stay literal"
' "$HOME/Library/Logs/mole/operations.log"
    [ "$status" -eq 0 ]
}

@test "mo history text prints legacy control bytes escaped and keeps JSON content" {
    local esc=$'\033'
    {
        printf '# ========== clean session started at 2026-05-24 10:00:00 ==========\n'
        printf '[2026-05-24 10:00:01] [clean] REMOVED /tmp/cache one (2KB)\n'
        printf '# ========== clean session ended at 2026-05-24 10:00:05, 1 items, %s[2J6KB ==========\n' "$esc"
        printf '[2026-05-24 10:01:00] [cl%s[31mean] REMOVED /tmp/other (1KB)\n' "$esc"
    } > "$HOME/Library/Logs/mole/operations.log"
    {
        printf '2026-05-24T10:00:02+0000\ttrash\t4\tok\t/tmp/Old App.app\n'
        printf '2026-05-24T10:00:03+0000%s[2J\ttrash\t4\tok\t/tmp/evil%s[31mRED\rend\n' "$esc" "$esc"
        printf '2026-05-24T10:00:04+0000\tperm%s]0;title\a\t4\tok\t/tmp/mode\n' "$esc"
    } > "$HOME/Library/Logs/mole/deletions.log"

    run env HOME="$HOME" "$PROJECT_ROOT/mole" history
    [ "$status" -eq 0 ]
    # Positive controls: the escaped spellings and the clean row are present.
    [[ "$output" == *'/tmp/evil\x1b[31mRED\rend'* ]] || return 1
    [[ "$output" == *'2026-05-24T10:00:03+0000\x1b[2J'* ]] || return 1
    [[ "$output" == *'perm\x1b]0;title\x07'* ]] || return 1
    [[ "$output" == *'1 items, \x1b[2J6KB'* ]] || return 1
    [[ "$output" == *'cl\x1b[31mean'* ]] || return 1
    [[ "$output" == *'/tmp/Old App.app'* ]] || return 1
    # Only the colored heading may carry an escape byte.
    printf '%s\n' "$output" | python3 -c '
import sys
lines = sys.stdin.buffer.read().split(b"\n")
bad = [l for l in lines if b"\x1b" in l and b"Mole History" not in l]
assert not bad, bad
assert not any(b"\r" in l or b"\x07" in l for l in lines), lines
'

    run env HOME="$HOME" "$PROJECT_ROOT/mole" history --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | python3 -c '
import json, sys
data = json.load(sys.stdin)
paths = {d["path"] for d in data["deletions"]}
assert "/tmp/evil\x1b[31mRED\rend" in paths, paths
assert {d["timestamp"] for d in data["deletions"]} >= {"2026-05-24T10:00:03+0000\x1b[2J"}, data["deletions"]
assert any(s["size"] == "\x1b[2J6KB" for s in data["sessions"]), data["sessions"]
'
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
assert all(s["run_id"] == "" for s in data["sessions"])
assert all(s["attribution"] == "command" for s in data["sessions"])
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

@test "operation history keeps overlapping runs and their child-shell actions apart" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" python3 <<'PY'
import json
import os
import select
import subprocess

root = os.environ["PROJECT_ROOT"]
script = r'''
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
get_timestamp() { printf '2026-05-24 10:00:00\n'; }
log_operation_session_start clean
printf 'ready\n'
while IFS= read -r step; do
    case "$step" in
        removed) log_operation clean REMOVED /tmp/first 1KB ;;
        trashed) log_operation clean TRASHED /tmp/second 2KB ;;
        worker)
            /bin/bash --noprofile --norc -c '
                source "$PROJECT_ROOT/lib/core/common.sh"
                log_operation clean SKIPPED /tmp/worker whitelist
            '
            ;;
        end-first) log_operation_session_end clean 1 1; exit ;;
        end-second) log_operation_session_end clean 1 2; exit ;;
    esac
    printf 'ready\n'
done
'''

def ready(writer):
    assert select.select([writer.stdout], [], [], 10)[0], "writer stalled"
    assert writer.stdout.readline() == "ready\n", "writer failed"

def step(writer, action, final=False):
    writer.stdin.write(action + "\n")
    writer.stdin.flush()
    if final:
        assert writer.wait(timeout=10) == 0
    else:
        ready(writer)

writers = []
try:
    for _ in range(2):
        writer = subprocess.Popen(
            ["/bin/bash", "--noprofile", "--norc", "-c", script],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
        )
        writers.append(writer)
        ready(writer)
    first, second = writers
    step(first, "removed")
    step(second, "trashed")
    step(first, "worker")
    step(second, "end-second", final=True)
    step(first, "end-first", final=True)
    result = subprocess.run(
        [root + "/mole", "history", "--json"],
        check=True, capture_output=True, text=True, timeout=10,
    )
    sessions = json.loads(result.stdout)["sessions"]
    assert len(sessions) == 2, sessions
    assert all(s["run_id"] for s in sessions), sessions
    assert all(s["attribution"] == "run" for s in sessions), sessions
    assert sessions[0]["run_id"] != sessions[1]["run_id"], sessions
    first, second = sorted(sessions, key=lambda s: s["size"])
    assert first["actions"]["removed"] == 1, first
    assert first["actions"]["skipped"] == 1, first
    assert first["actions"]["trashed"] == 0, first
    assert second["actions"]["trashed"] == 1, second
    assert second["operation_count"] == 1, second
    assert all(s["ended_at"] for s in sessions), sessions
finally:
    for writer in writers:
        if writer.poll() is None:
            writer.kill()
        writer.wait(timeout=10)
PY
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

@test "mo history marks ambiguous legacy runs without inventing identities or dropping actions" {
    cat > "$HOME/Library/Logs/mole/operations.log" <<'EOF'
# ========== clean session started at 2026-05-24 10:00:00 ==========
[2026-05-24 10:00:01] [clean] REMOVED /tmp/first (1KB)
# ========== clean session started at 2026-05-24 10:01:00 ==========
[2026-05-24 10:01:01] [clean] FAILED /tmp/second (permission denied)
# ========== clean session ended at 2026-05-24 10:02:00, 0 items, 0B ==========
[2026-05-24 10:02:30] [clean] REMOVED /tmp/late-first (1KB)
# ========== clean session ended at 2026-05-24 10:03:00, 1 items, 1KB ==========
EOF
    run env HOME="$HOME" "$PROJECT_ROOT/mole" history --json
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    printf '%s\n' "$output" | python3 -c '
import json, sys
sessions = json.load(sys.stdin)["sessions"]
assert all(s["run_id"] == "" for s in sessions), sessions
assert all(s["attribution"] == "ambiguous" for s in sessions), sessions
assert sum(s["actions"]["removed"] for s in sessions) == 2, sessions
assert sum(s["actions"]["failed"] for s in sessions) == 1, sessions
'
    run env HOME="$HOME" "$PROJECT_ROOT/mole" history
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    [[ "$output" == *"legacy run attribution uncertain"* ]] || return 1
}

@test "ending a session with logging disabled releases its operation ownership" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
log_operation_session_start clean
log_operation clean REMOVED /tmp/inside 1KB
MO_NO_OPLOG=1 log_operation_session_end clean 1 1
log_operation clean SKIPPED /tmp/outside whitelist
EOF
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    run env HOME="$HOME" "$PROJECT_ROOT/mole" history --json
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    printf '%s\n' "$output" | python3 -c '
import json, sys
sessions = json.load(sys.stdin)["sessions"]
assert len(sessions) == 2, sessions
identified, = [s for s in sessions if s["run_id"]]
legacy, = [s for s in sessions if not s["run_id"]]
assert not identified["ended_at"], identified
assert identified["actions"]["removed"] == 1, identified
assert identified["actions"]["skipped"] == 0, identified
assert legacy["actions"]["skipped"] == 1, legacy
assert legacy["operation_count"] == 1, legacy
'
}

@test "new child invocations own a fresh run while interrupted parents keep their actions" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
get_timestamp() { printf '2026-05-24 10:00:00\n'; }
log_operation_session_start clean
log_operation clean REMOVED /tmp/parent 1KB
/bin/bash --noprofile --norc -c '
    source "$PROJECT_ROOT/lib/core/common.sh"
    log_operation_session_start clean
    log_operation clean FAILED /tmp/child "permission denied"
    log_operation_session_end clean 0 0
'
log_operation clean SKIPPED /tmp/parent-kept whitelist
kill -TERM "$$"
EOF
    [[ "$status" -eq 143 ]] || { echo "$output"; return 1; }
    run env HOME="$HOME" "$PROJECT_ROOT/mole" history --json
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    printf '%s\n' "$output" | python3 -c '
import json, sys
sessions = json.load(sys.stdin)["sessions"]
assert len(sessions) == 2, sessions
parent, = [s for s in sessions if not s["ended_at"]]
child, = [s for s in sessions if s["ended_at"]]
assert parent["run_id"] and parent["run_id"] != child["run_id"], sessions
assert parent["actions"]["removed"] == 1, parent
assert parent["actions"]["skipped"] == 1, parent
assert parent["actions"]["failed"] == 0, parent
assert child["actions"]["failed"] == 1, child
assert child["operation_count"] == 1, child
'
}

@test "mo history retains identified runs across missing markers and ignores malformed identities" {
    cat > "$HOME/Library/Logs/mole/operations.log" <<'EOF'
[2026-05-24 10:00:01] [clean run=left] REMOVED /tmp/first (1KB)
# ========== purge session started at 2026-05-24 10:01:00 ==========
[2026-05-24 10:01:01] [purge] TRASHED /tmp/legacy (1KB)
# ========== clean run=right session started at 2026-05-24 10:02:00 ==========
[2026-05-24 10:02:01] [clean run=right] FAILED /tmp/second (permission denied)
[2026-05-24 10:02:02] [clean run=] REMOVED /tmp/invalid-empty
[2026-05-24 10:02:03] [clean run=bad token] REMOVED /tmp/invalid-space
# ========== clean run=right session ended at 2026-05-24 10:03:00, 0 items, 0B ==========
# ========== purge session ended at 2026-05-24 10:04:00, 1 items, 1KB ==========
# ========== clean run=left session ended at 2026-05-24 10:05:00, 1 items, 1KB ==========
EOF
    run env HOME="$HOME" "$PROJECT_ROOT/mole" history --json
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    printf '%s\n' "$output" | python3 -c '
import json, sys
sessions = json.load(sys.stdin)["sessions"]
assert len(sessions) == 3, sessions
by_id = {s["run_id"]: s for s in sessions}
assert set(by_id) == {"left", "right", ""}, sessions
assert by_id["left"]["actions"]["removed"] == 1, sessions
assert by_id["left"]["ended_at"] == "2026-05-24 10:05:00", sessions
assert by_id["right"]["actions"]["failed"] == 1, sessions
assert by_id["right"]["actions"]["removed"] == 0, sessions
assert by_id[""]["actions"]["trashed"] == 1, sessions
assert by_id[""]["attribution"] == "command", sessions
assert sum(s["operation_count"] for s in sessions) == 3, sessions
'
}

@test "uninstall signal cleanup ends its run once" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_SKIP_MAIN=1 \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/uninstall.sh"
log_operation_session_start uninstall
log_operation uninstall SKIPPED /tmp/kept whitelist
kill -TERM "$$"
EOF
    run env HOME="$HOME" "$PROJECT_ROOT/mole" history --json
    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    printf '%s\n' "$output" | python3 -c '
import json, sys
sessions = json.load(sys.stdin)["sessions"]
assert len(sessions) == 1, sessions
assert sessions[0]["run_id"] and sessions[0]["ended_at"], sessions
assert sessions[0]["attribution"] == "run", sessions
assert sessions[0]["actions"]["skipped"] == 1, sessions
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

@test "mo history closes parked marker-less sessions at the next marker and keeps marked ones" {
    # installer and uninstall write no start marker, so a start marker for
    # another command ends both even while installer waits behind uninstall.
    cat > "$HOME/Library/Logs/mole/operations.log" <<'EOF'
[2026-10-08 10:00:01] [installer] REMOVED /tmp/a (1KB)
[2026-10-08 10:00:02] [uninstall] REMOVED /tmp/b (1KB)
# ========== clean session started at 2026-10-08 10:00:03 ==========
[2026-10-08 10:00:04] [clean] REMOVED /tmp/c (1KB)
[2026-10-08 10:00:05] [installer] REMOVED /tmp/d (1KB)
# ========== clean session ended at 2026-10-08 10:00:06, 1 items, 1KB ==========
EOF
    run env HOME="$HOME" "$PROJECT_ROOT/mole" history --json
    [ "$status" -eq 0 ] || return 1
    printf '%s\n' "$output" | python3 -c '
import json, sys
sessions = json.load(sys.stdin)["sessions"]
installers = [s for s in sessions if s["command"] == "installer"]
assert len(installers) == 2, sessions
assert all(s["actions"]["removed"] == 1 for s in installers), installers
assert [s["command"] for s in sessions] == ["installer", "uninstall", "clean", "installer"][::-1], sessions
'

    # A parked session that a start marker opened keeps waiting for its own
    # actions and end marker.
    cat > "$HOME/Library/Logs/mole/operations.log" <<'EOF'
# ========== purge session started at 2026-10-08 10:00:01 ==========
[2026-10-08 10:00:02] [purge] REMOVED /tmp/a (1KB)
[2026-10-08 10:00:03] [uninstall] REMOVED /tmp/b (1KB)
# ========== clean session started at 2026-10-08 10:00:04 ==========
[2026-10-08 10:00:05] [purge] REMOVED /tmp/c (1KB)
# ========== clean session ended at 2026-10-08 10:00:06, 0 items, 0B ==========
# ========== purge session ended at 2026-10-08 10:00:07, 2 items, 2KB ==========
EOF
    run env HOME="$HOME" "$PROJECT_ROOT/mole" history --json
    [ "$status" -eq 0 ] || return 1
    printf '%s\n' "$output" | python3 -c '
import json, sys
sessions = json.load(sys.stdin)["sessions"]
purges = [s for s in sessions if s["command"] == "purge"]
assert len(purges) == 1, sessions
assert purges[0]["actions"]["removed"] == 2 and purges[0]["ended_at"] == "2026-10-08 10:00:07", purges
'
}

@test "mo history load time does not grow with runs that never wrote an end marker" {
    # Compare against the same number of finished runs so the bound holds on
    # any host: finished runs never wait, interrupted ones used to be rescanned
    # for every new run and took several times longer.
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" python3 - <<'PY'
import os
import subprocess
import time

home = os.environ["HOME"]
root = os.environ["PROJECT_ROOT"]
log = os.path.join(home, "Library/Logs/mole/operations.log")


def write_log(ended):
    lines = []
    for i in range(400):
        rid = "20261008%06d-1-%d-%d" % (i, i, i)
        lines.append("# ========== clean run=%s session started at 2026-10-08 10:00:00 ==========" % rid)
        for j in range(10):
            lines.append("[2026-10-08 10:00:00] [clean run=%s] REMOVED /tmp/cache-%d-%d (1KB)" % (rid, i, j))
        if ended:
            lines.append("# ========== clean run=%s session ended at 2026-10-08 10:00:01, 10 items, 1KB ==========" % rid)
    with open(log, "w") as f:
        f.write("\n".join(lines) + "\n")


def load_once(ended):
    write_log(ended)
    start = time.perf_counter()
    subprocess.run([root + "/mole", "history", "--json"], env=dict(os.environ, HOME=home),
                   stdout=subprocess.DEVNULL, check=True)
    return time.perf_counter() - start


# Alternate the two logs so a busy host slows both sides alike, and keep each
# side's fastest run.
finished = interrupted = None
for _ in range(3):
    f = load_once(True)
    i = load_once(False)
    finished = f if finished is None else min(finished, f)
    interrupted = i if interrupted is None else min(interrupted, i)
print("finished=%.2fs interrupted=%.2fs" % (finished, interrupted))
assert interrupted < 2.0 * finished, (finished, interrupted)
PY
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
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
