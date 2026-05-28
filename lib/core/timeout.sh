#!/bin/bash
# Roomy - Timeout Control
# Command execution with timeout support

set -euo pipefail

# Prevent multiple sourcing
if [[ -n "${ROOMY_TIMEOUT_LOADED:-}" ]]; then
    return 0
fi
readonly ROOMY_TIMEOUT_LOADED=1

# ============================================================================
# Timeout Command Initialization
# ============================================================================

# Initialize timeout command (prefer gtimeout from coreutils, fallback to timeout)
# Sets ROOMY_TIMEOUT_BIN to the available timeout command
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
if [[ -z "${ROOMY_TIMEOUT_INITIALIZED:-}" ]]; then
    ROOMY_TIMEOUT_BIN=""
    ROOMY_TIMEOUT_PERL_BIN=""
    for candidate in gtimeout timeout; do
        if command -v "$candidate" > /dev/null 2>&1; then
            ROOMY_TIMEOUT_BIN="$(command -v "$candidate")"
            if [[ "${ROOMY_DEBUG:-0}" == "1" ]]; then
                echo "[TIMEOUT] Using command: $ROOMY_TIMEOUT_BIN" >&2
            fi
            break
        fi
    done

    if command -v perl > /dev/null 2>&1; then
        ROOMY_TIMEOUT_PERL_BIN="$(command -v perl)"
        if [[ -z "$ROOMY_TIMEOUT_BIN" ]] && [[ "${ROOMY_DEBUG:-0}" == "1" ]]; then
            echo "[TIMEOUT] Using perl fallback: $ROOMY_TIMEOUT_PERL_BIN" >&2
        fi
    fi

    # Log warning if no timeout command available
    if [[ -z "$ROOMY_TIMEOUT_BIN" && -z "$ROOMY_TIMEOUT_PERL_BIN" ]] && [[ "${ROOMY_DEBUG:-0}" == "1" ]]; then
        echo "[TIMEOUT] No timeout command found, using shell fallback" >&2
        echo "[TIMEOUT] Install coreutils for better reliability: brew install coreutils" >&2
    fi

    # Export so child processes inherit detected values and skip re-detection.
    # Without this, children that inherit ROOMY_TIMEOUT_INITIALIZED=1 skip the init
    # block but have empty bin vars, forcing the slow shell fallback.
    export ROOMY_TIMEOUT_BIN
    export ROOMY_TIMEOUT_PERL_BIN
    export ROOMY_TIMEOUT_INITIALIZED=1
fi

# ============================================================================
# Timeout Execution
# ============================================================================

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
#   ROOMY_DEBUG - Set to 1 to enable debug logging to stderr
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
run_with_timeout() {
    local duration="${1:-0}"
    shift || true

    # No timeout if duration is invalid or zero
    if [[ ! "$duration" =~ ^[0-9]+(\.[0-9]+)?$ ]] || [[ $(echo "$duration <= 0" | bc -l 2> /dev/null) -eq 1 ]]; then
        "$@"
        return $?
    fi

    # Use timeout command if available (preferred path)
    if [[ -n "${ROOMY_TIMEOUT_BIN:-}" ]]; then
        local timeout_bin="$ROOMY_TIMEOUT_BIN"
        if [[ "$timeout_bin" != */* ]]; then
            timeout_bin=$(command -v "$timeout_bin" 2> /dev/null || true)
        fi
        if [[ -z "$timeout_bin" || ! -x "$timeout_bin" ]]; then
            timeout_bin=""
        fi
    fi
    if [[ -n "${timeout_bin:-}" ]]; then
        if [[ "${ROOMY_DEBUG:-0}" == "1" ]]; then
            echo "[TIMEOUT] Running with ${duration}s timeout: $*" >&2
        fi
        "$timeout_bin" "$duration" "$@"
        return $?
    fi

    # Use perl helper when timeout command is unavailable.
    if [[ -n "${ROOMY_TIMEOUT_PERL_BIN:-}" ]]; then
        if [[ "${ROOMY_DEBUG:-0}" == "1" ]]; then
            echo "[TIMEOUT] Perl fallback, ${duration}s: $*" >&2
        fi
        # shellcheck disable=SC2016  # Embedded Perl uses Perl variables inside single quotes.
        "$ROOMY_TIMEOUT_PERL_BIN" -e '
            use strict;
            use warnings;
            use POSIX qw(:sys_wait_h setsid);
            use Time::HiRes qw(time sleep);

            my $duration = 0 + shift @ARGV;
            $duration = 1 if $duration <= 0;

            my $pid = fork();
            defined $pid or exit 125;

            if ($pid == 0) {
                setsid() or exit 125;
                exec @ARGV;
                exit 127;
            }

            my $deadline = time() + $duration;

            while (1) {
                my $result = waitpid($pid, WNOHANG);
                if ($result == $pid) {
                    if (WIFEXITED($?)) {
                        exit WEXITSTATUS($?);
                    }
                    if (WIFSIGNALED($?)) {
                        exit 128 + WTERMSIG($?);
                    }
                    exit 1;
                }

                if (time() >= $deadline) {
                    kill "TERM", -$pid;
                    sleep 0.5;

                    for (1 .. 6) {
                        $result = waitpid($pid, WNOHANG);
                        if ($result == $pid) {
                            exit 124;
                        }
                        sleep 0.25;
                    }

                    kill "KILL", -$pid;
                    waitpid($pid, 0);
                    exit 124;
                }

                sleep 0.1;
            }
        ' "$duration" "$@"
        return $?
    fi

    # ========================================================================
    # Shell-based fallback implementation
    # ========================================================================

    if [[ "${ROOMY_DEBUG:-0}" == "1" ]]; then
        echo "[TIMEOUT] Shell fallback, ${duration}s: $*" >&2
    fi

    # Start command in background
    "$@" &
    local cmd_pid=$!

    # Start timeout killer in background.
    # Redirect all FDs to /dev/null so orphaned child processes (e.g. sleep $duration)
    # do not inherit open file descriptors from the caller and block output pipes
    # (notably bats output capture pipes that wait for all writers to close).
    (
        sleep_pid=""
        trap 'if [[ -n "${sleep_pid:-}" ]]; then kill "$sleep_pid" 2>/dev/null || true; fi; exit 0' TERM INT

        # Wait for timeout duration
        sleep "$duration" &
        sleep_pid=$!
        wait "$sleep_pid" 2> /dev/null || exit 0
        sleep_pid=""

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

    # Forward SIGINT to the command while preserving the caller's trap.
    trap 'interrupted=1; kill -INT "$cmd_pid" 2>/dev/null || true; kill "$killer_pid" 2>/dev/null || true' INT

    # Wait for command to complete
    local exit_code=0
    set +e
    wait "$cmd_pid" 2> /dev/null
    exit_code=$?
    set -e

    if [[ -n "$previous_int_trap" ]]; then
        eval "$previous_int_trap"
    else
        trap - INT
    fi

    # Clean up killer process
    if kill -0 "$killer_pid" 2> /dev/null; then
        kill "$killer_pid" 2> /dev/null || true
        wait "$killer_pid" 2> /dev/null || true
    fi

    if [[ $interrupted -eq 1 ]]; then
        return 130
    fi

    # Check if command was killed by timeout (exit codes 143=SIGTERM, 137=SIGKILL)
    if [[ $exit_code -eq 143 || $exit_code -eq 137 ]]; then
        # Command was killed by timeout
        if [[ "${ROOMY_DEBUG:-0}" == "1" ]]; then
            echo "[TIMEOUT] Command timed out after ${duration}s" >&2
        fi
        return 124
    fi

    # Command completed normally (or with its own error)
    return "$exit_code"
}
