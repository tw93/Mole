#!/usr/bin/env python3
"""Exercise personal-data review with real keys and a synthetic uninstall plan."""
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
from pathlib import Path

root = Path(__file__).resolve().parents[1]
script = r'''
source "$TEST_ROOT/lib/ui/menu_paginated.sh"
source "$TEST_ROOT/lib/uninstall/batch.sh"
app="$HOME/Applications/Example.app"
data="$HOME/Library/Application Support/Example"
mkdir -p "$app" "$data"
encoded=$(printf '%s' "$data" | base64 | tr -d '\n')
app_details=("Example|$app|com.example.app|10|$encoded||true|false|false|||||none||||")
running_apps=() sudo_apps=() brew_cask_apps=() leftover_notes=()
total_estimated_size=10
get_path_size_kb() { echo 10; }
calculate_total_size() { if [[ -n "$1" ]]; then echo 10; else echo 0; fi; }
# App-list metadata must not leak into the path selector.
MOLE_MENU_FILTER_NAMES=IncorrectAppName
MOLE_MENU_META_SIZEKB=999
MOLE_PRESELECTED_INDICES=0
rc=0
_batch_preview_and_confirm || rc=$?
[[ $rc -eq 0 ]] || exit "$rc"
IFS='|' read -r _ _ _ _ encoded _ <<< "${app_details[0]}"
files=$(decode_file_list "$encoded" Example)
if [[ "$files" == "$data" ]]; then echo TEST_REMOVE_DATA; else echo TEST_KEEP_DATA; fi
'''


def read_until(master, marker, timeout=8):
    output = b''
    deadline = time.monotonic() + timeout
    while marker not in output:
        assert time.monotonic() < deadline, (marker, output[-3000:])
        if select.select([master], [], [], .02)[0]:
            output += os.read(master, 65536)
    return output


def wait_for_key_read(slave, timeout=8):
    # The prompt prints, drains pending input, then starts read -s, which
    # turns echo off. A key sent before that is drained on purpose, so wait
    # for echo to go off instead of sleeping a fixed time.
    deadline = time.monotonic() + timeout
    while termios.tcgetattr(slave)[3] & termios.ECHO:
        assert time.monotonic() < deadline, 'prompt never started reading a key'
        time.sleep(.01)


def check(cols, choice):
    with tempfile.TemporaryDirectory(prefix='mole-uninstall-review-') as home:
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, cols, 0, 0))
        env = dict(os.environ, HOME=home, TEST_ROOT=str(root), TERM='xterm-256color',
                   MOLE_TEST_NO_AUTH='1', MOLE_DRY_RUN='1')

        def own_terminal():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        process = subprocess.Popen(['/bin/bash', '--noprofile', '--norc', '-c', script],
                                   stdin=slave, stdout=slave, stderr=slave,
                                   env=env, preexec_fn=own_terminal)
        try:
            preview = read_until(master, b'cancel: ')
            assert b'Personal data kept' in preview, preview
            assert b'D choose personal data' not in preview, preview
            wait_for_key_read(slave)
            os.write(master, b'd')
            menu = read_until(master, b'Q Cancel')
            assert b'0/1 selected' in menu and b'IncorrectAppName' not in menu, menu
            assert b'A All' in menu, menu
            if choice in ('select', 'all'):
                time.sleep(.12)
                os.write(master, b' ' if choice == 'select' else b'a')
                menu += read_until(master, b'1/1 selected')
            time.sleep(.12)
            os.write(master, b'q' if choice == 'cancel' else b'\r')
            reviewed = read_until(master, b'cancel: ')
            removes = choice in ('select', 'all')
            assert (b'Personal data kept' in reviewed) != removes, reviewed
            # Leaving the picker restores the old preview; the redrawn plan
            # starts on a cleared screen so the stale one is not left above it.
            redrawn = reviewed.rsplit(b'\x1b[?1049l', 1)[-1]
            cleared = redrawn.find(b'\x1b[2J')
            assert -1 < cleared < redrawn.find(b'Files to be removed'), reviewed
            wait_for_key_read(slave)
            os.write(master, b'\r')
            expected = b'TEST_REMOVE_DATA' if removes else b'TEST_KEEP_DATA'
            read_until(master, expected)
            process.wait(timeout=5)
            assert process.returncode == 0, process.returncode
            if cols == 120 and choice == 'select':
                # Keep readable rendering evidence in the test output.
                plain = re.sub(rb'\x1b\[[0-?]*[ -/]*[@-~]', b'', preview + menu + reviewed)
                print(plain.decode('utf-8').replace('\r', ''))
            print(f'PASS: {cols} columns, {choice}')
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
            os.close(master)
            os.close(slave)


for width in (80, 120):
    for selection in ('empty', 'select', 'all', 'cancel'):
        check(width, selection)
