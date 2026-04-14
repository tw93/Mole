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
large_kb=$(((MOLE_ONE_GB_BYTES * 2) / 1024))

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

    local log_file="$HOME/Library/Logs/mole/mole.log"
    [[ -f "$log_file" ]]
    grep -q "INFO: $message" "$log_file"
}

@test "log_error writes to stderr and log file" {
    local message="Something went wrong"
    local stderr_file="$HOME/log_error_stderr.txt"

    HOME="$HOME" bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; log_error '$message' 1>/dev/null 2>'$stderr_file'"

    [[ -s "$stderr_file" ]]
    grep -q "$message" "$stderr_file"

    local log_file="$HOME/Library/Logs/mole/mole.log"
    [[ -f "$log_file" ]]
    grep -q "ERROR: $message" "$log_file"
}

@test "log_operation recreates operations log if the log directory disappears mid-session" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
rm -rf "$HOME/Library/Logs/mole"
log_operation "clean" "REMOVED" "/tmp/example" "1KB"
EOF
    [ "$status" -eq 0 ]

    local oplog="$HOME/Library/Logs/mole/operations.log"
    [[ -f "$oplog" ]]
    grep -Fq "[clean] REMOVED /tmp/example (1KB)" "$oplog"
}

@test "should_protect_path protects Mole runtime logs" {
    result="$(
        HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc -c \
            'source "$PROJECT_ROOT/lib/core/common.sh"; should_protect_path "$HOME/Library/Logs/mole/operations.log" && echo protected || echo not-protected'
    )"
    [ "$result" = "protected" ]
}

@test "rotate_log_once only checks log size once per session" {
    local log_file="$HOME/Library/Logs/mole/mole.log"
    mkdir -p "$(dirname "$log_file")"
    dd if=/dev/zero of="$log_file" bs=1024 count=1100 2> /dev/null

    HOME="$HOME" bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'"
    [[ -f "${log_file}.old" ]]

    result=$(HOME="$HOME" MOLE_LOG_ROTATED=1 bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; echo \$MOLE_LOG_ROTATED")
    [[ "$result" == "1" ]]
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


@test "should_protect_data protects system and critical apps" {
    result=$(HOME="$HOME" bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_data 'com.apple.Safari' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "protected" ]

    result=$(HOME="$HOME" bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_data 'com.clash.app' && echo 'protected' || echo 'not-protected'")
    [ "$result" = "protected" ]

    result=$(HOME="$HOME" bash --noprofile --norc -c "source '$PROJECT_ROOT/lib/core/common.sh'; should_protect_data 'io.github.clash-verge-rev.clash-verge-rev' && echo 'protected' || echo 'not-protected'")
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
MOLE_SPINNER_PREFIX="  " start_inline_spinner "Testing..."
sleep 0.1
stop_inline_spinner
echo "done"
EOF
    )
    [[ "$result" == *"done"* ]]
}

@test "start_inline_spinner ignores PATH-provided sleep in TTY mode" {
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
    run bash -c "export MOLE_BASE_LOADED=1; source '$PROJECT_ROOT/lib/core/ui.sh'; echo -n 'j' | read_key"
    [ "$output" = "DOWN" ]

    run bash -c "export MOLE_BASE_LOADED=1; source '$PROJECT_ROOT/lib/core/ui.sh'; echo -n 'k' | read_key"
    [ "$output" = "UP" ]

    run bash -c "export MOLE_BASE_LOADED=1; source '$PROJECT_ROOT/lib/core/ui.sh'; echo -n 'h' | read_key"
    [ "$output" = "LEFT" ]

    run bash -c "export MOLE_BASE_LOADED=1; source '$PROJECT_ROOT/lib/core/ui.sh'; echo -n 'l' | read_key"
    [ "$output" = "RIGHT" ]
}

@test "read_key maps uppercase J/K/H/L to navigation" {
    run bash -c "export MOLE_BASE_LOADED=1; source '$PROJECT_ROOT/lib/core/ui.sh'; echo -n 'J' | read_key"
    [ "$output" = "DOWN" ]

    run bash -c "export MOLE_BASE_LOADED=1; source '$PROJECT_ROOT/lib/core/ui.sh'; echo -n 'K' | read_key"
    [ "$output" = "UP" ]
}

@test "read_key respects MOLE_READ_KEY_FORCE_CHAR" {
    run bash -c "export MOLE_BASE_LOADED=1; export MOLE_READ_KEY_FORCE_CHAR=1; source '$PROJECT_ROOT/lib/core/ui.sh'; echo -n 'j' | read_key"
    [ "$output" = "CHAR:j" ]
}

@test "ensure_sudo_session returns 1 and sets MOLE_SUDO_ESTABLISHED=false in test mode" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 bash --noprofile --norc <<'SCRIPT'
source "$PROJECT_ROOT/lib/core/base.sh"
source "$PROJECT_ROOT/lib/core/sudo.sh"
MOLE_SUDO_ESTABLISHED=""
ensure_sudo_session "Test prompt" && rc=0 || rc=$?
echo "EXIT=$rc"
echo "FLAG=$MOLE_SUDO_ESTABLISHED"
SCRIPT

    [ "$status" -eq 0 ]
    [[ "$output" == *"EXIT=1"* ]]
    [[ "$output" == *"FLAG=false"* ]]
}

@test "ensure_sudo_session short-circuits to 0 when session already established" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/base.sh"
source "$PROJECT_ROOT/lib/core/sudo.sh"
has_sudo_session() { return 0; }
export -f has_sudo_session
MOLE_SUDO_ESTABLISHED="true"
ensure_sudo_session "Test prompt"
echo "EXIT=$?"
SCRIPT

    [ "$status" -eq 0 ]
    [[ "$output" == *"EXIT=0"* ]]
}
