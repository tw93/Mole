#!/usr/bin/env python3
"""Exercise clean's main, prompt and exit traps without authorizing any cleanup."""
import errno
import fcntl
import os
import pty
import re
import select
import subprocess
import tempfile
import termios
import time
import tty
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = r'''
source "$PROJECT_ROOT/bin/clean.sh"
adopt_sudo_session() { [[ "$CACHED" == yes ]]; }
ensure_sudo_session() { return 1; }
ensure_sudo_session_with_password() { [[ "$1" == secret ]]; }
perform_cleanup() {
    printf 'scanning (dry=%s, system=%s)\n' "$DRY_RUN" "$SYSTEM_CLEAN"
    if [[ "$OUTCOME" == signal ]]; then kill -TERM "$$"; fi
    return "$OUTCOME"
}
main "$@"
'''


def own_terminal():
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)


def run_terminal(command, env, keys):
    master, slave = pty.openpty()
    try:
        if keys:
            tty.setcbreak(slave)
            os.write(master, keys)
        with tempfile.TemporaryFile() as stdout:
            process = subprocess.Popen(command, env=env, stdin=slave, stderr=slave,
                                       stdout=stdout, preexec_fn=own_terminal)
            os.close(slave)
            slave = None
            try:
                stderr = bytearray()
                deadline = time.monotonic() + 10
                while select.select([master], [], [], max(0, deadline - time.monotonic()))[0]:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError as error:
                        if error.errno != errno.EIO:
                            raise
                        break
                    if not chunk:
                        break
                    stderr.extend(chunk)
                process.wait(timeout=max(0, deadline - time.monotonic()))
                stdout.seek(0)
                return subprocess.CompletedProcess(command, process.returncode,
                                                   stdout.read(), bytes(stderr))
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
    finally:
        os.close(master)
        if slave is not None:
            os.close(slave)


def check(name, states, *, keys=b'', args=(), outcome=0, code=0,
          terminal_stderr=True, output=b''):
    with tempfile.TemporaryDirectory(prefix='mole-clean-status-') as home:
        env = dict(os.environ, PROJECT_ROOT=str(ROOT), HOME=home, TMPDIR=home,
                   TERM='xterm-256color', MOLE_TEST_MODE='1', MOLE_TEST_NO_AUTH='1',
                   MOLE_DRY_RUN='0', SUDO_USER='', CACHED='no' if keys else 'yes',
                   OUTCOME=str(outcome))
        command = ['/bin/bash', '--noprofile', '--norc', '-c', SCRIPT, 'clean', *args]
        if terminal_stderr:
            result = run_terminal(command, env, keys)
        else:
            # Input remains interactive. The descriptor receiving the reports
            # must itself be a terminal, even when a caller merges both outputs.
            master, slave = pty.openpty()
            try:
                result = subprocess.run(command, env=env, stdin=slave, stdout=subprocess.PIPE,
                                        stderr=subprocess.STDOUT, timeout=10)
            finally:
                os.close(master)
                os.close(slave)
    stderr = result.stderr or b''
    assert result.returncode == code, (name, result.returncode, result.stdout, stderr)
    assert output in result.stdout, (name, output, result.stdout)
    prefix = b'\x1b]7501;'
    assert prefix not in result.stdout, (name, result.stdout)
    reports = re.findall(rb'\x1b\]7501;([^\x1b\x07]*)\x1b\\', stderr)
    assert stderr.count(prefix) == len(reports), (name, stderr)
    actual = []
    for report in reports:
        fields = dict(pair.split('=', 1) for pair in report.decode('ascii').split(':'))
        assert fields.get('app') == 'mole', (name, fields)
        state = fields['state']
        if 'kind' in fields:
            state += '/' + fields['kind']
        actual.append(state)
    assert actual == states.split(), (name, actual, states, stderr)


permission = 'working blocked/permission'
check('cached credentials', 'working done', output=b'scanning (dry=false, system=true)')
check('dry run', 'working done', args=['--dry-run'], output=b'scanning (dry=true')
check('skip sudo', permission + ' working done', keys=b' ',
      output=b'scanning (dry=false, system=false)')
check('failed authentication', permission + ' blocked/auth working done', keys=b'\r',
      output=b'scanning (dry=false, system=false)')
check('typed password', permission + ' blocked/auth working done', keys=b'secret\n',
      output=b'scanning (dry=false, system=true)')
check('Escape', permission + ' idle', keys=b'\x1b', output=b'Canceled')
check('trapped SIGTERM', 'working idle', outcome='signal', code=143)
check('interrupted step', 'working idle', outcome=130, code=130)
check('failed step', 'working error', outcome=1, code=1)
check('timed-out step', 'working error', outcome=124, code=124)
check('help', '', args=['--help'], output=b'--dry-run')
check('piped', '', terminal_stderr=False, output=b'scanning')
