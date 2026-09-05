#!/usr/bin/env bats
# Leaked automation-browser cleanup: only automation-profile processes are
# touched, dry-run never kills, and in-use profiles are never deleted.

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-automation-browsers.XXXXXX")"
    export HOME
    mkdir -p "$HOME"
}

teardown_file() {
    if [[ "$HOME" == "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        rm -rf "$HOME"
    fi
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

# Stub binaries: ps emits one orphaned cliDaemon (ppid 1), one reparented
# Chrome on an automation profile, one automation Chrome whose harness is
# still alive (must survive), one reparented automation Chrome too young to
# judge (must survive), and one unrelated browser (must survive). getconf
# points the profile scan at the test temp root.
make_process_stubs() {
    mkdir -p "$HOME/bin" "$HOME/tmproot"
    cat > "$HOME/bin/ps" <<'SCRIPT'
#!/bin/bash
printf '%s\n' \
    '  901     1 02-01:00:00 Mon Aug 31 01:02:03 2026 /opt/homebrew/bin/node playwright-core/lib/entry/cliDaemon.js daemon' \
    '  902     1 01-20:00:00 Tue Sep  1 02:03:04 2026 /Applications/Chrome.app/x --user-data-dir=/tmp/playwright_chromiumdev_profile-old' \
    '  903   777 06-20:00:00 Wed Sep  2 03:04:05 2026 /Applications/Chrome.app/x --user-data-dir=/tmp/playwright_chromiumdev_profile-live' \
    '  905     1    05:00 Thu Sep  3 04:05:06 2026 /Applications/Chrome.app/x --user-data-dir=/tmp/playwright_chromiumdev_profile-new' \
    '  904     1 03-01:00:00 Sun Aug 30 05:06:07 2026 /Applications/Safari.app/Contents/MacOS/Safari'
SCRIPT
    cat > "$HOME/bin/getconf" <<SCRIPT
#!/bin/bash
printf '%s/\n' "$HOME/tmproot"
SCRIPT
    cat > "$HOME/bin/pgrep" <<'SCRIPT'
#!/bin/bash
# Simulate: only the "live" profile has a process still referencing it.
for arg in "$@"; do
    [[ "$arg" == *"profile-live"* ]] && exit 0
done
exit 1
SCRIPT
    chmod +x "$HOME/bin/ps" "$HOME/bin/getconf" "$HOME/bin/pgrep"
}

run_cleanup() {
    local dry_run="$1"
    run env HOME="$HOME" PATH="$HOME/bin:/usr/bin:/bin" PROJECT_ROOT="$PROJECT_ROOT" \
        DRY="$dry_run" TRACE="$HOME/kill.trace" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN="$DRY"
kill() { printf 'KILL %s\n' "$*" >> "$TRACE"; return 0; }
sleep() { :; }
safe_clean() {
    local -a paths=("$@")
    local label="${paths[${#paths[@]} - 1]}"
    unset 'paths[${#paths[@]}-1]'
    local p
    for p in "${paths[@]}"; do
        printf 'SAFE_CLEAN %s (%s)\n' "$p" "$label"
    done
}

note_activity() { :; }
clean_dev_automation_browsers
EOF
}

@test "does not signal a PID replaced between discovery and TERM" {
    make_process_stubs
    : > "$HOME/kill.trace"
    cat > "$HOME/bin/ps" <<'SCRIPT'
#!/bin/bash
if [[ "$1" == "-Ao" ]]; then
    printf '%s\n' '  901     1 02-01:00:00 Mon Aug 31 01:02:03 2026 /opt/homebrew/bin/node playwright-core/lib/entry/cliDaemon.js daemon'
else
    printf '%s\n' '  901     1 02-01:00:00 Fri Sep  4 11:12:13 2026 /Applications/Safari.app/Contents/MacOS/Safari'
fi
SCRIPT
    chmod +x "$HOME/bin/ps"

    run_cleanup false
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"stopped 0 processes"* ]] || { echo "$output"; return 1; }
    [ ! -s "$HOME/kill.trace" ] || { cat "$HOME/kill.trace"; return 1; }
}

@test "does not KILL a PID replaced after TERM" {
    make_process_stubs
    : > "$HOME/kill.trace"
    rm -f "$HOME/term-sent"
    export TERM_MARKER="$HOME/term-sent"
    cat > "$HOME/bin/ps" <<'SCRIPT'
#!/bin/bash
if [[ "$1" == "-Ao" || ! -e "$TERM_MARKER" ]]; then
    printf '%s\n' '  901     1 02-01:00:00 Mon Aug 31 01:02:03 2026 /opt/homebrew/bin/node playwright-core/lib/entry/cliDaemon.js daemon'
else
    printf '%s\n' '  901     1 02-01:00:00 Fri Sep  4 11:12:13 2026 /Applications/Safari.app/Contents/MacOS/Safari'
fi
SCRIPT
    chmod +x "$HOME/bin/ps"

    run env HOME="$HOME" PATH="$HOME/bin:/usr/bin:/bin" PROJECT_ROOT="$PROJECT_ROOT" \
        DRY=false TRACE="$HOME/kill.trace" TERM_MARKER="$TERM_MARKER" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN="$DRY"
kill() {
    printf 'KILL %s\n' "$*" >> "$TRACE"
    [[ "$1" == "-TERM" ]] && : > "$TERM_MARKER"
    return 0
}
sleep() { :; }
safe_clean() { :; }
note_activity() { :; }
clean_dev_automation_browsers
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -q 'KILL -TERM 901' "$HOME/kill.trace" || return 1
    ! grep -q 'KILL -9 901' "$HOME/kill.trace" || { cat "$HOME/kill.trace"; return 1; }
}

@test "kills only automation processes whose owner is gone" {
    make_process_stubs
    : > "$HOME/kill.trace"

    run_cleanup false
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"stopped 2 processes"* ]] || { echo "$output"; return 1; }
    grep -q 'KILL -TERM 901' "$HOME/kill.trace" || return 1
    grep -q 'KILL -TERM 902' "$HOME/kill.trace" || return 1
    # A live automation run keeps its parent, so it is never signaled however
    # long it has been running. This is the call age alone cannot make.
    ! grep -q ' 903' "$HOME/kill.trace" || return 1
    # Reparented but under an hour: possibly mid-handoff, so left alone.
    ! grep -q ' 905' "$HOME/kill.trace" || return 1
    # The unrelated browser is never touched.
    ! grep -q ' 904' "$HOME/kill.trace" || return 1
}

@test "dry run reports but never signals a process" {
    make_process_stubs
    : > "$HOME/kill.trace"

    run_cleanup true
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"would stop 2 processes"* ]] || { echo "$output"; return 1; }
    [ ! -s "$HOME/kill.trace" ] || { cat "$HOME/kill.trace"; return 1; }
}

@test "stale profiles are cleaned, in-use and fresh profiles survive" {
    make_process_stubs
    : > "$HOME/kill.trace"

    mkdir -p "$HOME/tmproot/playwright_chromiumdev_profile-stale" \
        "$HOME/tmproot/playwright_chromiumdev_profile-live" \
        "$HOME/tmproot/playwright_chromiumdev_profile-fresh"
    # Age the stale and live dirs well past the 2h threshold.
    touch -t 202601010000 "$HOME/tmproot/playwright_chromiumdev_profile-stale"
    touch -t 202601010000 "$HOME/tmproot/playwright_chromiumdev_profile-live"

    run_cleanup false
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"SAFE_CLEAN"*"profile-stale"* ]] || { echo "$output"; return 1; }
    # In-use profile (pgrep hit) and fresh profile (under 2h) stay.
    [[ "$output" != *"SAFE_CLEAN"*"profile-live"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"SAFE_CLEAN"*"profile-fresh"* ]] || { echo "$output"; return 1; }
}

@test "quiet no-op when nothing leaked" {
    mkdir -p "$HOME/bin" "$HOME/tmproot-empty"
    cat > "$HOME/bin/ps" <<'SCRIPT'
#!/bin/bash
printf '%s\n' '  904     1 03-01:00:00 /Applications/Safari.app/Contents/MacOS/Safari'
SCRIPT
    cat > "$HOME/bin/getconf" <<SCRIPT
#!/bin/bash
printf '%s/\n' "$HOME/tmproot-empty"
SCRIPT
    chmod +x "$HOME/bin/ps" "$HOME/bin/getconf"

    run_cleanup false
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" != *"stopped"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"SAFE_CLEAN"* ]] || { echo "$output"; return 1; }
}
