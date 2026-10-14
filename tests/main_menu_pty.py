#!/usr/bin/env python3
"""Check terminal restoration after leaving the real main menu."""
import fcntl
import os
import pty
import re
import select
import shlex
import signal
import subprocess
import sys
import tempfile
import termios
import time
from pathlib import Path

root = Path(__file__).resolve().parents[1]


def check_exit(key):
    with tempfile.TemporaryDirectory(prefix="mole-menu-") as home:
        master, slave = pty.openpty()
        original = termios.tcgetattr(slave)
        env = dict(os.environ, HOME=home, TERM="xterm-256color",
                   MOLE_TEST_MODE="1", MOLE_SKIP_MAIN="1", MOLE_TEST_NO_AUTH="1",
                   TEST_ROOT=str(root))

        def own_terminal():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        child_script = 'source "$TEST_ROOT/mole"; interactive_main_menu'
        # Keep the controlling terminal alive after Bash exits so Darwin still
        # allows tcgetattr. The keeper must survive the same foreground Ctrl-C.
        keeper = (
            'import subprocess, time, signal; '
            'signal.signal(signal.SIGINT, lambda *args: None); '
            f'p = subprocess.run(["/bin/bash", "--noprofile", "--norc", "-c", {child_script!r}]); '
            'print("MENU_EXIT=" + str(p.returncode), flush=True); time.sleep(10)'
        )
        process = subprocess.Popen(
            [sys.executable, '-c', keeper],
            stdin=slave, stdout=slave, stderr=slave, env=env,
            preexec_fn=own_terminal)
        output = b''
        try:
            deadline = time.monotonic() + 10
            while b'Q Quit' not in output or termios.tcgetattr(slave)[3] & termios.ECHO:
                assert time.monotonic() < deadline, ('menu did not start reading', output)
                if select.select([master], [], [], .01)[0]:
                    output += os.read(master, 65536)
            os.write(master, key)
            deadline = time.monotonic() + 5
            while b'MENU_EXIT=' not in output and time.monotonic() < deadline:
                if select.select([master], [], [], .02)[0]:
                    output += os.read(master, 65536)
            assert b'MENU_EXIT=0' in output, ('exit failed', output[-3000:])
            restored = termios.tcgetattr(slave)
            # Darwin may set this transient input-reprocessing flag on reads.
            restored[3] &= ~getattr(termios, "PENDIN", 0)
            original[3] &= ~getattr(termios, "PENDIN", 0)
            assert restored == original, ('terminal settings changed', key, original, restored)
            print('PASS: main menu restores terminal after', repr(key))
        finally:
            if process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except PermissionError:
                    process.kill()
                process.wait(timeout=5)
            os.close(slave)
            os.close(master)


check_exit(b'q')
check_exit(b'\x03')


def instrument_router(needle, replacement):
    rewrite = (f"import sys; s=sys.stdin.read(); assert s.count({needle!r}) == 1; "
               f"print(s.replace({needle!r}, {replacement!r}))")
    return f'eval "$(declare -f run_mole_command | {shlex.quote(sys.executable)} -c {shlex.quote(rewrite)})"\n'


def notice_diagnostics(process, home, parent_signal, repeat_signal, keys, wait_marker, sent, repeated):
    details = {"parent_signal": str(parent_signal), "repeat_signal": str(repeat_signal),
               "keys": repr(keys), "wait_marker": repr(wait_marker),
               "sent": sent, "repeated": repeated, "fixture_pgid": process.pid}
    try:
        snapshot = subprocess.run(
            ["/bin/ps", "-axo", "pid=,ppid=,pgid=,state=,pcpu=,time=,comm="],
            capture_output=True, text=True, timeout=3, check=True)
        # Read no command arguments and publish only this fixture's process group.
        rows = [line for line in snapshot.stdout.splitlines()
                if len(line.split(None, 3)) >= 3 and line.split(None, 3)[2] == str(process.pid)]
        details["processes"] = "PID PPID PGID STATE PCPU TIME COMM\n" + "\n".join(rows)
    except (OSError, subprocess.SubprocessError) as error:
        details["processes"] = type(error).__name__
    trace = Path(home) / "router.trace"
    if trace.exists():
        with trace.open("rb") as stream:
            stream.seek(max(0, trace.stat().st_size - 16384))
            details["router_trace"] = stream.read(16384).decode(errors="replace")
    return details


def check_notice(script, expected_status=0, wait_marker=None, keys=b'', required=(), forbidden=(), parent_signal=None, repeat_signal=None, block_term=False):
    with tempfile.TemporaryDirectory(prefix="mole-update-terminal-") as home:
        master, slave = pty.openpty()
        env = dict(os.environ, HOME=home, TERM="xterm-256color", TEST_ROOT=str(root),
                   MOLE_TEST_MODE="1", MOLE_SKIP_MAIN="1", MOLE_TEST_NO_AUTH="1")
        child = 'source "$TEST_ROOT/mole"; mkdir -p "$HOME/.cache/mole"; ' + script
        inherited_mask = 'signal.pthread_sigmask(signal.SIG_BLOCK,{signal.SIGTERM}); ' if block_term else ''
        keeper = ('import subprocess,time,signal; signal.signal(signal.SIGINT,lambda *a:None); '
                  + inherited_mask
                  + f'p=subprocess.run(["/bin/bash","--noprofile","--norc","-c",{child!r}]); '
                  'print("CASE_EXIT="+str(p.returncode),flush=True); time.sleep(10)')

        def terminal():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        process = subprocess.Popen([sys.executable, '-c', keeper], stdin=slave,
                                   stdout=slave, stderr=slave, env=env, preexec_fn=terminal)
        output = b''
        sent = False
        repeated = False
        try:
            # Only hang detection: a loaded machine can delay sourcing mole and
            # the one-second child cleanup well past ten seconds.
            deadline = time.monotonic() + 30
            while b'CASE_EXIT=' not in output:
                if time.monotonic() >= deadline:
                    diagnostics = notice_diagnostics(process, home, parent_signal, repeat_signal,
                                                     keys, wait_marker, sent, repeated)
                    raise AssertionError(('terminal case timed out', diagnostics, output[-3000:]))
                if select.select([master], [], [], .02)[0]:
                    output += os.read(master, 65536)
                if wait_marker and wait_marker in output and not sent:
                    if parent_signal:
                        pid = int(re.search(rb'WRAPPER_PID=(\d+)', output).group(1))
                        os.kill(pid, parent_signal)
                    else:
                        os.write(master, keys)
                    sent = True
                if repeat_signal and b'CLEANUP_STARTED' in output and not repeated:
                    os.kill(int(re.search(rb'WRAPPER_PID=(\d+)', output).group(1)), repeat_signal)
                    repeated = True
            assert f'CASE_EXIT={expected_status}\r\n'.encode() in output, output[-3000:]
            for marker in required:
                assert marker in output, (marker, output[-3000:])
            for marker in forbidden:
                assert marker not in output, (marker, output[-3000:])
            return output
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
            os.close(slave)
            os.close(master)


# Use the actual asynchronous checker and actual key reader: no keypress should
# be needed before the delayed network result becomes visible.
check_notice('''
VERSION=1.0.0
get_install_channel(){ echo stable; }
is_homebrew_install(){ return 1; }
get_latest_version_from_github(){ sleep 1; echo 9.8.7; }
check_for_updates
interactive_main_menu
''', wait_marker=b'Update 9.8.7 available', keys=b'q', required=(b'U Update',))
print('PASS: idle menu refreshes a delayed update without a keypress')

setup = '''
check_for_updates(){ echo CHECK_CALLED; printf 'Update 9.8.7 available, run mo update' > "$HOME/.cache/mole/update_message"; }
SCRIPT_DIR="$HOME/commands"
mkdir -p "$SCRIPT_DIR/bin"
'''


def check_inherited_term_mask():
    # tty7's daemon blocks TERM and its panes inherit that mask. The real
    # interactive launcher must clear it before a child stops its spinner.
    check_notice(setup + r'''
cat > "$HOME/masked-term-child" <<'CHILD'
#!/bin/bash
set -euo pipefail
(
    trap 'exit 0' TERM
    : > "$HOME/spinner-ready"
    while :; do sleep 0.01; done
) &
spinner=$!
while [[ ! -e "$HOME/spinner-ready" ]]; do sleep 0.01; done
kill -TERM "$spinner"
wait "$spinner"
printf 'SPINNER_STOPPED\n'
CHILD
chmod +x "$HOME/masked-term-child"
run_mole_command "$HOME/masked-term-child"
''', block_term=True, required=(b'SPINNER_STOPPED',))


check_inherited_term_mask()
print('PASS: an inherited blocked TERM does not hang spinner shutdown')

for command in ['clean', 'optimize', 'uninstall', 'purge', 'installer', 'analyze', 'status']:
    script = setup + f'''
printf '#!/bin/bash\\nprintf "COMMAND_DONE\\\\n"\\nexit 7\\n' > "$SCRIPT_DIR/bin/{command}.sh"
chmod +x "$SCRIPT_DIR/bin/{command}.sh"
main {command}
'''
    output = check_notice(script, expected_status=7,
                          required=(b'CHECK_CALLED', b'COMMAND_DONE', b'Update 9.8.7 available'))
    assert output.index(b'COMMAND_DONE') < output.index(b'Update 9.8.7 available'), output
print('PASS: all seven interactive subcommands retain their status and show the notice after completion')

for flag in ['--json', '-json', '--json=true', '-json=true', '--ndjson', '--watch', '-watch', '--watch=true',
             '-watch=true', '--help', '-h', '--version', '-V', '--list', '--list=x']:
    check_notice(setup + f'''run_mole_command /bin/bash -c 'printf "JSON_OUTPUT\\n"' test {flag}''',
                 required=(b'JSON_OUTPUT',), forbidden=(b'CHECK_CALLED', b'Update 9.8.7'))
# Each of the three standard streams alone is enough to skip the notice. The
# all-terminal runs above are the positive control for CHECK_CALLED.
for redirect in ['> "$HOME/output"', '< /dev/null', '2> "$HOME/errors"']:
    check_notice(setup + f"""run_mole_command /bin/bash -c 'exit 0' {redirect}""",
                 forbidden=(b'CHECK_CALLED', b'Update 9.8.7'))
print('PASS: machine-readable flags, help, lists and any redirected stream stay silent')

check_notice(setup + '''run_mole_command /bin/bash -c 'trap "exit 130" INT; echo CHILD_READY; while :; do :; done' ''',
             expected_status=130, wait_marker=b'CHILD_READY', keys=b'\x03',
             forbidden=(b'Update 9.8.7',))
print('PASS: Ctrl-C preserves cancellation without printing an update notice')

# Trace only bounded router events, never the child's busy loop or PTY output.
router_trace = r"""
_fixture_router_trace_count=0
_fixture_trace_router() {
    [[ "$_fixture_router_trace_count" -lt 64 ]] || return 0
    _fixture_router_trace_count=$((_fixture_router_trace_count + 1))
    printf 'event=%s ready=%s pid=%s pending=%s generation=%s observed=%s interrupted=%s rc=%s\n' \
        "$1" "$command_ready" "$command_pid" "$pending_signal" "$signal_generation" \
        "$observed_generation" "$interrupted" "$rc" >> "$HOME/router.trace"
}
"""
router_trace += instrument_router('[[ "$command_ready" == "true" && -n "$command_pid" && -n "$pending_signal" ]]',
                                  '_fixture_trace_router before_flush; [[ "$command_ready" == "true" && -n "$command_pid" && -n "$pending_signal" ]]')
router_trace += instrument_router('observed_generation=$signal_generation;',
                                  'observed_generation=$signal_generation; _fixture_trace_router before_wait;')
router_trace += instrument_router('[[ "$observed_generation" -eq "$signal_generation" ]]',
                                  '_fixture_trace_router after_wait; [[ "$observed_generation" -eq "$signal_generation" ]]')

for sig in [signal.SIGHUP, signal.SIGINT, signal.SIGTERM]:
    check_notice(setup + router_trace + '''echo WRAPPER_PID=$$; run_mole_command /bin/bash -c 'trap "exit 130" INT; trap "exit 143" TERM; echo CHILD_READY; while :; do :; done' ''',
                 expected_status=128 + sig, wait_marker=b'CHILD_READY', parent_signal=sig,
                 forbidden=(b'Update 9.8.7',))
print('PASS: signals sent only to the router are forwarded to its child')
check_notice(setup + '''run_mole_command /bin/bash -c 'echo READ_READY; IFS= read -r text; echo GOT:$text' ''',
             wait_marker=b'READ_READY', keys=b'hello\n', required=(b'GOT:hello',))
print('PASS: interactive child keeps terminal stdin')

# The first signal fixes the status, whichever trap sees it and whichever signal
# follows; each pair would differ if one trap overwrote an earlier status.
for first, repeat in [(signal.SIGTERM, signal.SIGTERM), (signal.SIGTERM, signal.SIGINT), (signal.SIGTERM, signal.SIGHUP),
                      (signal.SIGINT, signal.SIGTERM), (signal.SIGHUP, signal.SIGTERM)]:
    output = check_notice(setup + """
cat > "$HOME/signal-child" <<'CHILD'
#!/bin/bash
cleanup() { trap '' TERM INT HUP; echo CLEANUP_STARTED; sleep 1; echo CLEANUP_DONE; exit 0; }
trap cleanup TERM INT HUP
echo CHILD_READY
while :; do :; done
CHILD
chmod +x "$HOME/signal-child"
echo WRAPPER_PID=$$
run_mole_command "$HOME/signal-child"
""",
                          expected_status=128 + first, wait_marker=b'CHILD_READY', parent_signal=first,
                          repeat_signal=repeat, required=(b'CLEANUP_DONE',), forbidden=(b'Update 9.8.7',))
    assert output.index(b'CLEANUP_DONE') < output.index(b'CASE_EXIT='), output
print('PASS: repeated signals preserve the first cancellation and wait for child cleanup')

# A target bash cannot launch keeps the diagnostic and status that a plain exec
# gives in the mole environment (the redirected-output path: 1, or 126 for a
# directory), instead of the perl wrapper's silent 127.
unlaunchable = setup + '''
printf '#!/bin/bash\\nexit 0\\n' > "$HOME/plain.sh"
chmod 644 "$HOME/plain.sh"
mkdir "$HOME/adir"
printf '#!/nonexistent/interp\\nexit 0\\n' > "$HOME/bad-interp.sh"
chmod 755 "$HOME/bad-interp.sh"
'''
for target, message, status in [('nope.sh', b'No such file or directory', 1), ('plain.sh', b'Permission denied', 1),
                                ('adir', b'is a directory', 126)]:
    check_notice(unlaunchable + f'run_mole_command "$HOME/{target}"', expected_status=status,
                 required=(message,), forbidden=(b'CHECK_CALLED', b'Update 9.8.7'))
# A #! line naming a missing interpreter is caught before the wrapper spawns
# anything, so bash names the interpreter ('bad interpreter') instead of the
# wrapper blaming the script, and no update check starts.
check_notice(unlaunchable + 'run_mole_command "$HOME/bad-interp.sh"', expected_status=1,
             required=(b'bad interpreter',), forbidden=(b'CHECK_CALLED', b'Update 9.8.7'))
print('PASS: an unlaunchable target keeps the diagnostic and status of a plain exec')

# Without /usr/bin/perl the command still runs through the plain exec path and
# only the notice is lost. The function text is rewritten to point at a missing
# perl, because the real one cannot be removed for a test.
check_notice(setup + """
eval "$(declare -f run_mole_command | sed 's|/usr/bin/perl|/nonexistent/perl|g')"
run_mole_command /bin/bash -c 'printf "COMMAND_DONE\\\\n"; exit 7'
""", expected_status=7, required=(b'COMMAND_DONE',), forbidden=(b'nonexistent', b'Update 9.8.7'))
print('PASS: a missing perl falls back to a plain exec with the command status')

# A child killed by a signal must not surface bash's job-status line, which
# quotes the internal perl one-liner; the status still reports the signal.
check_notice(setup + '''run_mole_command /bin/bash -c 'echo CHILD_READY; kill -KILL $$' ''',
             expected_status=137, required=(b'CHILD_READY',), forbidden=(b'perl', b'Killed', b'Update 9.8.7'))
print('PASS: a child killed by a signal keeps its status without bash job-status text')

# Bash prints that same job-status line from whichever command finishes first
# after the child is gone. Hold the router after the launch until the child has
# died, then run an external command in the same window: nothing there may
# reach the terminal, or a slow runner leaks the line at random (seen on CI).
after_launch = instrument_router('command_pid=$!',
                                 'command_pid=$!; local launch_deadline=$((SECONDS + 2)); '
                                 'while ((SECONDS < launch_deadline)); do :; done; /bin/echo > /dev/null')
check_notice(setup + after_launch + '''run_mole_command /bin/bash -c 'echo CHILD_READY; kill -KILL $$' ''',
             expected_status=137, required=(b'CHILD_READY',), forbidden=(b'perl', b'Killed', b'Update 9.8.7'))
print('PASS: a child that dies before the wait starts leaves no job-status line')

# Delivery counts for INT. A terminal Ctrl-C reaches the child from the tty and
# again from the router's forward, so one or two deliveries are expected there;
# a signal sent to the router alone must arrive exactly once. The count child
# keeps running after a delivery so a late duplicate is still counted.
counter = setup + """
cat > "$HOME/count-child" <<'CHILD'
#!/bin/bash
n=0
trap 'n=$((n+1))' INT
echo CHILD_READY
end=$((SECONDS + 2))
while ((SECONDS < end)); do :; done
echo "INT_COUNT=$n"
CHILD
chmod +x "$HOME/count-child"
echo WRAPPER_PID=$$
run_mole_command "$HOME/count-child"
"""


# A child can become ready before the router assigns its PID. Expand that
# scheduling window with builtins, which neither replace $! nor defer traps
# like a foreground sleep would. Both tty and router-only INT must survive.
launch_window = instrument_router('command_pid=$!',
                                  'local launch_deadline=$((SECONDS + 2)); while ((SECONDS < launch_deadline)); do :; done; command_pid=$!')
launch_counter = counter[len(setup):].replace("end=$((SECONDS + 2))", "end=$((SECONDS + 4))")
launch_counter = launch_counter.replace("trap 'n=$((n+1))' INT", "trap 'n=$((n+1))' INT HUP TERM")
for early_signal in [None, signal.SIGINT, signal.SIGHUP, signal.SIGTERM]:
    terminal_signal = early_signal is None
    output = check_notice(setup + launch_window + launch_counter,
                          expected_status=128 + (early_signal or signal.SIGINT), wait_marker=b'CHILD_READY',
                          keys=b'\x03' if terminal_signal else b'',
                          parent_signal=early_signal,
                          required=(b'INT_COUNT=',), forbidden=(b'Update 9.8.7',))
    count = re.search(rb'INT_COUNT=(\d+)', output)
    assert count and int(count.group(1)) in ([1, 2] if terminal_signal else [1]), output
print('PASS: cancellation survives the child-launch PID assignment window')

# An INT sent before Perl resets Bash's inherited SIG_IGN must be queued
# until the launcher is ready, not just reflected in the router's exit code.
before_reset = instrument_router('$SIG{INT}="DEFAULT";',
                                 '$|=1; print "BEFORE_RESET\\n"; select undef,undef,undef,1; $SIG{INT}="DEFAULT";')
early_child = """echo WRAPPER_PID=$$; run_mole_command /bin/bash -c 'trap "exit 130" INT; end=$((SECONDS+2)); while ((SECONDS<end)); do :; done; echo CHILD_COMPLETED'"""
check_notice(setup + before_reset + early_child, expected_status=130,
             wait_marker=b'BEFORE_RESET', parent_signal=signal.SIGINT,
             forbidden=(b'CHILD_COMPLETED', b'Update 9.8.7'))
print('PASS: early INT stops the child after its inherited ignore is reset')

before_fork = instrument_router('if [[ "$interrupted" -ne 0 ]]; then',
                               'echo PRE_FORK_READY; local launch_deadline=$((SECONDS+2)); while ((SECONDS<launch_deadline)); do :; done; if [[ "$interrupted" -ne 0 ]]; then')
launch_marker = instrument_router('$SIG{INT}="DEFAULT";',
                                  '$|=1; print "LAUNCH_ENTER\\n"; $SIG{INT}="DEFAULT";')
check_notice(setup + before_fork + launch_marker + early_child, expected_status=130,
             wait_marker=b'PRE_FORK_READY', parent_signal=signal.SIGINT,
             forbidden=(b'LAUNCH_ENTER', b'CHILD_COMPLETED', b'Update 9.8.7'))
print('PASS: cancellation before fork skips command launch')

ready_pause = instrument_router('kill "USR1", getppid();',
                                'kill "USR1", getppid(); select undef,undef,undef,1;')
check_notice(setup + ready_pause + "run_mole_command /bin/bash -c 'echo CHILD_COMPLETED; exit 7'",
             expected_status=7, required=(b'CHILD_COMPLETED',))
print('PASS: launcher readiness cannot replace the command exit status')

# Bash 3.2 can discard INT inside a USR1 trap entered from the wait builtin.
# Keep that handler active with builtins while the real child reports ready.
ready_handler_window = instrument_router('command_ready=true;',
                                        'command_ready=true; local ready_deadline=$((SECONDS+1)); while ((SECONDS<ready_deadline)); do :; done;')
check_notice(setup + ready_handler_window + """echo WRAPPER_PID=$$; run_mole_command /bin/bash -c 'trap "exit 130" INT; echo CHILD_READY; while :; do :; done' """,
             expected_status=130, wait_marker=b'CHILD_READY', parent_signal=signal.SIGINT,
             forbidden=(b'Update 9.8.7',))
print('PASS: INT during launcher readiness reaches the child')

for launcher_exit, expected_status in [('exit 7;', 7), ('kill "KILL", $$;', 137)]:
    failed_launcher = instrument_router('$SIG{INT}="DEFAULT";', launcher_exit + '$SIG{INT}="DEFAULT";')
    check_notice(setup + failed_launcher + "run_mole_command /bin/bash -c 'echo CHILD_COMPLETED'",
                 expected_status=expected_status, forbidden=(b'CHILD_COMPLETED',))
print('PASS: a launcher that exits before readiness does not block the router')

output = check_notice(counter, expected_status=130, wait_marker=b'CHILD_READY', keys=b'\x03',
                      forbidden=(b'Update 9.8.7',))
count = re.search(rb'INT_COUNT=(\d+)', output)
assert count and int(count.group(1)) in (1, 2), output
output = check_notice(counter, expected_status=130, wait_marker=b'CHILD_READY', parent_signal=signal.SIGINT,
                      forbidden=(b'Update 9.8.7',))
assert b'INT_COUNT=1\r\n' in output, output
print(f'PASS: INT reaches the child once from the router and at most twice from a terminal Ctrl-C (saw {int(count.group(1))})')
