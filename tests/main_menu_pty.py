#!/usr/bin/env python3
"""Check terminal restoration after leaving the real main menu."""
import fcntl
import os
import pty
import select
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
