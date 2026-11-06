#!/usr/bin/env bats

load helpers/common

setup() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT
    export MO_DEBUG=0
}

@test "run_with_timeout: command completes before timeout" {
    result=$(/bin/bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 5 echo 'success'
    ")
    [[ "$result" == "success" ]]
}

@test "run_with_timeout: zero timeout runs command normally" {
    result=$(/bin/bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 0 echo 'no_timeout'
    ")
    [[ "$result" == "no_timeout" ]]
}

@test "run_with_timeout: invalid timeout runs command normally" {
    result=$(/bin/bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout invalid echo 'no_timeout'
    ")
    [[ "$result" == "no_timeout" ]]
}

@test "run_with_timeout: negative timeout runs command normally" {
    result=$(/bin/bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout -5 echo 'no_timeout'
    ")
    [[ "$result" == "no_timeout" ]]
}

@test "run_with_timeout: preserves command exit code on success" {
    /bin/bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 5 true
    "
    exit_code=$?
    [[ $exit_code -eq 0 ]]
}

@test "run_with_timeout: preserves command exit code on failure" {
    set +e
    /bin/bash -c "
        set +e
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 5 false
        exit \$?
    "
    exit_code=$?
    set -e
    [[ $exit_code -eq 1 ]]
}

@test "run_with_timeout: returns 124 on timeout (if using gtimeout)" {
    if ! command -v gtimeout >/dev/null 2>&1 && ! command -v timeout >/dev/null 2>&1; then
        skip "gtimeout/timeout not available"
    fi

    set +e
    /bin/bash -c "
        set +e
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 1 sleep 3
        exit \$?
    "
    exit_code=$?
    set -e
    [[ $exit_code -eq 124 ]]
}

@test "run_with_timeout: timeout backend kills a command that ignores TERM (#1787)" {
    if ! command -v gtimeout >/dev/null 2>&1 && ! command -v timeout >/dev/null 2>&1; then
        skip "gtimeout/timeout not available"
    fi

    start_time=$(date +%s)
    set +e
    /bin/bash -c "
        set +e
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 1 perl -e '\$SIG{TERM} = \"IGNORE\"; sleep 10'
        exit \$?
    "
    exit_code=$?
    set -e
    duration=$(($(date +%s) - start_time))
    [[ $exit_code -eq 124 ]] || return 1
    [[ $duration -lt 7 ]]
}

@test "run_with_timeout: an early SIGKILL is not reported as a timeout" {
    if ! command -v gtimeout >/dev/null 2>&1 && ! command -v timeout >/dev/null 2>&1; then
        skip "gtimeout/timeout not available"
    fi

    set +e
    /bin/bash -c "
        set +e
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 5 perl -e 'kill 9, \$\$'
        exit \$?
    "
    exit_code=$?
    set -e
    [[ $exit_code -eq 137 ]]
}

@test "run_with_timeout: fractional deadlines preserve an early SIGKILL" {
    if ! command -v gtimeout >/dev/null 2>&1 && ! command -v timeout >/dev/null 2>&1; then
        skip "gtimeout/timeout not available"
    fi

    # Both a sub-second budget and a kill after its whole-second portion must
    # retain the signal status rather than looking like timeout escalation.
    run /bin/bash -c 'source "$1/lib/core/timeout.sh"; run_with_timeout 0.4 /bin/bash -c '\''kill -9 $$'\''' bash "$PROJECT_ROOT"
    [[ $status -eq 137 ]] || return 1
    run /bin/bash -c 'source "$1/lib/core/timeout.sh"; run_with_timeout 1.9 /bin/bash -c '\''sleep 1.1; kill -9 $$'\''' bash "$PROJECT_ROOT"
    [[ $status -eq 137 ]]
}

@test "run_with_timeout: fractional deadlines still classify forced timeout escalation" {
    if ! command -v gtimeout >/dev/null 2>&1 && ! command -v timeout >/dev/null 2>&1; then
        skip "gtimeout/timeout not available"
    fi

    run /bin/bash -c 'source "$1/lib/core/timeout.sh"; run_with_timeout 0.4 /bin/bash -c '\''trap "" TERM; sleep 10'\''' bash "$PROJECT_ROOT"
    [[ $status -eq 124 ]]
}

@test "run_with_timeout: kills long-running command" {
    start_time=$(date +%s)
    set +e
    /bin/bash -c "
        set +e
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 2 sleep 5
    " >/dev/null 2>&1
    set -e
    end_time=$(date +%s)
    duration=$((end_time - start_time))

    [[ $duration -lt 10 ]]
}

@test "run_with_timeout: handles fast-completing commands" {
    start_time=$(date +%s)
    /bin/bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 10 echo 'fast'
    " >/dev/null 2>&1
    end_time=$(date +%s)
    duration=$((end_time - start_time))

    [[ $duration -lt 3 ]]
}

@test "run_with_timeout: works in pipefail mode" {
    result=$(/bin/bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 5 echo 'pipefail_test'
    ")
    [[ "$result" == "pipefail_test" ]]
}

@test "run_with_timeout: doesn't cause unintended exits" {
    result=$(/bin/bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 5 true || true
        echo 'survived'
    ")
    [[ "$result" == "survived" ]]
}

@test "run_with_timeout: handles commands with arguments" {
    result=$(/bin/bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 5 echo 'arg1' 'arg2' 'arg3'
    ")
    [[ "$result" == "arg1 arg2 arg3" ]]
}

@test "run_with_timeout: handles commands with spaces in arguments" {
    result=$(/bin/bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 5 echo 'hello world'
    ")
    [[ "$result" == "hello world" ]]
}

@test "run_with_timeout: debug logging when MO_DEBUG=1" {
    # On a terminal the notice is still printed; captured output is covered by
    # "run_with_timeout keeps its debug notice out of captured command output".
    output=$(script -q /dev/null /bin/bash -c "
        set -euo pipefail
        export MO_DEBUG=1
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 5 echo 'test'
    " < /dev/null)
    # The per-call notice, not the one-time backend line printed at source.
    [[ "$output" =~ \[TIMEOUT\]\ (Running\ with\ 5s\ timeout|Perl\ fallback,\ 5s|Shell\ fallback,\ 5s):\ echo\ test ]] || return 1
}

@test "run_with_timeout: no debug logging when MO_DEBUG=0" {
    output=$(/bin/bash -c "
        set -euo pipefail
        export MO_DEBUG=0
        unset MO_TIMEOUT_INITIALIZED
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 5 echo 'test'
    " 2>/dev/null)
    [[ "$output" == "test" ]]
}

@test "timeout.sh: prevents multiple sourcing" {
    result=$(/bin/bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        echo 'loaded'
    ")
    [[ "$result" == "loaded" ]]
}

@test "timeout.sh: sets MOLE_TIMEOUT_LOADED flag" {
    result=$(/bin/bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        echo \"\$MOLE_TIMEOUT_LOADED\"
    ")
    [[ "$result" == "1" ]]
}

@test "run_with_timeout: perl fallback preserves command exit code (#1003)" {
    if ! command -v perl > /dev/null 2>&1; then
        skip "perl not available"
    fi
    set +e
    /bin/bash -c "
        set +e
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        MO_TIMEOUT_BIN=''
        MO_TIMEOUT_PERL_BIN=\"\$(command -v perl)\"
        run_with_timeout 5 sh -c 'exit 7'
        exit \$?
    "
    exit_code=$?
    set -e
    [[ $exit_code -eq 7 ]]
}

@test "run_with_timeout: perl fallback kills long-running command (#1003)" {
    if ! command -v perl > /dev/null 2>&1; then
        skip "perl not available"
    fi
    start_time=$(date +%s)
    set +e
    /bin/bash -c "
        set +e
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        MO_TIMEOUT_BIN=''
        MO_TIMEOUT_PERL_BIN=\"\$(command -v perl)\"
        run_with_timeout 2 sleep 8
    " > /dev/null 2>&1
    set -e
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    [[ $duration -lt 7 ]]
}

@test "run_with_timeout: perl fallback cleans child when its caller dies" {
    if [[ "$(uname -s)" != "Darwin" || ! -x /usr/bin/perl ]]; then
        skip "macOS perl required"
    fi

    local child_pid_file="$BATS_TEST_TMPDIR/timeout-child.pid"
    local caller_pid=""
    local perl_pid=""
    local child_pid=""

    /bin/bash "$PROJECT_ROOT/tests/timeout_parent_death_fixture.sh" \
        "$PROJECT_ROOT" "$child_pid_file" > /dev/null 2>&1 &
    caller_pid=$!

    for _ in {1..50}; do
        [[ -s "$child_pid_file" ]] && break
        /bin/sleep 0.1
    done
    [[ -s "$child_pid_file" ]] || {
        kill -KILL "$caller_pid" 2> /dev/null || true
        return 1
    }

    child_pid=$(cat "$child_pid_file")
    perl_pid=$(pgrep -P "$caller_pid" -x perl 2> /dev/null | head -1 || true)
    [[ "$child_pid" =~ ^[0-9]+$ && "$perl_pid" =~ ^[0-9]+$ ]] || {
        kill -KILL "$caller_pid" "$child_pid" 2> /dev/null || true
        return 1
    }

    kill -TERM "$caller_pid"
    for _ in {1..50}; do
        if ! kill -0 "$perl_pid" 2> /dev/null && ! kill -0 "$child_pid" 2> /dev/null; then
            break
        fi
        /bin/sleep 0.1
    done

    local leaked=0
    if kill -0 "$perl_pid" 2> /dev/null || kill -0 "$child_pid" 2> /dev/null; then
        leaked=1
        kill -KILL "$perl_pid" "$child_pid" 2> /dev/null || true
    fi
    kill -KILL "$caller_pid" 2> /dev/null || true
    wait "$caller_pid" 2> /dev/null || true

    [ "$leaked" -eq 0 ]
}

# setsid() in the perl fallback strips the controlling terminal, which breaks
# nested sudo inside brew cask uninstall scripts (issue #1003). The fallback must
# use setpgid to keep the tty while still enabling process-group kill. This guards
# against a regression that is otherwise only observable on a real terminal.
@test "timeout.sh: perl fallback must not detach the controlling tty (#1003)" {
    # Match call statements at line start, not the comments that explain why
    # setsid is avoided (those mention "setsid()" mid-line and would false-positive).
    run grep -nE '^[[:space:]]*setsid[[:space:]]*\(' "$PROJECT_ROOT/lib/core/timeout.sh"
    [ "$status" -ne 0 ]
    run grep -nE '^[[:space:]]*setpgid[[:space:]]*\(' "$PROJECT_ROOT/lib/core/timeout.sh"
	[ "$status" -eq 0 ]
}

@test "run_with_timeout: perl fallback keeps tty reads in foreground (#1201)" {
	if [[ "$(uname -s)" != "Darwin" || ! -x /usr/bin/expect || ! -x /usr/bin/perl ]]; then
		skip "macOS expect/perl required"
	fi

	run /usr/bin/expect "$PROJECT_ROOT/tests/timeout_tty_read.exp" "$PROJECT_ROOT"

	[ "$status" -eq 0 ]
	[[ "$output" == *"READ:typed-value"* ]]
}

@test "run_with_timeout: perl fallback restores tty after timeout (#1201)" {
	if [[ "$(uname -s)" != "Darwin" || ! -x /usr/bin/expect || ! -x /usr/bin/perl ]]; then
		skip "macOS expect/perl required"
	fi

	run /usr/bin/expect "$PROJECT_ROOT/tests/timeout_tty_restore.exp" "$PROJECT_ROOT"

	[ "$status" -eq 0 ]
	[[ "$output" == *"TIMEOUT:124"* ]] || return 1
	[[ "$output" == *"READ-AFTER:typed-after"* ]]
}

# Issue #1222: the perl fallback hands the controlling terminal to its timed
# child whenever stdin is a tty (the #1201 behaviour). When it is invoked from a
# background metadata/scan worker in bin/uninstall.sh that still has the tty on
# stdin, that handoff steals the foreground process group from the foreground
# script, which then stops with SIGTTIN at the confirmation prompt. Redirecting
# the worker's stdin from /dev/null makes -t STDIN false and skips the handoff.
# These two tests pin both halves of the contract: the handoff still happens for
# interactive (tty) callers, and never happens once stdin is /dev/null.
_tty_bg_field() {
	# Extract NAME=<digits> from the fixture output (single line each).
	printf '%s\n' "$2" | sed -n "s/.*${1}=\\([0-9][0-9]*\\).*/\\1/p" | head -1
}

@test "run_with_timeout: perl fallback hands tty to child when stdin is a tty (#1201/#1222)" {
	if [[ "$(uname -s)" != "Darwin" || ! -x /usr/bin/expect || ! -x /usr/bin/perl ]]; then
		skip "macOS expect/perl required"
	fi

	run /usr/bin/expect "$PROJECT_ROOT/tests/timeout_tty_background.exp" "$PROJECT_ROOT" tty

	[ "$status" -eq 0 ] || return 1
	local child fg caller
	child=$(_tty_bg_field CHILD_PGRP "$output")
	fg=$(_tty_bg_field FG "$output")
	caller=$(_tty_bg_field CALLER_PGRP "$output")
	[[ -n "$child" && -n "$fg" && -n "$caller" ]] || return 1
	# The timed child captured the terminal's foreground process group.
	[ "$fg" = "$child" ] || return 1
	[ "$fg" != "$caller" ] || return 1
}

@test "run_with_timeout: perl fallback keeps tty with caller when stdin is /dev/null (#1222)" {
	if [[ "$(uname -s)" != "Darwin" || ! -x /usr/bin/expect || ! -x /usr/bin/perl ]]; then
		skip "macOS expect/perl required"
	fi

	run /usr/bin/expect "$PROJECT_ROOT/tests/timeout_tty_background.exp" "$PROJECT_ROOT" devnull

	[ "$status" -eq 0 ] || return 1
	local child fg caller
	child=$(_tty_bg_field CHILD_PGRP "$output")
	fg=$(_tty_bg_field FG "$output")
	caller=$(_tty_bg_field CALLER_PGRP "$output")
	[[ -n "$child" && -n "$fg" && -n "$caller" ]] || return 1
	# No handoff: the terminal's foreground group stayed with the caller.
	[ "$fg" = "$caller" ] || return 1
	[ "$fg" != "$child" ] || return 1
}

# Guard the actual call sites: background uninstall workers must redirect stdin
# from /dev/null. Without it the Perl timeout fallback can steal the terminal
# from a background worker and suspend the foreground prompt with SIGTTIN.
@test "uninstall: background timeout workers redirect stdin (#1222)" {
	# Disowned metadata-refresh subshell close.
	run grep -nE '^[[:space:]]*\)[[:space:]]*>[[:space:]]*/dev/null[[:space:]]+2>&1[[:space:]]+<[[:space:]]*/dev/null[[:space:]]*&[[:space:]]*$' "$PROJECT_ROOT/bin/uninstall.sh"
	[ "$status" -eq 0 ] || return 1
	# Parallel scan workers.
	run grep -nE 'process_app_metadata[[:space:]].*<[[:space:]]*/dev/null[[:space:]]*&[[:space:]]*$' "$PROJECT_ROOT/bin/uninstall.sh"
	[ "$status" -eq 0 ] || return 1
	# Post-uninstall work: Homebrew autoremove and LaunchServices/Dock refresh.
	run grep -cE '^[[:space:]]*\)[[:space:]]*>[[:space:]]*/dev/null[[:space:]]+2>&1[[:space:]]+<[[:space:]]*/dev/null[[:space:]]*&[[:space:]]*$' "$PROJECT_ROOT/lib/uninstall/batch.sh"
	[ "$status" -eq 0 ] || return 1
	[ "$output" -ge 2 ] || return 1
}

@test "run_with_timeout: shell fallback preserves caller INT trap" {
    result=$(/bin/bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        MO_TIMEOUT_BIN=''
        MO_TIMEOUT_PERL_BIN=''
        trap 'echo caller-trap' INT
        run_with_timeout 2 true
        trap -p INT
    ")
    [[ "$result" == *"caller-trap"* ]]
}

@test "run_with_timeout: shell fallback cleans up watchdog sleep" {
    /bin/bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        MO_TIMEOUT_BIN=''
        MO_TIMEOUT_PERL_BIN=''
        run_with_timeout 287 true
        sleep 0.1
        leaked=''
        for pid in \$(pgrep -x sleep 2>/dev/null || true); do
            command_line=\$(ps -p \"\$pid\" -o command= 2>/dev/null || true)
            if [[ \"\$command_line\" == 'sleep 287' ]]; then
                leaked=\"\$pid\"
                kill \"\$pid\" 2>/dev/null || true
            fi
        done
        [[ -z \"\$leaked\" ]] || return 1
    "
}

# A directory-sizing `du` on a stalled network mount or a huge tree wedges the
# whole scan: it has no internal bound and the caller usually pipes it into a
# command substitution that just waits. Every `du -s*` in lib/ and bin/ must
# therefore run under run_with_timeout or the shared bounded sudo helper. This
# test pins that so a new sizing site cannot be added unbounded.
@test "every du sizing call in lib/ and bin/ runs under run_with_timeout" {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    unbounded=""
    while IFS=: read -r file line text; do
        [[ "$text" =~ ^[[:space:]]*# ]] && continue
        local first_line=$((line > 2 ? line - 2 : 1))
        local context=""
        context=$(sed -n "${first_line},${line}p" "$file")
        if ! grep -Eq 'run_with_timeout|_mole_bounded_sudo' <<< "$context"; then
            unbounded+="${file}:${line}:${text}"$'\n'
        fi
    done < <(grep -rn -- 'du -s' "$PROJECT_ROOT/lib" "$PROJECT_ROOT/bin" || true)
    if [[ -n "$unbounded" ]]; then
        echo "Unbounded du call sites:" >&2
        echo "$unbounded" >&2
        return 1
    fi
}

@test "timeout status predicates name the two questions callers ask" {
    run /bin/bash --noprofile --norc -c '
        set -euo pipefail
        source "$1/lib/core/timeout.sh"
        for rc in 0 1 2 123 124 125 127 128 130 143 ""; do
            a=no
            b=no
            mole_rc_timeout "$rc" && a=yes
            mole_rc_timeout_or_signal "$rc" && b=yes
            printf "%s:%s:%s " "${rc:-empty}" "$a" "$b"
        done
    ' _ "${BATS_TEST_DIRNAME}/.."

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == "0:no:no 1:no:no 2:no:no 123:no:no 124:yes:yes 125:no:no 127:no:no 128:no:yes 130:no:yes 143:no:yes empty:no:no " ]]
}

@test "mole_rc_signal accepts only statuses that name a real signal" {
    # An owner command may exit with an errno-derived status above 127 (npm's
    # 243, for one). That is an ordinary failure, and a timeout is not a signal.
    run /bin/bash --noprofile --norc -c '
        set -euo pipefail
        source "$1/lib/core/timeout.sh"
        for rc in 0 1 124 127 128 129 130 143 159 160 192 243 255 ""; do
            a=no
            mole_rc_signal "$rc" && a=yes
            printf "%s:%s " "${rc:-empty}" "$a"
        done
    ' _ "${BATS_TEST_DIRNAME}/.."

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == "0:no 1:no 124:no 127:no 128:no 129:yes 130:yes 143:yes 159:yes 160:no 192:no 243:no 255:no empty:no " ]]
}

@test "run_with_timeout keeps its debug notice out of captured command output" {
    # Callers parse `$(run_with_timeout ... cmd 2>&1)`; under --debug the
    # wrapper's own notice used to arrive inside that capture, and purge read
    # it as an lsof warning.
    mkdir -p "$HOME/fake-timeout"
    cat > "$HOME/fake-timeout/timeout" <<'SCRIPT'
#!/bin/bash
shift 3
exec "$@"
SCRIPT
    chmod +x "$HOME/fake-timeout/timeout"
    run env HOME="$HOME" PROJECT_ROOT="${BATS_TEST_DIRNAME}/.." MO_DEBUG=1 FAKE_TIMEOUT="$HOME/fake-timeout/timeout" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
for backend in binary perl shell; do
    case "$backend" in
        binary) MO_TIMEOUT_BIN="$FAKE_TIMEOUT" MO_TIMEOUT_PERL_BIN="" ;;
        perl) MO_TIMEOUT_BIN="" MO_TIMEOUT_PERL_BIN="$(command -v perl)" ;;
        shell) MO_TIMEOUT_BIN="" MO_TIMEOUT_PERL_BIN="" ;;
    esac
    : > "$DEBUG_LOG_FILE"
    out=$(run_with_timeout 5 /bin/sh -c 'echo OUT; echo ERR >&2' 2>&1)
    [[ "$out" == $'OUT\nERR' ]] || { printf 'CAPTURED:%s:%s\n' "$backend" "$out"; exit 1; }
    grep -q '^\[TIMEOUT\] ' "$DEBUG_LOG_FILE" || { echo "NOT_LOGGED:$backend"; exit 1; }
    # An unwritable debug log must not put its write error in the capture.
    chmod 444 "$DEBUG_LOG_FILE"
    out=$(run_with_timeout 5 /bin/sh -c 'echo OUT' 2>&1)
    chmod 644 "$DEBUG_LOG_FILE"
    [[ "$out" == OUT ]] || { printf 'UNWRITABLE:%s:%s\n' "$backend" "$out"; exit 1; }
done
echo CLEAN
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *CLEAN* ]] || { echo "$output"; return 1; }
}

@test "run_with_timeout shell fallback stops the command when interrupted" {
    # A background command ignores SIGINT without job control, so forwarding
    # INT left it running with no deadline after Ctrl-C. The double case runs
    # under an exiting caller trap like bin/clean.sh's and presses Ctrl-C again
    # inside the grace period, which used to skip the KILL.
    cat > "$HOME/interrupt.sh" <<'EOF'
source "$PROJECT_ROOT/lib/core/common.sh"
MO_TIMEOUT_BIN="" MO_TIMEOUT_PERL_BIN=""
rc_file="$1"
caller_trap="$2"
shift 2
[[ "$caller_trap" == exit ]] && trap 'exit 130' INT
rc=0
run_with_timeout 40 "$@" || rc=$?
echo "$rc" > "$rc_file"
EOF
    local mode pid_file rc_file runner_pid cmd_pid ticks caller_trap
    for mode in plain ignores-term double-interrupt; do
        pid_file="$HOME/cmd-$mode.pid"
        rc_file="$HOME/cmd-$mode.rc"
        rm -f "$pid_file" "$rc_file" # SAFE: test-owned scratch files
        caller_trap=none
        [[ "$mode" == double-interrupt ]] && caller_trap="exit"
        if [[ "$mode" == plain ]]; then
            # shellcheck disable=SC2016 # $$ and $1 belong to the inner sh.
            /usr/bin/perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV' \
                env PROJECT_ROOT="${BATS_TEST_DIRNAME}/.." /bin/bash "$HOME/interrupt.sh" "$rc_file" "$caller_trap" \
                /bin/sh -c 'echo $$ > "$1"; exec /bin/sleep 39' sh "$pid_file" > /dev/null 2>&1 3>&- &
        else
            # shellcheck disable=SC2016 # Perl variables, not Bash.
            /usr/bin/perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV' \
                env PROJECT_ROOT="${BATS_TEST_DIRNAME}/.." /bin/bash "$HOME/interrupt.sh" "$rc_file" "$caller_trap" \
                /usr/bin/perl -e 'open(my $f, ">", $ARGV[0]) or die; print $f $$; close $f; $SIG{TERM} = "IGNORE"; sleep 39' "$pid_file" > /dev/null 2>&1 3>&- &
        fi
        runner_pid=$!
        ticks=0
        while [[ ! -s "$pid_file" && $ticks -lt 50 ]]; do
            sleep 0.1
            ticks=$((ticks + 1))
        done
        cmd_pid=$(cat "$pid_file")
        [[ "$cmd_pid" =~ ^[0-9]+$ ]] || { echo "NO_PID:$mode"; return 1; }
        kill -INT "$runner_pid"
        if [[ "$mode" == double-interrupt ]]; then
            sleep 0.5
            kill -INT "$runner_pid" 2> /dev/null || true
        fi
        ticks=0
        while kill -0 "$cmd_pid" 2> /dev/null && [[ $ticks -lt 40 ]]; do
            sleep 0.1
            ticks=$((ticks + 1))
        done
        if kill -0 "$cmd_pid" 2> /dev/null; then
            kill -KILL "$cmd_pid" 2> /dev/null || true
            echo "ORPHANED:$mode"
            return 1
        fi
        wait "$runner_pid" 2> /dev/null || true
        [[ "$(cat "$rc_file" 2> /dev/null)" == 130 ]] || { echo "RC:$mode:$(cat "$rc_file" 2> /dev/null)"; return 1; }
    done
}

@test "run_with_timeout shell fallback traps INT before the command starts" {
    # A Ctrl-C between the command's start and the trap took bash's default
    # exit and left the command, which ignores INT in the background, running
    # until the killer's deadline (CI 2026-11-04, ORPHANED:plain above). The
    # shim waits for the command's marker when the INT trap is set: present
    # means the command started first.
    run env PROJECT_ROOT="${BATS_TEST_DIRNAME}/.." MARKER="$HOME/started-before-trap" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
MO_TIMEOUT_BIN="" MO_TIMEOUT_PERL_BIN=""
rm -f "$MARKER" # SAFE: test-owned scratch file
trap() {
    if [[ "${1:-}" != "-p" && "${1:-}" != "-" && "${*: -1}" == "INT" && -z "${TRAP_SEEN:-}" ]]; then
        TRAP_SEEN=1
        local ticks=0
        while [[ ! -e "$MARKER" && $ticks -lt 20 ]]; do
            sleep 0.05
            ticks=$((ticks + 1))
        done
        if [[ -e "$MARKER" ]]; then echo "ORDER=command-first"; else echo "ORDER=trap-first"; fi
    fi
    builtin trap "$@"
}
run_with_timeout 5 /bin/sh -c 'touch "$1"' sh "$MARKER"
echo "RC=$?"
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"ORDER=trap-first"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"RC=0"* ]] || { echo "$output"; return 1; }
}

@test "run_with_timeout shell fallback never starts a command after an early interrupt" {
    # The shim delivers Ctrl-C the moment the INT trap is in place, before the
    # command is forked. The command must not run at all, the caller's own INT
    # trap must come back, and the call must return 130 at once.
    run env PROJECT_ROOT="${BATS_TEST_DIRNAME}/.." MARKER="$HOME/started-after-interrupt" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
MO_TIMEOUT_BIN="" MO_TIMEOUT_PERL_BIN=""
rm -f "$MARKER" # SAFE: test-owned scratch file
builtin trap 'echo CALLER_TRAP' INT
# An ignored TERM is inherited across fork and exec, so a command that was
# started at all leaves its marker instead of dying to the follow-up TERM.
builtin trap '' TERM
trap() {
    builtin trap "$@"
    if [[ "${1:-}" != "-p" && "${1:-}" != "-" && "${*: -1}" == "INT" && -z "${INT_SENT:-}" ]]; then
        INT_SENT=1
        kill -INT $$
    fi
}
start=$SECONDS
rc=0
run_with_timeout 10 /bin/sh -c 'touch "$1"; exec /bin/sleep 8' sh "$MARKER" || rc=$?
echo "RC=$rc ELAPSED=$((SECONDS - start))"
sleep 0.3
[[ -e "$MARKER" ]] && echo "COMMAND_STARTED"
builtin trap -p INT
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"RC=130 ELAPSED="[0-2]* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"COMMAND_STARTED"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"echo CALLER_TRAP"* ]] || { echo "$output"; return 1; }
}

@test "run_with_timeout shell fallback leaves the caller's errexit as it was" {
    run env PROJECT_ROOT="${BATS_TEST_DIRNAME}/.." /bin/bash --noprofile --norc << 'EOF'
source "$PROJECT_ROOT/lib/core/common.sh"
MO_TIMEOUT_BIN="" MO_TIMEOUT_PERL_BIN=""
set +e
rc=0
run_with_timeout 5 /bin/sh -c 'exit 3' || rc=$?
[[ $- == *e* ]] && echo "ERREXIT_ON" || echo "ERREXIT_OFF"
echo "RC_OFF=$rc"
set -e
rc=0
run_with_timeout 5 /bin/sh -c 'exit 3' || rc=$?
[[ $- == *e* ]] && echo "ERREXIT_ON" || echo "ERREXIT_OFF"
echo "RC_ON=$rc"
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"ERREXIT_OFF"$'\n'"RC_OFF=3"$'\n'"ERREXIT_ON"$'\n'"RC_ON=3"* ]] || { echo "$output"; return 1; }
}

@test "run_with_timeout passes the caller's stdin through every backend" {
    # The simulator metadata check feeds awk and the Finder and login item
    # paths feed osascript through stdin; the shell backend used to hand them
    # /dev/null, which read every simulator as running.
    mkdir -p "$HOME/fake-timeout"
    cat > "$HOME/fake-timeout/timeout" <<'SCRIPT'
#!/bin/bash
shift 3
exec "$@"
SCRIPT
    chmod +x "$HOME/fake-timeout/timeout"
    run env HOME="$HOME" PROJECT_ROOT="${BATS_TEST_DIRNAME}/.." FAKE_TIMEOUT="$HOME/fake-timeout/timeout" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
for backend in binary perl shell; do
    case "$backend" in
        binary) MO_TIMEOUT_BIN="$FAKE_TIMEOUT" MO_TIMEOUT_PERL_BIN="" ;;
        perl) MO_TIMEOUT_BIN="" MO_TIMEOUT_PERL_BIN="$(command -v perl)" ;;
        shell) MO_TIMEOUT_BIN="" MO_TIMEOUT_PERL_BIN="" ;;
    esac
    out=$(run_with_timeout 5 /usr/bin/awk '{ print "GOT:" $0 }' <<< "hello")
    [[ "$out" == "GOT:hello" ]] || { printf 'HERESTRING:%s:%s\n' "$backend" "$out"; exit 1; }
    out=$(run_with_timeout 5 /bin/cat << 'DOC'
line one
line two
DOC
    )
    [[ "$out" == $'line one\nline two' ]] || { printf 'HEREDOC:%s:%s\n' "$backend" "$out"; exit 1; }
done
echo CLEAN
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *CLEAN* ]] || { echo "$output"; return 1; }
}

# Sources timeout.sh with only the fake directory ahead of the system paths and
# prints the backend it picked, then the status of a one-second timeout.
_probe_timeout_backend() {
    local fake_dir="$1"
    # shellcheck disable=SC2016 # The child shell expands its own positional parameters.
    run /bin/bash -c '
        set -euo pipefail
        unset MO_TIMEOUT_INITIALIZED MO_TIMEOUT_BIN MO_TIMEOUT_PERL_BIN
        export PATH="$2:/usr/bin:/bin"
        source "$1/lib/core/timeout.sh"
        printf "bin=%s\n" "$MO_TIMEOUT_BIN"
        rc=0
        run_with_timeout 1 /bin/sleep 5 || rc=$?
        printf "rc=%s\n" "$rc"
    ' bash "${BATS_TEST_DIRNAME}/.." "$fake_dir" < /dev/null
}

@test "timeout.sh skips a PATH timeout shim that reports its deadline as 143" {
    local fake_dir="$BATS_TEST_TMPDIR/fake-timeout-143"
    mkdir -p "$fake_dir"
    # Kills the command on its deadline and exits with the child's status, as
    # a hand-written shim does, instead of the 124 every caller relies on.
    cat > "$fake_dir/timeout" << 'SHIM'
#!/bin/bash
shift
"$@" &
pid=$!
(/bin/sleep 0.2; kill -TERM "$pid" 2> /dev/null) &
wait "$pid"
exit $?
SHIM
    chmod +x "$fake_dir/timeout"

    _probe_timeout_backend "$fake_dir"
    [ "$status" -eq 0 ]
    [[ "$output" != *"bin=$fake_dir/timeout"* ]] || return 1
    [[ "$output" == *"rc=124"* ]]
}

@test "timeout.sh skips a PATH timeout shim that rejects fractional durations" {
    local fake_dir="$BATS_TEST_TMPDIR/fake-timeout-125"
    mkdir -p "$fake_dir"
    cat > "$fake_dir/timeout" << 'SHIM'
#!/bin/bash
[[ "$1" =~ ^[0-9]+$ ]] || exit 125
exec /usr/bin/perl -e 'alarm shift; exec @ARGV' "$@"
SHIM
    chmod +x "$fake_dir/timeout"

    _probe_timeout_backend "$fake_dir"
    [ "$status" -eq 0 ]
    [[ "$output" != *"bin=$fake_dir/timeout"* ]] || return 1
    [[ "$output" == *"rc=124"* ]]
}

@test "timeout.sh keeps a PATH timeout that reports its deadline as 124" {
    local fake_dir="$BATS_TEST_TMPDIR/fake-timeout-124"
    mkdir -p "$fake_dir"
    cat > "$fake_dir/timeout" << 'SHIM'
#!/bin/bash
shift
"$@" &
pid=$!
(/bin/sleep 0.2; kill -TERM "$pid" 2> /dev/null) &
wait "$pid" && exit 0
exit 124
SHIM
    chmod +x "$fake_dir/timeout"

    _probe_timeout_backend "$fake_dir"
    [ "$status" -eq 0 ]
    [[ "$output" == *"bin=$fake_dir/timeout"* ]] || return 1
    [[ "$output" == *"rc=124"* ]]
}
