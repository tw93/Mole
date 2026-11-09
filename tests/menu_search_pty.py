#!/usr/bin/env python3
"""Check that menu search keeps a pasted term under the system Bash."""
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
source "$TEST_ROOT/lib/core/common.sh"
source "$TEST_ROOT/lib/ui/menu_paginated.sh"
set +e
items=()
for ((i = 1; i <= 40; i++)); do items+=("App $i"); done
items+=("zebra target")
paginated_multi_select "Pick" "${items[@]}"
'''


def read_until(master, output, marker, timeout):
    deadline = time.monotonic() + timeout
    while marker not in output:
        assert time.monotonic() < deadline, ('missing ' + repr(marker), output[-2000:])
        if select.select([master], [], [], .02)[0]:
            output += os.read(master, 65536)
    return output


def check_search(keys):
    with tempfile.TemporaryDirectory(prefix="mole-menu-search-") as home:
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, b'\x28\x00\x78\x00\x00\x00\x00\x00')
        env = dict(os.environ, HOME=home, TERM="xterm-256color",
                   MOLE_TEST_MODE="1", MOLE_TEST_NO_AUTH="1", TEST_ROOT=str(root))

        def own_terminal():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        process = subprocess.Popen(
            ["/bin/bash", "--noprofile", "--norc", "-c", child_script],
            stdin=slave, stdout=slave, stderr=slave, env=env,
            preexec_fn=own_terminal)
        output = b''
        try:
            output = read_until(master, output, b'selected', 10)
            os.write(master, b'/')
            output = read_until(master, output, b'type to search', 5)
            keys(master)
            output = read_until(master, output, b'Search: zebra_', 5)
            print('PASS: search kept the full term')
        finally:
            if process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except PermissionError:
                    process.kill()
                # Darwin holds an exiting session leader until its terminal
                # output drains, so keep reading while waiting for the exit.
                deadline = time.monotonic() + 5
                while process.poll() is None and time.monotonic() < deadline:
                    if select.select([master], [], [], .02)[0]:
                        try:
                            os.read(master, 65536)
                        except OSError:
                            break
                process.wait(timeout=5)
            os.close(slave)
            os.close(master)


def paste(master):
    os.write(master, b'zebra')


def fast_typing(master):
    for char in b'zebra':
        os.write(master, bytes([char]))
        time.sleep(.02)


def after_partial_escape(master):
    # Shift+Up is only partly decoded; its tail must not become search text.
    # Keep reading while waiting: a blocked redraw would delay the drain past
    # the next write and flush it too.
    os.write(master, b'\x1b[1;2A')
    deadline = time.monotonic() + .5
    while time.monotonic() < deadline:
        if select.select([master], [], [], .02)[0]:
            os.read(master, 65536)
    os.write(master, b'zebra')


def check_term_without_keypress():
    # A TERM sent to the menu process alone (not the terminal's process
    # group) used to wait for the next keypress before the trap ran.
    with tempfile.TemporaryDirectory(prefix="mole-menu-term-") as home:
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, b'\x28\x00\x78\x00\x00\x00\x00\x00')
        env = dict(os.environ, HOME=home, TERM="xterm-256color",
                   MOLE_TEST_MODE="1", MOLE_TEST_NO_AUTH="1", TEST_ROOT=str(root))

        def own_terminal():
            # bash cannot trap a signal it inherited ignored.
            signal.signal(signal.SIGTERM, signal.SIG_DFL)
            signal.signal(signal.SIGINT, signal.SIG_DFL)
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        process = subprocess.Popen(
            ["/bin/bash", "--noprofile", "--norc", "-c", child_script],
            stdin=slave, stdout=slave, stderr=slave, env=env,
            preexec_fn=own_terminal)
        output = b''
        try:
            output = read_until(master, output, b'selected', 10)
            time.sleep(.3)
            os.kill(process.pid, signal.SIGTERM)
            deadline = time.monotonic() + 4
            while process.poll() is None:
                assert time.monotonic() < deadline, 'menu ignored TERM until a keypress'
                if select.select([master], [], [], .05)[0]:
                    try:
                        output += os.read(master, 65536)
                    except OSError:
                        break
            print('PASS: menu stopped on TERM without a keypress')
        finally:
            if process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except PermissionError:
                    process.kill()
                process.wait(timeout=5)
            os.close(slave)
            os.close(master)


def check_word_search():
    # Words match in any order; one missing word empties the list; an extra
    # space, and a glob character, stay literal.
    cases = [(b'target zebra', True), (b'zebra  target', True),
             (b'zebra nope', False), (b'z*a', False)]
    for term, found in cases:
        with tempfile.TemporaryDirectory(prefix="mole-menu-words-") as home:
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, b'\x28\x00\x78\x00\x00\x00\x00\x00')
            env = dict(os.environ, HOME=home, TERM="xterm-256color",
                       MOLE_TEST_MODE="1", MOLE_TEST_NO_AUTH="1", TEST_ROOT=str(root))

            def own_terminal():
                os.setsid()
                fcntl.ioctl(0, termios.TIOCSCTTY, 0)

            process = subprocess.Popen(
                ["/bin/bash", "--noprofile", "--norc", "-c", child_script],
                stdin=slave, stdout=slave, stderr=slave, env=env,
                preexec_fn=own_terminal)
            output = b''
            try:
                output = read_until(master, output, b'selected', 10)
                os.write(master, b'/')
                output = read_until(master, output, b'type to search', 5)
                mark = len(output)
                os.write(master, term)
                output = read_until(master, output, b'Search: ' + term + b'_', 5)
                output = read_until(master, output[mark:], b'selected)', 5)
                # The header counts the matches of the 41 rows; the list follows it.
                assert (b'(1/41;' if found else b'(0/41;') in output, (term, output[-200:])
                print('PASS: search for', term.decode(), 'found' if found else 'empty')
            finally:
                if process.poll() is None:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except PermissionError:
                        process.kill()
                    deadline = time.monotonic() + 5
                    while process.poll() is None and time.monotonic() < deadline:
                        if select.select([master], [], [], .02)[0]:
                            try:
                                os.read(master, 65536)
                            except OSError:
                                break
                    process.wait(timeout=5)
                os.close(slave)
                os.close(master)


def check_word_search_steps():
    # Each step reuses or rebuilds the filter cache: extending narrows, and a
    # backspace has to bring back what the longer text hid.
    steps = [(b'app', b'app', 40), (b' ', b'app ', 40), (b'1', b'app 1', 13),
             (b'x', b'app 1x', 0), (b'\x7f', b'app 1', 13), (b'\x7f', b'app ', 40)]
    with tempfile.TemporaryDirectory(prefix="mole-menu-steps-") as home:
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, b'\x28\x00\x78\x00\x00\x00\x00\x00')
        env = dict(os.environ, HOME=home, TERM="xterm-256color",
                   MOLE_TEST_MODE="1", MOLE_TEST_NO_AUTH="1", TEST_ROOT=str(root))

        def own_terminal():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        process = subprocess.Popen(
            ["/bin/bash", "--noprofile", "--norc", "-c", child_script],
            stdin=slave, stdout=slave, stderr=slave, env=env,
            preexec_fn=own_terminal)
        output = b''
        try:
            output = read_until(master, output, b'selected', 10)
            os.write(master, b'/')
            output = read_until(master, output, b'type to search', 5)
            for key, shown, count in steps:
                mark = len(output)
                os.write(master, key)
                marker = b'Search: ' + shown + b'_'
                deadline = time.monotonic() + 5
                while marker not in output[mark:]:
                    assert time.monotonic() < deadline, ('missing', marker, output[-800:])
                    if select.select([master], [], [], .02)[0]:
                        output += os.read(master, 65536)
                # The header counts the matches of the 41 rows; the list follows it.
                output = read_until(master, output[output.rindex(marker):], b'selected)', 5)
                assert b'(%d/41;' % count in output, (shown, output[-200:])
            print('PASS: search steps kept the filter cache honest')
        finally:
            if process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except PermissionError:
                    process.kill()
                deadline = time.monotonic() + 5
                while process.poll() is None and time.monotonic() < deadline:
                    if select.select([master], [], [], .02)[0]:
                        try:
                            os.read(master, 65536)
                        except OSError:
                            break
                process.wait(timeout=5)
            os.close(slave)
            os.close(master)


check_search(paste)
check_search(fast_typing)
check_search(after_partial_escape)
check_word_search()
check_word_search_steps()
check_term_without_keypress()
