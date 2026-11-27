#!/usr/bin/env python3
"""Ctrl-C in a terminal stops a Homebrew `mo update` at once (#2121).

gtimeout and /usr/bin/timeout run brew in a process group of their own, so a
terminal Ctrl-C reached neither and Mole waited out the 120 s budget. In a
terminal the fix hands brew the terminal: brew gets the SIGINT and the shell
sees only its 130, so this drives a real pty rather than a signal to a group.
"""
import errno
import fcntl
import os
import pty
import select
import subprocess
import tempfile
import termios
import time
from pathlib import Path

root = Path(__file__).resolve().parents[1]

# Like gtimeout and /usr/bin/timeout: the command runs in a process group of its
# own that never owns the terminal.
FAKE_TIMEOUT = r'''#!/usr/bin/perl
use POSIX qw(setpgid);
shift @ARGV if $ARGV[0] eq '-k';
shift @ARGV;
shift @ARGV;
setpgid(0, 0);
my $pid = fork();
if ($pid == 0) { exec @ARGV; exit 127; }
waitpid($pid, 0);
exit($? >> 8);
'''

script = r'''
source "$TEST_ROOT/lib/core/common.sh"
MO_TIMEOUT_BIN="$FAKEBIN/fake-timeout"
rc=0
update_via_homebrew "1.0.0" || rc=$?
printf 'RESULT:%s\n' "$rc"
'''

with tempfile.TemporaryDirectory(prefix='mole-update-ctrlc-') as tmp:
    home = Path(tmp, 'home')
    fakebin = Path(tmp, 'bin')
    home.mkdir()
    fakebin.mkdir()
    marker = Path(tmp, 'brew-started')
    (fakebin / 'fake-timeout').write_text(FAKE_TIMEOUT)
    (fakebin / 'brew').write_text(f'#!/bin/sh\ntouch "{marker}"\nexec sleep 8\n')
    for name in ('fake-timeout', 'brew'):
        os.chmod(fakebin / name, 0o755)

    master, slave = pty.openpty()
    env = dict(os.environ, HOME=str(home), TEST_ROOT=str(root), FAKEBIN=str(fakebin),
               PATH=f'{fakebin}:{os.environ["PATH"]}', TERM='xterm')
    def own_terminal():
        # A new session whose controlling terminal is the pty, so the pty's
        # Ctrl-C becomes SIGINT for whichever process group holds it.
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)

    process = subprocess.Popen(['/bin/bash', '--noprofile', '--norc', '-c', script],
                               stdin=slave, stdout=slave, stderr=slave, env=env,
                               preexec_fn=own_terminal)
    os.close(slave)
    output = b''

    def drain(timeout):
        global output
        if select.select([master], [], [], timeout)[0]:
            try:
                chunk = os.read(master, 65536)
            except OSError as exc:
                if exc.errno != errno.EIO:
                    raise
                return False
            if not chunk:
                return False
            output += chunk
        return True

    try:
        deadline = time.monotonic() + 10
        while not marker.exists() and time.monotonic() < deadline:
            drain(.05)
        assert marker.exists(), output
        pressed = time.monotonic()
        os.write(master, b'\x03')
        while process.poll() is None and time.monotonic() < pressed + 12:
            drain(.05)
        for _ in range(100):
            if not select.select([master], [], [], 0)[0] or not drain(0):
                break
        elapsed = time.monotonic() - pressed
        assert process.poll() is not None, output
        assert elapsed < 4, (elapsed, output)
        # The run ends at the interrupt: no result line, exit 130.
        assert b'RESULT:' not in output, output
        assert process.returncode == 130, (process.returncode, output)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)
    print(f'PASS: Ctrl-C stopped the update in {elapsed:.1f}s')
