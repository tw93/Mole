#!/usr/bin/env python3
"""Drive clean's sudo gate on a real terminal.

A user who types the password straight away must reach sudo's own prompt with
nothing left over for the shell; Space skips and q cancels. sudo is a stand-in
that records how it was called, so no password is ever read.
"""
import fcntl
import os
import pty
import select
import signal
import subprocess
import tempfile
import termios
import time
from pathlib import Path

root = Path(__file__).resolve().parents[1]

child_script = r'''
SCRIPT_DIR="$TEST_ROOT"
source "$TEST_ROOT/bin/clean.sh"
set +e
if [[ "${GATE_IN_SUBSHELL:-}" == 1 ]]; then
    (prompt_for_system_clean)
else
    prompt_for_system_clean
    echo "READY=$SYSTEM_READY"
fi
rest=""
IFS= read -r -t 1 rest
echo "LEFTOVER=[$rest]"
mole_sudo_end
'''


def read_until(master, output, marker, timeout):
    deadline = time.monotonic() + timeout
    while marker not in output:
        assert time.monotonic() < deadline, ('missing ' + repr(marker), output[-2000:])
        if select.select([master], [], [], .02)[0]:
            try:
                output += os.read(master, 65536)
            except OSError:
                break
    return output


def run_gate(keys, subshell=False):
    with tempfile.TemporaryDirectory(prefix="mole-sudo-gate-") as tmp:
        home = Path(tmp) / "home"
        fakes = Path(tmp) / "bin"
        home.mkdir()
        fakes.mkdir()
        log = Path(tmp) / "sudo.log"
        sudo = fakes / "sudo"
        sudo.write_text('#!/bin/bash\n[[ "$1" == -n ]] && exit 1\n'
                        'printf "%%s\\n" "$*" >> "%s"\nexit 0\n' % log)
        journal = fakes / "journalctl"
        journal.write_text('#!/bin/bash\nexit 0\n')
        sudo.chmod(0o755)
        journal.chmod(0o755)
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, b'\x28\x00\x78\x00\x00\x00\x00\x00')
        env = dict(os.environ, HOME=str(home), TERM="xterm-256color", TEST_ROOT=str(root),
                   PATH=str(fakes) + os.pathsep + os.environ.get("PATH", ""))
        if subshell:
            env["GATE_IN_SUBSHELL"] = "1"
        for name in ("XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME"):
            env.pop(name, None)

        def own_terminal():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        process = subprocess.Popen(
            ["/bin/bash", "--noprofile", "--norc", "-c", child_script],
            stdin=slave, stdout=slave, stderr=slave, env=env,
            preexec_fn=own_terminal)
        output = b''
        try:
            output = read_until(master, output, b'skip: ', 10)
            os.write(master, keys)
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                ready = select.select([master], [], [], .05)[0]
                if ready:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError:
                        break
                    if not chunk:
                        break
                    output += chunk
                elif process.poll() is not None:
                    break
            assert process.poll() is not None, ('still running', output[-2000:])
        finally:
            if process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except PermissionError:
                    process.kill()
                process.wait(timeout=5)
            os.close(slave)
            os.close(master)
        calls = log.read_text() if log.exists() else ''
        return output.decode('utf-8', 'replace'), calls


# A password typed at once: the first key leads to sudo's prompt, the rest is
# dropped instead of reaching the shell.
out, calls = run_gate(b's3cret\r')
assert 'READY=true' in out, out
assert 'LEFTOVER=[]' in out, out
assert 'Skipped' not in out, out
assert '-v -p' in calls, calls
print('PASS: typed characters reach the sudo prompt, nothing is left over')

out, calls = run_gate(b'\r')
assert 'READY=true' in out and '-v -p' in calls, (out, calls)
print('PASS: Enter asks for the password')

out, calls = run_gate(b' ')
assert 'Skipped' in out and 'READY=false' in out, out
assert '-v' not in calls, calls
print('PASS: Space skips without asking')

out, calls = run_gate(b'q')
assert 'Cancelled' in out and 'READY=' not in out, out
assert '-v' not in calls, calls
print('PASS: q cancels')

# A password that starts with q or a space: the gate cancels or skips, and the
# rest of what was typed must not reach the shell either.
out, calls = run_gate(b'quartz9x\r', subshell=True)
assert 'Cancelled' in out and 'LEFTOVER=[]' in out, out
assert '-v' not in calls, calls
print('PASS: q with keys typed after it leaves nothing over')

out, calls = run_gate(b' pass9x\r')
assert 'Skipped' in out and 'LEFTOVER=[]' in out, out
print('PASS: Space with keys typed after it leaves nothing over')

