#!/usr/bin/env bats

load helpers

log_file() { echo "$HOME/.local/state/mole/operations.log"; }

@test "rows carry a run id and always end in one detail" {
    run bash -c 'SCRIPT_DIR="$MOLE_TEST_REPO"; source "$MOLE_TEST_REPO/lib/core/common.sh"
        log_operation clean REMOVED "$HOME/a (x86)"
        log_operation clean REMOVED "$HOME/b" "1.2MB (est)"'
    [ "$status" -eq 0 ]
    grep -qE '^\[[0-9-]+ [0-9:]+\] \[clean run=[0-9]+-[0-9]+-[0-9]+\] REMOVED .*/a \(x86\) \(-\)$' "$(log_file)"
    grep -qE 'REMOVED .*/b \(1\.2MB \[est\]\)$' "$(log_file)"
}

@test "history groups rows by run, newest first, and reads old rows without run ids" {
    mkdir -p "$(dirname "$(log_file)")"
    cat > "$(log_file)" << 'LOG'
[2026-11-01 10:00:00] [clean] REMOVED /home/u/.cache/a (1.0MB)
[2026-11-01 10:00:01] [clean] REMOVED /home/u/.cache/b
[2026-11-01 11:00:00] [uninstall] TRASHED /home/u/.config/app

# ========== analyze run=20261102-1-2-3 session started at 2026-11-02 09:00:00 ==========
[2026-11-02 09:00:00] [analyze run=20261102-1-2-3] TRASHED /home/u/Program Files (x86) (-)
[2026-11-02 10:00:00] [purge run=20261102-9-9-9] REMOVED /home/u/www/app/node_modules (120MB)
[2026-11-02 10:00:01] [purge run=20261102-9-9-9] SKIPPED /home/u/www/new/node_modules (in use)
[2026-11-02 10:00:02] [optimize run=20261102-8-8-8] TASK_FAILED fontconfig (-)
not a record
LOG
    run bash "$REPO/mole" history
    [ "$status" -eq 0 ]
    [[ "$output" == *"Recent sessions"* ]]
    first=$(grep -m1 -E '^  [a-z]+ +2026' <<< "$output")
    [[ "$first" == *"optimize"*"failed 1"* ]]
    [[ "$output" == *"purge"*"removed 1, skipped 1"* ]]
    [[ "$output" == *"clean "*"2026-11-01 10:00:00, removed 2"* ]]
    [[ "$output" == *"trashed     /home/u/Program Files (x86)"* ]]
    [[ "$output" != *"(x86) (-)"* ]]
    [[ "$output" == *"node_modules (120MB)"* ]]

    run bash "$REPO/mole" history --json --limit 2
    [ "$status" -eq 0 ]
    [[ "$output" == *'"limit": 2'* ]]
    [ "$(grep -c '"command":' <<< "$output")" -eq 4 ]
    [[ "$output" == *'"path": "/home/u/www/new/node_modules", "detail": "in use"'* ]]
    [[ "$output" == *'"run_id": "20261102-8-8-8"'* ]]
    if command -v python3 > /dev/null; then
        python3 -c 'import json,sys; d=json.load(sys.stdin); assert len(d["sessions"])==2 and d["sessions"][0]["actions"]["failed"]==1' <<< "$output"
    fi
}

@test "history with no log, and bad arguments" {
    run bash "$REPO/mole" history
    [ "$status" -eq 0 ]
    [[ "$output" == *"No operation history yet."* ]]
    run bash "$REPO/mole" history --json
    [[ "$output" == *'"sessions": []'* ]]
    for bad in "--limit 0" "--limit 201" "--limit x" "--limit" "--bogus" "extra"; do
        # shellcheck disable=SC2086
        run bash "$REPO/mole" history $bad
        [ "$status" -eq 1 ]
    done
    run bash "$REPO/mole" history --limit=200
    [ "$status" -eq 0 ]
}

@test "a path with quotes and backslashes stays valid JSON" {
    mkdir -p "$(dirname "$(log_file)")"
    printf '%s\n' '[2026-11-02 10:00:00] [clean run=1-2-3] REMOVED /home/u/a "q" \x (-)' > "$(log_file)"
    run bash "$REPO/mole" history --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"path": "/home/u/a \"q\" \\x"'* ]]
}

@test "a path with control bytes is escaped in the log and valid in JSON" {
    run bash -c 'SCRIPT_DIR="$MOLE_TEST_REPO"; source "$MOLE_TEST_REPO/lib/core/common.sh"
        log_operation clean REMOVED "$HOME/a"$'"'"'\t'"'"'"b"$'"'"'\e'"'"'"c"'
    grep -q 'REMOVED .*/a\\tb\\x1bc (-)$' "$(log_file)"
    run bash "$REPO/mole" history --json
    [ "$status" -eq 0 ]
    if command -v python3 > /dev/null; then python3 -c 'import json,sys; json.load(sys.stdin)' <<< "$output"; fi
}

@test "--debug keeps a session log and says where it is" {
    run bash "$REPO/mole" history --debug
    [ "$status" -eq 0 ]
    [[ "$output" == *"Debug log: ~/.local/state/mole/mole_debug_session.log"* ]]
    head -1 "$HOME/.local/state/mole/mole_debug_session.log" | grep -q '^# Mole debug session'
    if grep -qw "$(id -un)" "$HOME/.local/state/mole/mole_debug_session.log"; then false; fi
}

@test "mo --version names the install source" {
    run bash "$REPO/mole" --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"Install: "* ]]
}
