#!/usr/bin/env bats

load helpers/common

# Leaked automation-browser cleanup: only automation-profile processes are
# touched, dry-run never kills, and in-use profiles are never deleted.

setup_file() {
    mole_test_setup_home automation-browsers
    mkdir -p "$HOME"
}

teardown_file() {
    mole_test_teardown_home
}

# Stub binaries: ps emits one playwright-cli session daemon (ppid 1 by design,
# must survive), one reparented Chrome on an automation profile, one
# automation Chrome whose harness is still alive (must survive), one
# reparented automation Chrome too young to judge (must survive), and one
# unrelated browser (must survive). getconf points the profile scan at the
# test temp root.
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
# These cases exercise process identity, not timeout backend scheduling.
# Keep the real ps fixtures and PID rebind checks behind the same call boundary.
run_with_timeout() {
    [[ $# -ge 2 && "$1" == "$MOLE_TIMEOUT_QUICK_DETECT_SEC" && "$2" == ps ]] || return 99
    shift
    "$@"
}
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
    : > "$HOME/ps.trace"
    cat > "$HOME/bin/ps" <<'SCRIPT'
#!/bin/bash
printf '%s\n' "$*" >> "$HOME/ps.trace"
if [[ "$1" == "-Ao" ]]; then
    printf '%s\n' '  902     1 01-20:00:00 Tue Sep  1 02:03:04 2026 /Applications/Chrome.app/x --user-data-dir=/tmp/playwright_chromiumdev_profile-old'
else
    printf '%s\n' '  902     1 01-20:00:00 Fri Sep  4 11:12:13 2026 /Applications/Safari.app/Contents/MacOS/Safari'
fi
SCRIPT
    chmod +x "$HOME/bin/ps"

    run_cleanup false
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$(cat "$HOME/ps.trace")" == $'-Ao pid=,ppid=,etime=,lstart=,command= -ww\n-p 902 -o pid=,ppid=,etime=,lstart=,command= -ww' ]] || { cat "$HOME/ps.trace"; return 1; }
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
    printf '%s\n' '  902     1 01-20:00:00 Tue Sep  1 02:03:04 2026 /Applications/Chrome.app/x --user-data-dir=/tmp/playwright_chromiumdev_profile-old'
else
    printf '%s\n' '  902     1 01-20:00:00 Fri Sep  4 11:12:13 2026 /Applications/Safari.app/Contents/MacOS/Safari'
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
    grep -q 'KILL -TERM 902' "$HOME/kill.trace" || return 1
    ! grep -q 'KILL -9 902' "$HOME/kill.trace" || { cat "$HOME/kill.trace"; return 1; }
}

@test "kills only automation processes whose owner is gone" {
    make_process_stubs
    : > "$HOME/kill.trace"

    run_cleanup false
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"stopped 1 processes"* ]] || { echo "$output"; return 1; }
    grep -q 'KILL -TERM 902' "$HOME/kill.trace" || return 1
    # The playwright-cli daemon is spawned detached and unref'd, so ppid 1 is
    # its steady state for an active session. Killing it ends a live session.
    ! grep -q ' 901' "$HOME/kill.trace" || return 1
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
    [[ "$output" == *"would stop 1 processes"* ]] || { echo "$output"; return 1; }
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

@test "GNU stat earlier in PATH does not break stale profile cleanup (#1752)" {
    make_process_stubs
    : > "$HOME/kill.trace"
    mkdir -p "$HOME/tmproot/playwright_chromiumdev_profile-stale"
    touch -t 202601010000 "$HOME/tmproot/playwright_chromiumdev_profile-stale"
    # GNU coreutils reads -f as "file system status": it prints a File: block
    # and fails on the format operand, which aborted mo clean under set -u.
    cat > "$HOME/bin/stat" <<'SCRIPT'
#!/bin/bash
printf '  File: "%s"\n    ID: 0 Namelen: ? Type: apfs\n' "${@: -1}"
exit 1
SCRIPT
    chmod +x "$HOME/bin/stat"

    run_cleanup false
    rm -f "$HOME/bin/stat"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"SAFE_CLEAN"*"profile-stale"* ]] || { echo "$output"; return 1; }
}

@test "a profile is kept when pgrep cannot answer" {
    make_process_stubs
    : > "$HOME/kill.trace"
    mkdir -p "$HOME/tmproot/playwright_chromiumdev_profile-stale"
    touch -t 202601010000 "$HOME/tmproot/playwright_chromiumdev_profile-stale"
    # Exit 2 is a pgrep usage/regex failure, not "no process found".
    printf '#!/bin/bash\nexit 2\n' > "$HOME/bin/pgrep"
    chmod +x "$HOME/bin/pgrep"

    run_cleanup false
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" != *"SAFE_CLEAN"* ]] || { echo "$output"; return 1; }
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

@test "stale puppeteer profiles are cleaned, in-use and fresh profiles survive" {
    make_process_stubs
    : > "$HOME/kill.trace"

    mkdir -p "$HOME/tmproot/puppeteer_dev_chrome_profile-stale" \
        "$HOME/tmproot/puppeteer_dev_chrome_profile-live" \
        "$HOME/tmproot/puppeteer_dev_chrome_profile-fresh" \
        "$HOME/tmproot/puppeteer_dev_firefox_profile-stale"
    touch -t 202601010000 "$HOME/tmproot/puppeteer_dev_chrome_profile-stale"
    touch -t 202601010000 "$HOME/tmproot/puppeteer_dev_chrome_profile-live"
    touch -t 202601010000 "$HOME/tmproot/puppeteer_dev_firefox_profile-stale"

    run_cleanup false
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"SAFE_CLEAN"*"puppeteer_dev_chrome_profile-stale"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"SAFE_CLEAN"*"puppeteer_dev_firefox_profile-stale"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"SAFE_CLEAN"*"puppeteer_dev_chrome_profile-live"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"SAFE_CLEAN"*"puppeteer_dev_chrome_profile-fresh"* ]] || { echo "$output"; return 1; }
}

@test "kills only puppeteer automation processes whose owner is gone" {
    make_process_stubs
    : > "$HOME/kill.trace"
    cat > "$HOME/bin/ps" <<'SCRIPT'
#!/bin/bash
printf '%s\n' \
    '  910     1 01-20:00:00 Tue Sep  1 02:03:04 2026 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --user-data-dir=/tmp/puppeteer_dev_chrome_profile-old' \
    '  911   888 06-20:00:00 Wed Sep  2 03:04:05 2026 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --user-data-dir=/tmp/puppeteer_dev_chrome_profile-live'
SCRIPT
    chmod +x "$HOME/bin/ps"

    run_cleanup false
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"stopped 1 processes"* ]] || { echo "$output"; return 1; }
    grep -q 'KILL -TERM 910' "$HOME/kill.trace" || return 1
    ! grep -q ' 911' "$HOME/kill.trace" || return 1
}
