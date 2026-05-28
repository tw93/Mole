#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-home.XXXXXX")"
    export HOME

    mkdir -p "$HOME"
}

teardown_file() {
    rm -rf "$HOME"
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

setup() {
    rm -rf "$HOME/.config"
    mkdir -p "$HOME"
}

@test "mo_spinner_chars returns default sequence" {
    result="$(HOME="$HOME" bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; mo_spinner_chars")"
    [ "$result" = "|/-\\" ]
}

@test "detect_architecture maps current CPU to friendly label" {
    expected="Intel"
    if [[ "$(uname -m)" == "arm64" ]]; then
        expected="Apple Silicon"
    fi
    result="$(HOME="$HOME" bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; detect_architecture")"
    [ "$result" = "$expected" ]
}

@test "get_free_space returns a non-empty value" {
    result="$(HOME="$HOME" bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; get_free_space")"
    [[ -n "$result" ]]
}

@test "cleanup_result_color_kb always returns green" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

small_kb=1
large_kb=$(((ROOMY_ONE_GB_BYTES * 2) / 1024))

if [[ "$(cleanup_result_color_kb "$small_kb")" == "$GREEN" ]] &&
    [[ "$(cleanup_result_color_kb "$large_kb")" == "$GREEN" ]]; then
    echo "ok"
fi
EOF

    [ "$status" -eq 0 ]
    [ "$output" = "ok" ]
}

@test "log_info prints message and appends to log file" {
    local message="Informational message from test"
    local stdout_output
    stdout_output="$(HOME="$HOME" bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; log_info '$message'")"
    [[ "$stdout_output" == *"$message"* ]]

    local log_file="$HOME/Library/Logs/roomy/roomy.log"
    [[ -f "$log_file" ]]
    grep -q "INFO: $message" "$log_file"
}

@test "log_error writes to stderr and log file" {
    local message="Something went wrong"
    local stderr_file="$HOME/log_error_stderr.txt"

    HOME="$HOME" bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; log_error '$message' 1>/dev/null 2>'$stderr_file'"

    [[ -s "$stderr_file" ]]
    grep -q "$message" "$stderr_file"

    local log_file="$HOME/Library/Logs/roomy/roomy.log"
    [[ -f "$log_file" ]]
    grep -q "ERROR: $message" "$log_file"
}

@test "debug log helpers replace symlinked debug log without following it" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

debug_log="$HOME/Library/Logs/roomy/roomy_debug_session.log"
protected="$HOME/protected-debug-log"
printf 'protected\n' > "$protected"

rm -f "$debug_log"
ln -s "$protected" "$debug_log"
export ROOMY_DEBUG=1
debug_risk_level HIGH "symlink-check"

grep -q "^protected$" "$protected"
[[ ! -L "$debug_log" ]]
grep -q "Risk Level: HIGH, symlink-check" "$debug_log"

rm -f "$debug_log"
ln -s "$protected" "$debug_log"
unset ROOMY_SYS_INFO_LOGGED
export ROOMY_TEST_NO_AUTH=1
log_system_info > /dev/null 2>&1

grep -q "^protected$" "$protected"
[[ ! -L "$debug_log" ]]
grep -q "Roomy Debug Session" "$debug_log"
EOF

    [ "$status" -eq 0 ]
}

@test "run_logged writes through symlink-safe log helpers and reports failures" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

log_file="$HOME/Library/Logs/roomy/roomy.log"
debug_log="$HOME/Library/Logs/roomy/roomy_debug_session.log"
protected_log="$HOME/protected-main-log"
protected_debug="$HOME/protected-debug-log"
printf 'protected-main\n' > "$protected_log"
printf 'protected-debug\n' > "$protected_debug"

rm -f "$log_file" "$debug_log"
ln -s "$protected_log" "$log_file"
ln -s "$protected_debug" "$debug_log"
export ROOMY_DEBUG=1

run_logged printf 'safe-output\n'

grep -q "^protected-main$" "$protected_log"
grep -q "^protected-debug$" "$protected_debug"
[[ ! -L "$log_file" ]]
[[ ! -L "$debug_log" ]]
grep -q "safe-output" "$log_file"
grep -q "safe-output" "$debug_log"

if run_logged bash -c 'printf "%s\n" failed-output; exit 7'; then
    echo "WRONG: run_logged swallowed command failure"
    exit 1
fi
grep -q "failed-output" "$log_file"
grep -q "Command failed: bash" "$log_file"
EOF

    [ "$status" -eq 0 ]
}

@test "dynamic helper variable names are validated before assignment" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

export ROOMY_DEBUG=1
debug_timer_start 'bad[$(touch "$HOME/timer-start-pwn")]' || true
debug_timer_end "Timer" 'bad[$(touch "$HOME/timer-end-pwn")]' || true
update_progress_if_needed 1 1 'bad[$(touch "$HOME/progress-pwn")]' 0 || true
build_regex_var 'bad[$(touch "$HOME/regex-pwn")]' 'com.example.*' || true

[[ ! -e "$HOME/timer-start-pwn" ]]
[[ ! -e "$HOME/timer-end-pwn" ]]
[[ ! -e "$HOME/progress-pwn" ]]
[[ ! -e "$HOME/regex-pwn" ]]

debug_timer_start roomy_timer_ok
[[ -n "${roomy_timer_ok:-}" ]]

last_progress_update=0
update_progress_if_needed 1 1 last_progress_update 0 > /dev/null 2>&1 || true
[[ "$last_progress_update" =~ ^[0-9]+$ ]]

ROOMY_TEST_REGEX=""
build_regex_var ROOMY_TEST_REGEX 'com.example.*'
[[ "$ROOMY_TEST_REGEX" == '^com\.example\..*$' ]]
EOF

    [ "$status" -eq 0 ]
}

@test "log_operation recreates operations log if the log directory disappears mid-session" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
rm -rf "$HOME/Library/Logs/roomy"
log_operation "clean" "REMOVED" "/tmp/example" "1KB"
EOF
    [ "$status" -eq 0 ]

    local oplog="$HOME/Library/Logs/roomy/operations.log"
    [[ -f "$oplog" ]]
    grep -Fq "[clean] REMOVED /tmp/example (1KB)" "$oplog"
}

@test "log_operation writes structured operation journal JSONL" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
log_operation_session_start "clean"
log_operation "clean" "TRASHED" "/tmp/example path" "1KB -> ~/.Trash/example path"
log_operation_session_end "clean" 1 1
EOF
    [ "$status" -eq 0 ]

    local journal="$HOME/Library/Logs/roomy/operation_journal.jsonl"
    [[ -f "$journal" ]]
    python3 - "$journal" <<'PY'
import json
import sys

records = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
assert any(record["record_type"] == "session" and record["action"] == "STARTED" for record in records)
operation = next(record for record in records if record["record_type"] == "operation" and record["action"] == "TRASHED")
assert operation["command"] == "clean"
assert operation["action"] == "TRASHED"
assert operation["path"] == "/tmp/example path"
assert "Trash" in operation["detail"]
assert records[-1]["action"] == "ENDED"
PY
}

@test "should_protect_path protects Roomy runtime logs" {
    result="$(
        HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc -c \
            'source "$PROJECT_ROOT/lib/core/common.sh"; should_protect_path "$HOME/Library/Logs/roomy/operations.log" && echo protected || echo not-protected'
    )"
    [ "$result" = "protected" ]
}

@test "rotate_log_once only checks log size once per session" {
    local log_file="$HOME/Library/Logs/roomy/roomy.log"
    mkdir -p "$(dirname "$log_file")"
    if command -v mkfile > /dev/null 2>&1; then
        mkfile -n 1100k "$log_file"
    else
        truncate -s 1100k "$log_file"
    fi

    HOME="$HOME" bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'"
    [[ -f "${log_file}.old" ]]

    result=$(HOME="$HOME" ROOMY_LOG_ROTATED=1 bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; echo \$ROOMY_LOG_ROTATED")
    [[ "$result" == "1" ]]
}

@test "rotate_log_once refuses symlinked rotation targets" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

log_file="$HOME/Library/Logs/roomy/roomy.log"
protected_dir="$HOME/protected-log-rotation"
mkdir -p "$protected_dir" "$(dirname "$log_file")"
if command -v mkfile > /dev/null 2>&1; then
    mkfile -n 1100k "$log_file"
else
    truncate -s 1100k "$log_file"
fi
printf 'large-log\n' >> "$log_file"
ln -sf "$protected_dir" "${log_file}.old"

unset ROOMY_LOG_ROTATED
rotate_log_once

[[ ! -L "${log_file}.old" ]]
[[ -f "${log_file}.old" ]]
[[ -f "$log_file" ]]
grep -q 'large-log' "${log_file}.old"
[[ -z "$(find "$protected_dir" -mindepth 1 -print -quit)" ]]
EOF

    [ "$status" -eq 0 ]
}

@test "drain_pending_input clears stdin buffer" {
    result=$(
        (echo -e "test\ninput" | HOME="$HOME" bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; drain_pending_input; echo done") &
        pid=$!
        sleep 2
        if kill -0 "$pid" 2> /dev/null; then
            kill "$pid" 2> /dev/null || true
            wait "$pid" 2> /dev/null || true
            echo "timeout"
        else
            wait "$pid" 2> /dev/null || true
        fi
    )
    [[ "$result" == "done" ]]
}

@test "bytes_to_human converts byte counts into readable units" {
    output="$(
        HOME="$HOME" bash --noprofile --norc << 'EOF'
source "$PROJECT_ROOT/lib/core/common.sh"
bytes_to_human 512
bytes_to_human 2000
bytes_to_human 5000000
bytes_to_human 3000000000
EOF
    )"

    bytes_lines=()
    while IFS= read -r line; do
        bytes_lines+=("$line")
    done <<< "$output"

    [ "${bytes_lines[0]}" = "512B" ]
    [ "${bytes_lines[1]}" = "2KB" ]
    [ "${bytes_lines[2]}" = "5.0MB" ]
    [ "${bytes_lines[3]}" = "3.00GB" ]
}

@test "create_temp_file and create_temp_dir are tracked and cleaned" {
    HOME="$HOME" bash --noprofile --norc << 'EOF'
source "$PROJECT_ROOT/lib/core/common.sh"
create_temp_file > "$HOME/temp_file_path.txt"
create_temp_dir > "$HOME/temp_dir_path.txt"
cleanup_temp_files
EOF

    file_path="$(cat "$HOME/temp_file_path.txt")"
    dir_path="$(cat "$HOME/temp_dir_path.txt")"
    [ ! -e "$file_path" ]
    [ ! -e "$dir_path" ]
    rm -f "$HOME/temp_file_path.txt" "$HOME/temp_dir_path.txt"
}

@test "command-substitution temp files are tracked and cleaned" {
    HOME="$HOME" bash --noprofile --norc << 'EOF'
source "$PROJECT_ROOT/lib/core/common.sh"
temp_file=$(create_temp_file)
prefixed_file=$(mktemp_file "roomy-substitution")
temp_dir=$(create_temp_dir)
printf '%s\n' "$temp_file" > "$HOME/temp_file_path.txt"
printf '%s\n' "$prefixed_file" > "$HOME/prefixed_file_path.txt"
printf '%s\n' "$temp_dir" > "$HOME/temp_dir_path.txt"
[[ -f "$temp_file" && -f "$prefixed_file" && -d "$temp_dir" ]]
cleanup_temp_files
EOF

    file_path="$(cat "$HOME/temp_file_path.txt")"
    prefixed_path="$(cat "$HOME/prefixed_file_path.txt")"
    dir_path="$(cat "$HOME/temp_dir_path.txt")"
    [ ! -e "$file_path" ]
    [ ! -e "$prefixed_path" ]
    [ ! -e "$dir_path" ]
    rm -f "$HOME/temp_file_path.txt" "$HOME/prefixed_file_path.txt" "$HOME/temp_dir_path.txt"
}


@test "should_protect_data protects system and critical apps" {
    result=$(HOME="$HOME" bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_data 'com.apple.Safari' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "protected" ]

    result=$(HOME="$HOME" bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_data 'com.clash.app' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "protected" ]

    result=$(HOME="$HOME" bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_data 'io.github.clash-verge-rev.clash-verge-rev' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "protected" ]

    result=$(HOME="$HOME" bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_data 'org.amnezia.awg' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "protected" ]

    result=$(HOME="$HOME" bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_data 'com.wireguard.macos' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "protected" ]

    result=$(HOME="$HOME" bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_data 'com.example.RegularApp' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "not-protected" ]
}

# Regression: CUPS prefs have a bundle-ID-style name but no parent .app,
# so the orphan sweep deleted them and users lost their default printer
# and recent-printer list. See #731.
@test "should_protect_data protects CUPS printing prefs (#731)" {
    result=$(HOME="$HOME" bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_data 'org.cups.PrintingPrefs' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "protected" ]

    result=$(HOME="$HOME" bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_data 'org.cups.printers' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "protected" ]
}

@test "should_protect_data protects Codex runtime identifiers" {
    result=$(HOME="$HOME" bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_data 'Codex' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "protected" ]

    result=$(HOME="$HOME" bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_data 'com.openai.codex' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "protected" ]

    result=$(HOME="$HOME" bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_data 'codex-runtimes' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "protected" ]

    local codex_runtimes_path="$HOME/.cache/codex-runtimes"
    result=$(HOME="$HOME" TARGET_PATH="$codex_runtimes_path" bash --noprofile --norc -c 'source "$PROJECT_ROOT/lib/core/common.sh"; should_protect_path "$TARGET_PATH" && echo "protected" || echo "not-protected"')
    [ "$result" = "protected" ]
}

@test "should_protect_path protects NetworkExtension VPN preferences" {
    result=$(HOME="$HOME" bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_path '/Volumes/Data/Library/Preferences/com.apple.networkextension.plist' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "protected" ]

    local user_network_ext_pref="$HOME/Library/Preferences/com.apple.networkextension.necp.plist"
    result=$(HOME="$HOME" TARGET_PATH="$user_network_ext_pref" bash --noprofile --norc -c 'source "$PROJECT_ROOT/lib/core/common.sh"; should_protect_path "$TARGET_PATH" && echo "protected" || echo "not-protected"')
    [ "$result" = "protected" ]
}

@test "input methods are protected during cleanup but allowed for uninstall" {
    result=$(HOME="$HOME" bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_data 'com.tencent.inputmethod.QQInput' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "protected" ]

    result=$(HOME="$HOME" bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_data 'com.sogou.inputmethod.pinyin' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "protected" ]

    result=$(HOME="$HOME" bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_from_uninstall 'com.tencent.inputmethod.QQInput' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "not-protected" ]

    result=$(HOME="$HOME" bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_from_uninstall 'com.apple.inputmethod.SCIM' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "protected" ]
}

@test "Apple apps from App Store can be uninstalled (Issue #386)" {
    # Xcode should NOT be protected from uninstall
    result=$(HOME="$HOME" bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_from_uninstall 'com.apple.dt.Xcode' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "not-protected" ]

    # Final Cut Pro should NOT be protected from uninstall
    result=$(HOME="$HOME" bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_from_uninstall 'com.apple.FinalCutPro' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "not-protected" ]

    # GarageBand should NOT be protected from uninstall
    result=$(HOME="$HOME" bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_from_uninstall 'com.apple.GarageBand' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "not-protected" ]

    # iWork apps should NOT be protected from uninstall
    result=$(HOME="$HOME" bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_from_uninstall 'com.apple.iWork.Pages' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "not-protected" ]

    # But Safari (system app) should still be protected
    result=$(HOME="$HOME" bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_from_uninstall 'com.apple.Safari' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "protected" ]

    # And Finder should still be protected
    result=$(HOME="$HOME" bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_from_uninstall 'com.apple.finder' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "protected" ]
}

@test "print_summary_block formats output correctly" {
    result=$(HOME="$HOME" bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; print_summary_block 'success' 'Test Summary' 'Detail 1' 'Detail 2'")
    [[ "$result" == *"Test Summary"* ]]
    [[ "$result" == *"Detail 1"* ]]
    [[ "$result" == *"Detail 2"* ]]
}

@test "start_inline_spinner and stop_inline_spinner work in non-TTY" {
    result=$(HOME="$HOME" bash --noprofile --norc << 'EOF'
source "$PROJECT_ROOT/lib/core/common.sh"
ROOMY_SPINNER_PREFIX="  " start_inline_spinner "Testing..."
sleep 0.1
stop_inline_spinner
echo "done"
EOF
    )
    [[ "$result" == *"done"* ]]
}

@test "start_inline_spinner ignores PATH-provided sleep in TTY mode" {
    if ! /usr/bin/script -q /dev/null /bin/true > /dev/null 2>&1; then
        skip "script cannot allocate a TTY in this environment"
    fi

    local fake_bin="$HOME/fake-bin"
    local marker="$HOME/fake-sleep.marker"

    mkdir -p "$fake_bin"
    cat > "$fake_bin/sleep" <<EOF
#!/bin/bash
echo "fake" >> "$marker"
exec /bin/sleep "\$@"
EOF
    chmod +x "$fake_bin/sleep"

    PATH="$fake_bin:$PATH" PROJECT_ROOT="$PROJECT_ROOT" HOME="$HOME" \
        /usr/bin/script -q /dev/null /bin/bash --noprofile --norc -c \
        "source \"\$PROJECT_ROOT/lib/core/common.sh\"; start_inline_spinner \"Testing...\"; /bin/sleep 0.15; stop_inline_spinner" \
        > /dev/null 2>&1

    [ ! -f "$marker" ]
}

@test "read_key maps j/k/h/l to navigation" {
    run bash -c "export ROOMY_BASE_LOADED=1; source '$PROJECT_ROOT/lib/core/ui.sh'; echo -n 'j' | read_key"
    [ "$output" = "DOWN" ]

    run bash -c "export ROOMY_BASE_LOADED=1; source '$PROJECT_ROOT/lib/core/ui.sh'; echo -n 'k' | read_key"
    [ "$output" = "UP" ]

    run bash -c "export ROOMY_BASE_LOADED=1; source '$PROJECT_ROOT/lib/core/ui.sh'; echo -n 'h' | read_key"
    [ "$output" = "LEFT" ]

    run bash -c "export ROOMY_BASE_LOADED=1; source '$PROJECT_ROOT/lib/core/ui.sh'; echo -n 'l' | read_key"
    [ "$output" = "RIGHT" ]
}

@test "read_key maps uppercase J/K/H/L to navigation" {
    run bash -c "export ROOMY_BASE_LOADED=1; source '$PROJECT_ROOT/lib/core/ui.sh'; echo -n 'J' | read_key"
    [ "$output" = "DOWN" ]

    run bash -c "export ROOMY_BASE_LOADED=1; source '$PROJECT_ROOT/lib/core/ui.sh'; echo -n 'K' | read_key"
    [ "$output" = "UP" ]
}

@test "read_key respects ROOMY_READ_KEY_FORCE_CHAR" {
    run bash -c "export ROOMY_BASE_LOADED=1; export ROOMY_READ_KEY_FORCE_CHAR=1; source '$PROJECT_ROOT/lib/core/ui.sh'; echo -n 'j' | read_key"
    [ "$output" = "CHAR:j" ]
}

@test "ensure_sudo_session returns 1 and sets ROOMY_SUDO_ESTABLISHED=false in test mode" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" ROOMY_TEST_NO_AUTH=1 bash --noprofile --norc <<'SCRIPT'
source "$PROJECT_ROOT/lib/core/base.sh"
source "$PROJECT_ROOT/lib/core/sudo.sh"
ROOMY_SUDO_ESTABLISHED=""
ensure_sudo_session "Test prompt" && rc=0 || rc=$?
echo "EXIT=$rc"
echo "FLAG=$ROOMY_SUDO_ESTABLISHED"
SCRIPT

    [ "$status" -eq 0 ]
    [[ "$output" == *"EXIT=1"* ]]
    [[ "$output" == *"FLAG=false"* ]]
}

@test "sudo helpers do not invoke sudo in no-auth test mode" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" ROOMY_TEST_NO_AUTH=1 bash --noprofile --norc <<'SCRIPT'
source "$PROJECT_ROOT/lib/core/base.sh"
source "$PROJECT_ROOT/lib/core/sudo.sh"
sudo() {
    echo "SUDO_CALLED:$*" >&2
    exit 99
}
export -f sudo

has_sudo_session && has_rc=0 || has_rc=$?
request_sudo_access "Test prompt" && request_rc=0 || request_rc=$?
ensure_sudo_session "Test prompt" && ensure_rc=0 || ensure_rc=$?

echo "HAS=$has_rc"
echo "REQUEST=$request_rc"
echo "ENSURE=$ensure_rc"
SCRIPT

    [ "$status" -eq 0 ]
    [[ "$output" == *"HAS=1"* ]]
    [[ "$output" == *"REQUEST=1"* ]]
    [[ "$output" == *"ENSURE=1"* ]]
    [[ "$output" != *"SUDO_CALLED"* ]]
}

@test "ensure_sudo_session short-circuits to 0 when session already established" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/base.sh"
source "$PROJECT_ROOT/lib/core/sudo.sh"
has_sudo_session() { return 0; }
export -f has_sudo_session
ROOMY_SUDO_ESTABLISHED="true"
ensure_sudo_session "Test prompt"
echo "EXIT=$?"
SCRIPT

    [ "$status" -eq 0 ]
    [[ "$output" == *"EXIT=0"* ]]
}
