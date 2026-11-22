#!/usr/bin/env python3
"""Check real keyboard input and terminal layout with synthetic apps only."""
import fcntl
import os
import pty
import re
import select
import signal
import struct
import subprocess
import tempfile
import termios
import time
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ANSI = re.compile(rb'\x1b\[[0-?]*[ -/]*[@-~]')
PROGRAM_STATUS = re.compile(rb'\x1b\]7501;[^\x1b\x07]*\x1b\\')


def plain(frame):
    return ANSI.sub(b'', PROGRAM_STATUS.sub(b'', frame)).decode('utf-8').replace('\r', '')


def assert_fits(frame, rows, columns):
    # The query is drawn once per byte. Inspect the last complete redraw.
    frame = frame.rsplit(b'\x1b[H', 1)[-1]
    lines = plain(frame).splitlines()
    for line in lines:
        width = sum(0 if unicodedata.combining(c) else
                    2 if unicodedata.east_asian_width(c) in 'WF' else 1
                    for c in line)
        assert width <= columns, (columns, width, line)
    assert len(lines) < rows, (rows, len(lines), lines)


def check_menu(columns):
    with tempfile.TemporaryDirectory(prefix='mole-uninstall-menu-') as directory:
        env = dict(os.environ, HOME=directory, PROJECT_ROOT=str(ROOT),
                   TERM='xterm-256color', COLUMNS=str(columns), LINES='16',
                   MOLE_TEST_NO_AUTH='1', MOLE_DRY_RUN='1')
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 16, columns, 0, 0))

        def own_terminal():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        process = subprocess.Popen(
            ['/bin/bash', str(ROOT / 'tests/fixtures/uninstall_menu.sh'), '--tty'],
            stdin=slave, stdout=slave, stderr=slave, env=env, preexec_fn=own_terminal)
        os.close(slave)

        def receive(marker):
            data = b''
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                readable = select.select([master], [], [], .1)[0]
                if readable:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError:
                        chunk = b''
                    data += chunk
                    if not chunk:
                        break
                elif marker in data:
                    return data
            assert marker in data, ('missing output', marker, data[-2000:])
            return data

        try:
            blocked = b'\x1b]7501;state=blocked:app=mole:kind=question\x1b\\'
            frame = receive(blocked)
            assert frame.index(b'Enter Save') < frame.index(blocked), frame
            app_rows = [line for line in plain(frame).splitlines() if ' | Unknown' in line]
            assert len(app_rows) == 5 and 'alph' in app_rows[0] and 'Zebra' in app_rows[-1], app_rows
            assert_fits(frame, 16, columns)
            os.write(master, b'o')
            frame = receive(b'Enter Save')
            assert blocked not in frame, frame
            # Verify the actual order even when the order hint is hidden.
            app_rows = [line for line in plain(frame).splitlines() if ' | Unknown' in line]
            assert len(app_rows) == 5 and 'Zebra' in app_rows[0] and 'alph' in app_rows[-1], app_rows
            assert_fits(frame, 16, columns)
            # An unrecognized sequence (Shift+Up) must not leak bytes into
            # the query, while a later paste is still kept whole.
            os.write(master, b'/vIs')
            receive(b'/ Search: vIs_')
            os.write(master, b'\x1b[1;2A')
            time.sleep(.3)
            # Paste as one write: the menu must not drain query characters.
            os.write(master, b'UaL studio\r')
            frame = receive(b'Esc Clear')
            # Wait for Enter to apply (editing frames also show Esc Clear).
            if b'Enter Save' not in frame:
                frame += receive(b'Enter Save')
            assert '(1/5; 0 selected)' in plain(frame), plain(frame)
            assert_fits(frame, 16, columns)
            os.write(master, b' ')
            receive(b'1 selected')
            os.write(master, b'\r')
            result = receive(b'SELECTED=/fixture/Studio.app')
            assert b'SELECTED=/fixture/Alpha.app' not in result, plain(result)
            assert process.wait(timeout=3) == 0
        finally:
            try:
                stop(process)
            finally:
                os.close(master)


def stop(process):
    # Cleanup must not bury the assertion that brought us here. killpg can
    # fail with EPERM on macOS once part of the group has exited, so fall
    # back to the fixture itself.
    for sig in (signal.SIGTERM, signal.SIGKILL):
        if process.poll() is not None:
            return
        try:
            os.killpg(process.pid, sig)
        except (ProcessLookupError, PermissionError):
            try:
                process.send_signal(sig)
            except ProcessLookupError:
                return
        try:
            process.wait(timeout=3)
            return
        except subprocess.TimeoutExpired:
            continue


for terminal_width in (40, 60, 80, 120):
    check_menu(terminal_width)
print('PASS: A-Z/Z-A, pasted multiword search, exact selection, and layouts at 40/60/80/120 columns')
