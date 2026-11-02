#!/bin/bash
# Mole - Timeout Control
# Command execution with timeout support

set -euo pipefail

# Prevent multiple sourcing
if [[ -n "${MOLE_TIMEOUT_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_TIMEOUT_LOADED=1

# ============================================================================
# Timeout Command Initialization
# ============================================================================

# Initialize timeout command (prefer gtimeout from coreutils, fallback to timeout)
# Sets MO_TIMEOUT_BIN to the available timeout command
#
# Recommendation: Install coreutils for reliable timeout support
#   brew install coreutils
#
# Fallback order:
#   1. gtimeout / timeout
#   2. perl helper with dedicated process group cleanup
#   3. shell-based fallback (last resort)
#
# The shell-based fallback has known limitations:
#   - May not clean up all child processes
#   - Has race conditions in edge cases
#   - Less reliable than native timeout/perl helper
if [[ -z "${MO_TIMEOUT_INITIALIZED:-}" ]]; then
    MO_TIMEOUT_BIN=""
    MO_TIMEOUT_PERL_BIN=""
    for candidate in gtimeout timeout; do
        if command -v "$candidate" > /dev/null 2>&1; then
            MO_TIMEOUT_BIN="$(command -v "$candidate")"
            if [[ "${MO_DEBUG:-0}" == "1" ]]; then
                echo "[TIMEOUT] Using command: $MO_TIMEOUT_BIN" >&2
            fi
            break
        fi
    done

    if command -v perl > /dev/null 2>&1; then
        MO_TIMEOUT_PERL_BIN="$(command -v perl)"
        if [[ -z "$MO_TIMEOUT_BIN" ]] && [[ "${MO_DEBUG:-0}" == "1" ]]; then
            echo "[TIMEOUT] Using perl fallback: $MO_TIMEOUT_PERL_BIN" >&2
        fi
    fi

    # Log warning if no timeout command available
    if [[ -z "$MO_TIMEOUT_BIN" && -z "$MO_TIMEOUT_PERL_BIN" ]] && [[ "${MO_DEBUG:-0}" == "1" ]]; then
        echo "[TIMEOUT] No timeout command found, using shell fallback" >&2
        echo "[TIMEOUT] Install coreutils for better reliability: brew install coreutils" >&2
    fi

    # Export so child processes inherit detected values and skip re-detection.
    # Without this, children that inherit MO_TIMEOUT_INITIALIZED=1 skip the init
    # block but have empty bin vars, forcing the slow shell fallback.
    export MO_TIMEOUT_BIN
    export MO_TIMEOUT_PERL_BIN
    export MO_TIMEOUT_INITIALIZED=1
fi

# ============================================================================
# Timeout Execution
# ============================================================================

# run_with_timeout reports 124 when the command timed out and 128+N when a
# signal killed it (Ctrl-C included). Whether a timeout stops the whole run or
# only skips one item is each caller's contract (bugs reference, section 15);
# these two predicates name the question so no caller spells the numbers again.
# scripts/audit_timeout_status.py rejects raw 124 comparisons outside this file.
mole_rc_timeout() {
    [[ "${1:-0}" -eq 124 ]]
}

mole_rc_timeout_or_signal() {
    [[ "${1:-0}" -eq 124 || "${1:-0}" -ge 128 ]]
}

# A mutating owner command may also exit with an errno-derived status such as
# npm's 243, which is an ordinary failure. Only a status that names a real
# signal means the user interrupted it; a timeout is not one.
mole_rc_signal() {
    [[ "${1:-0}" -ge 128 ]] && kill -l "$1" > /dev/null 2>&1
}

_mole_cleanup_timeout_killer() {
    local killer_pid="${1:-}"
    [[ "$killer_pid" =~ ^[0-9]+$ ]] || return 0

    local child_pids=""
    if command -v pgrep > /dev/null 2>&1; then
        child_pids=$(pgrep -P "$killer_pid" 2> /dev/null || true)
    fi

    kill "$killer_pid" 2> /dev/null || true

    if [[ -n "$child_pids" ]]; then
        local child_pid
        while IFS= read -r child_pid; do
            [[ "$child_pid" =~ ^[0-9]+$ ]] || continue
            kill "$child_pid" 2> /dev/null || true
        done <<< "$child_pids"
    fi

    wait "$killer_pid" 2> /dev/null || true
}

# Return success when Mole's process group still owns the controlling terminal.
# Checking this before a prompt avoids SIGTTIN if a nested interactive command
# returned the tty to Mole's parent shell instead of restoring it to Mole.
mole_tty_is_foreground() {
    # Non-terminal input cannot trigger SIGTTIN; preserve scripted/test flows.
    [[ -t 0 ]] || return 0

    local perl_bin="${MO_TIMEOUT_PERL_BIN:-}"
    if [[ -z "$perl_bin" || ! -x "$perl_bin" ]]; then
        perl_bin=$(command -v perl 2> /dev/null || true)
    fi
    [[ -n "$perl_bin" && -x "$perl_bin" ]] || return 0

    # shellcheck disable=SC2016 # Embedded Perl variables are intentionally single-quoted.
    "$perl_bin" -MPOSIX=tcgetpgrp -e '
        my $foreground_pgrp = tcgetpgrp(fileno(STDIN));
        my $current_pgrp = getpgrp();
        exit((defined($foreground_pgrp) && $foreground_pgrp >= 0 &&
            $foreground_pgrp == $current_pgrp) ? 0 : 1);
    ' 2> /dev/null
}

# Run command with timeout
# Uses gtimeout/timeout if available, falls back to shell-based implementation
#
# Args:
#   $1 - duration in seconds (0 or invalid = no timeout)
#   $@ - command and arguments to execute
#
# Returns:
#   Command exit code, or 124 if timed out (matches gtimeout behavior)
#
# Environment:
#   MO_DEBUG - Set to 1 to enable debug logging to stderr
#
# Implementation notes:
#   - Prefers gtimeout (coreutils) or timeout for reliability
#   - Shell fallback uses SIGTERM → SIGKILL escalation
#   - Attempts process group cleanup to handle child processes
#   - Returns exit code 124 on timeout (standard timeout exit code)
#
# Known limitations of shell-based fallback:
#   - Race condition: If command exits during signal delivery, the signal
#     may target a reused PID (very rare, requires quick PID reuse)
#   - Zombie processes: Brief zombies until wait completes
#   - Nested children: SIGKILL may not reach all descendants
#   - No process group: Cannot guarantee cleanup of detached children
#
# For mission-critical timeouts, install coreutils.
# A caller that captures `cmd 2>&1` and parses it (lsof, ps, codesign) must
# not read this wrapper's own notice as command output: under --debug, purge
# took the line for an lsof warning and kept every node_modules as unverified.
# The notice reaches stderr only on a terminal and always lands in the debug log.
_mole_timeout_debug() {
    if [[ -t 2 ]]; then
        echo "$1" >&2
    fi
    if [[ -n "${DEBUG_LOG_FILE:-}" ]] && declare -f append_log_line > /dev/null 2>&1; then
        # An unwritable log reports through the caller's stderr before the
        # inner `2> /dev/null` applies, which is the capture this avoids.
        { append_log_line "$DEBUG_LOG_FILE" "$1"; } 2> /dev/null || true
    fi
    return 0
}

run_with_timeout() {
    local duration="${1:-0}"
    shift || true

    # No timeout if duration is invalid or zero. The regex already forbids a
    # leading sign, so "<= 0" reduces to "is zero"; match that in pure bash
    # rather than shelling out to bc, which is not guaranteed on macOS.
    if [[ ! "$duration" =~ ^[0-9]+(\.[0-9]+)?$ ]] || [[ "$duration" =~ ^0+(\.0+)?$ ]]; then
        "$@"
        return $?
    fi

    # Use timeout command if available (preferred path)
    #
    # This backend has no owner-death detection, unlike the perl fallback below,
    # and that asymmetry is deliberate. Measured on macOS with coreutils
    # gtimeout: SIGKILLing the calling worker leaves gtimeout and its child
    # alive, but both still die when gtimeout's own deadline fires, so the orphan
    # window is capped by the caller's timeout budget (2-30s here) rather than
    # unbounded. gtimeout runs in its own process group, so Ctrl-C does not
    # reach it and the shell defers its INT trap until gtimeout returns; `-k 2`
    # keeps that return bounded when the command ignores TERM, matching the
    # perl backend's grace period (#1787). Closing the remaining SIGKILL gap would mean
    # either routing every non-TTY run through perl, which is every CI run and
    # every piped run, or backgrounding the backend and polling it, which
    # reopens the terminal-handoff class behind #1222/#1218. Neither is worth a
    # window the deadline already bounds.
    if [[ -n "${MO_TIMEOUT_BIN:-}" ]]; then
        local timeout_bin="$MO_TIMEOUT_BIN"
        if [[ "$timeout_bin" != */* ]]; then
            timeout_bin=$(command -v "$timeout_bin" 2> /dev/null || true)
        fi
        if [[ -z "$timeout_bin" || ! -x "$timeout_bin" ]]; then
            timeout_bin=""
        fi
    fi
    if [[ -n "${timeout_bin:-}" ]]; then
        if [[ "${MO_DEBUG:-0}" == "1" ]]; then
            _mole_timeout_debug "[TIMEOUT] Running with ${duration}s timeout: $*"
        fi
        local timeout_rc=0 timeout_started=$SECONDS timeout_kill_after=2
        local timeout_whole_seconds="${duration%.*}"
        # The -k escalation kills gtimeout's own process group, so bash would
        # print "Killed: 9"; the command keeps its stderr on fd 3 while that
        # shell notice goes to /dev/null.
        { "$timeout_bin" -k "$timeout_kill_after" "$duration" "$@" 2>&3 3>&-; } 3>&2 2> /dev/null || timeout_rc=$?
        # Escalation cannot exit 137 before the deadline plus its kill grace.
        # SECONDS rounds to whole seconds: including the grace keeps an early
        # SIGKILL distinct even for fractional budgets, without another clock
        # subprocess on every probe. Normalize leading zeroes as decimal.
        if [[ $timeout_rc -eq 137 && $((SECONDS - timeout_started)) -ge $((10#$timeout_whole_seconds + timeout_kill_after)) ]]; then
            return 124
        fi
        return "$timeout_rc"
    fi

    # Use perl helper when timeout command is unavailable.
    if [[ -n "${MO_TIMEOUT_PERL_BIN:-}" ]]; then
        if [[ "${MO_DEBUG:-0}" == "1" ]]; then
            _mole_timeout_debug "[TIMEOUT] Perl fallback, ${duration}s: $*"
        fi
        # shellcheck disable=SC2016  # Embedded Perl uses Perl variables inside single quotes.
        "$MO_TIMEOUT_PERL_BIN" -e '
            use strict;
            use warnings;
            use POSIX qw(:sys_wait_h setpgid tcgetpgrp tcsetpgrp);
            use Time::HiRes qw(time sleep);

            my $duration = 0 + shift @ARGV;
            $duration = 1 if $duration <= 0;
            my $caller_pid = getppid();

            # Only the process group that currently owns the terminal may hand it
            # to a child. Mole runs these helpers concurrently inside one process
            # group (parallel scan workers), so a helper that started while a
            # sibling held the terminal would capture the sibling child as the
            # "original" owner and later restore the terminal to that already
            # dead process group. Mole then no longer owns the terminal and the
            # next prompt read stops on SIGTTIN (issue #1222/#1218).
            my $my_pgrp = getpgrp();
            my $tty_fd = -t STDIN ? fileno(STDIN) : undef;
            my $original_pgrp;
            if (defined $tty_fd) {
                $original_pgrp = tcgetpgrp($tty_fd);
                undef $original_pgrp
                    if !defined $original_pgrp
                    || $original_pgrp < 0
                    || $original_pgrp != $my_pgrp;
            }

            my $pid = fork();
            defined $pid or exit 125;

            if ($pid == 0) {
                # New process group, NOT a new session: keep the controlling
                # terminal so nested sudo inside the wrapped command can reuse
                # the cached credential. setsid() would detach the tty and break
                # brew cask uninstall scripts that call sudo (issue #1003).
                # setpgid returns 0 on success (falsy in Perl), so it must not be
                # guarded with `or exit`; a rare failure only degrades group-kill.
                setpgid(0, 0);
                exec @ARGV;
                exit 127;
            }

            # Perl defers these handlers until a safe point. Record the desired
            # exit status here and let the normal wait loop terminate and reap
            # the whole timed process group.
            my $shutdown_status = 0;
            $SIG{INT} = sub { $shutdown_status ||= 130; };
            $SIG{TERM} = sub { $shutdown_status ||= 143; };
            $SIG{HUP} = sub { $shutdown_status ||= 129; };
            # Wakes the poll sleep on child exit. Not "IGNORE": that changes reaping.
            $SIG{CHLD} = sub { };

            # The child is a separate process group so timeout cleanup can kill
            # its descendants. A tty only permits its foreground process group
            # to read, however, so hand the terminal to the child while it runs.
            # Without this, nested sudo prints Password: and then stops on
            # SIGTTIN until the timeout expires (issue #1201).
            setpgid($pid, $pid);
            my $tty_handed_off = 0;
            if (defined $tty_fd && defined $original_pgrp) {
                local $SIG{TTOU} = "IGNORE";
                $tty_handed_off = tcsetpgrp($tty_fd, $pid) == 0 ? 1 : 0;
                kill "CONT", -$pid if $tty_handed_off;
            }

            my $restore_tty = sub {
                return unless $tty_handed_off && defined $tty_fd && defined $original_pgrp;
                $tty_handed_off = 0;
                # Give the terminal back only while our own child still owns it.
                # If something else took over meanwhile, restoring would revoke
                # the current owner instead.
                my $owner = tcgetpgrp($tty_fd);
                return unless defined $owner && $owner == $pid;
                local $SIG{TTOU} = "IGNORE";
                tcsetpgrp($tty_fd, $original_pgrp);
            };

            my $terminate_child = sub {
                my $sent = kill "TERM", -$pid;
                kill "TERM", $pid unless $sent;

                my $grace_deadline = time() + 2;
                while (time() < $grace_deadline) {
                    my $result = waitpid($pid, WNOHANG);
                    return if $result == $pid || $result == -1;
                    sleep 0.1;
                }

                $sent = kill "KILL", -$pid;
                kill "KILL", $pid unless $sent;
                waitpid($pid, 0);
            };

            my $deadline = time() + $duration;
            # Short metadata probes should not each pay a 100ms polling wait.
            # Back off to the existing cadence for long-running commands.
            my $poll_interval = 0.01;

            while (1) {
                my $result = waitpid($pid, WNOHANG);
                if ($result == $pid) {
                    my $status = $?;
                    $restore_tty->();
                    if (WIFEXITED($status)) {
                        exit WEXITSTATUS($status);
                    }
                    if (WIFSIGNALED($status)) {
                        exit 128 + WTERMSIG($status);
                    }
                    exit 1;
                }

                # A background shell worker can be killed without forwarding
                # TERM to this Perl child. Detect reparenting so the timed
                # command never outlives the worker that owned its deadline.
                if ($shutdown_status || getppid() != $caller_pid) {
                    my $status = $shutdown_status || 143;
                    $terminate_child->();
                    $restore_tty->();
                    exit $status;
                }

                if (time() >= $deadline) {
                    $terminate_child->();
                    $restore_tty->();
                    exit 124;
                }

                sleep $poll_interval;
                $poll_interval *= 2;
                $poll_interval = 0.1 if $poll_interval > 0.1;
            }
        ' "$duration" "$@"
        return $?
    fi

    # ========================================================================
    # Shell-based fallback implementation
    # ========================================================================

    if [[ "${MO_DEBUG:-0}" == "1" ]]; then
        _mole_timeout_debug "[TIMEOUT] Shell fallback, ${duration}s: $*"
    fi

    # Start command in background. Without job control bash gives a background
    # command /dev/null as stdin, so pass the caller's stdin on explicitly, as
    # the timeout binary and perl backends do: callers feed osascript and awk
    # through a here-document.
    "$@" <&0 &
    local cmd_pid=$!

    # Start timeout killer in background.
    # Redirect all FDs to /dev/null so orphaned child processes (e.g. sleep $duration)
    # do not inherit open file descriptors from the caller and block output pipes
    # (notably bats output capture pipes that wait for all writers to close).
    (
        # Wait for timeout duration
        sleep "$duration"

        # Check if process still exists
        if kill -0 "$cmd_pid" 2> /dev/null; then
            # Try to kill process group first (negative PID), fallback to single process
            # Process group kill is best effort - may not work if setsid was used
            kill -TERM -"$cmd_pid" 2> /dev/null || kill -TERM "$cmd_pid" 2> /dev/null || true

            # Grace period for clean shutdown
            sleep 2

            # Escalate to SIGKILL if still alive
            if kill -0 "$cmd_pid" 2> /dev/null; then
                kill -KILL -"$cmd_pid" 2> /dev/null || kill -KILL "$cmd_pid" 2> /dev/null || true
            fi
        fi
    ) < /dev/null > /dev/null 2>&1 &
    local killer_pid=$!

    local interrupted=0
    local previous_int_trap
    previous_int_trap=$(trap -p INT || true)

    # Stop the command on SIGINT while preserving the caller's trap. A background
    # command ignores SIGINT when job control is off, so forwarding INT left it
    # running with no deadline once the killer was gone; send TERM, as the perl
    # backend does.
    trap 'interrupted=1; kill -TERM "$cmd_pid" 2>/dev/null || true; _mole_cleanup_timeout_killer "$killer_pid"' INT

    # Wait for command to complete
    local exit_code=0
    set +e
    wait "$cmd_pid" 2> /dev/null
    exit_code=$?
    set -e

    _mole_cleanup_timeout_killer "$killer_pid"

    if [[ $interrupted -eq 1 ]]; then
        # A command that ignores TERM gets the same two-second grace as the
        # timeout binary's -k 2 before SIGKILL. The caller's trap stays off
        # until then: its exit on a second Ctrl-C would skip the KILL.
        trap 'interrupted=1' INT
        local grace_ticks=0
        while kill -0 "$cmd_pid" 2> /dev/null && [[ $grace_ticks -lt 20 ]]; do
            sleep 0.1 || true
            grace_ticks=$((grace_ticks + 1))
        done
        if kill -0 "$cmd_pid" 2> /dev/null; then
            kill -KILL "$cmd_pid" 2> /dev/null || true
        fi
        wait "$cmd_pid" 2> /dev/null || true
    fi

    if [[ -n "$previous_int_trap" ]]; then
        # eval: restore previous trap captured by $(trap -p INT)
        eval "$previous_int_trap"
    else
        trap - INT
    fi

    if [[ $interrupted -eq 1 ]]; then
        return 130
    fi

    # Check if command was killed by timeout (exit codes 143=SIGTERM, 137=SIGKILL)
    if [[ $exit_code -eq 143 || $exit_code -eq 137 ]]; then
        # Command was killed by timeout
        if [[ "${MO_DEBUG:-0}" == "1" ]]; then
            _mole_timeout_debug "[TIMEOUT] Command timed out after ${duration}s"
        fi
        return 124
    fi

    # Command completed normally (or with its own error)
    return "$exit_code"
}
