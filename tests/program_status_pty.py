#!/usr/bin/env python3
"""OSC 7501 reports from the main menu and run_mole_command (#2072), on a real terminal."""
import fcntl
import os
import pty
import re
import select
import signal
import subprocess
import sys
import tempfile
import termios
import time
from pathlib import Path

root = Path(__file__).resolve().parents[1]
REPORT = re.compile(rb'\x1b\]7501;([^\x1b\x07]*)\x1b\\')
# A stand-in command: the menu launches "$SCRIPT_DIR/bin/clean.sh" for key 1.
STUB = '#!/bin/bash\nprintf "stub ran %s\\n" "$*"\n'


def states(output):
    assert output.count(b'\x1b]7501;') == len(REPORT.findall(output)), output[-2000:]
    found = []
    for report in REPORT.findall(output):
        fields = dict(pair.split('=', 1) for pair in report.decode('ascii').split(':'))
        assert fields.get('app') == 'mole', fields
        found.append(fields['state'])
    return found


def run(name, script, expected, keys=b'', menu=False, required=b''):
    with tempfile.TemporaryDirectory(prefix='mole-program-status-') as home:
        stub_root = Path(home) / 'stub'
        (stub_root / 'bin').mkdir(parents=True)
        stub = stub_root / 'bin' / 'clean.sh'
        stub.write_text(STUB)
        stub.chmod(0o755)
        master, slave = pty.openpty()
        env = dict(os.environ, HOME=home, TERM='xterm-256color', TEST_ROOT=str(root),
                   STUB_ROOT=str(stub_root), MOLE_TEST_MODE='1', MOLE_SKIP_MAIN='1',
                   MOLE_TEST_NO_AUTH='1')
        child = 'source "$TEST_ROOT/mole"; ' + script
        # Keep the controlling terminal open after Bash exits, and survive the
        # same foreground Ctrl-C the menu receives.
        keeper = ('import subprocess,time,signal; signal.signal(signal.SIGINT,lambda *a:None); '
                  f'p=subprocess.run(["/bin/bash","--noprofile","--norc","-c",{child!r}]); '
                  'print("CASE_EXIT="+str(p.returncode),flush=True); time.sleep(10)')

        def terminal():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        process = subprocess.Popen([sys.executable, '-c', keeper], stdin=slave, stdout=slave,
                                   stderr=slave, env=env, preexec_fn=terminal)
        output = b''
        try:
            pending = list(keys)
            deadline = time.monotonic() + 30
            while b'CASE_EXIT=' not in output:
                assert time.monotonic() < deadline, (name, 'timed out', output[-3000:])
                if select.select([master], [], [], .02)[0]:
                    output += os.read(master, 65536)
                if pending and menu:
                    # Send the next key only once the menu is drawn and reading.
                    ready = output.count(b'Q Quit') > len(keys) - len(pending)
                    if ready and not termios.tcgetattr(slave)[3] & termios.ECHO:
                        os.write(master, bytes([pending.pop(0)]))
            while select.select([master], [], [], .05)[0]:
                output += os.read(master, 65536)
        finally:
            if process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except PermissionError:
                    process.kill()
                process.wait(timeout=5)
            os.close(slave)
            os.close(master)
    assert b'CASE_EXIT=0' in output, (name, output[-3000:])
    assert required in output, (name, required, output[-3000:])
    actual = states(output)
    assert actual == expected, (name, actual, expected)
    print('PASS:', name, ' '.join(actual) or '(none)')


menu = 'interactive_main_menu'
run('menu quit', menu, ['idle', 'clear'], keys=b'q', menu=True)
run('menu Ctrl-C', menu, ['idle', 'clear'], keys=b'\x03', menu=True)
run('menu launches a command', 'SCRIPT_DIR="$STUB_ROOT"; ' + menu,
    ['idle', 'working'], keys=b'1', menu=True, required=b'stub ran')
run('menu redraws without reporting again', menu, ['idle', 'clear'], keys=b'\x1b[B\x1b[Aq', menu=True)
run('direct command', 'run_mole_command "$STUB_ROOT/bin/clean.sh" --dry-run',
    ['working'], required=b'stub ran --dry-run')
run('JSON output', 'run_mole_command "$STUB_ROOT/bin/clean.sh" --json', [],
    required=b'stub ran --json')
run('redirected output', '(run_mole_command "$STUB_ROOT/bin/clean.sh") > "$HOME/out"; cat "$HOME/out"',
    [], required=b'stub ran')
