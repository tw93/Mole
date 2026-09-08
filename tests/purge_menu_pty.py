#!/usr/bin/env python3
"""Exercise the real purge selector in a PTY using fabricated metadata only."""
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

root = Path(__file__).resolve().parents[1]
fixture = tempfile.TemporaryDirectory(prefix="mole-purge-menu-")
home = Path(fixture.name)
env = dict(
    os.environ,
    HOME=str(home),
    TEST_ROOT=str(root),
    TERM='xterm-256color',
    MOLE_TEST_NO_AUTH='1',
    MOLE_DRY_RUN='1',
    XDG_CACHE_HOME=str(home / '.cache'),
)
setup = r'''
source "$TEST_ROOT/lib/clean/project.sh"
categories=(); size_values=(); recent_values=(); age_values=()
long_path='/fixture/company/very-long-segment/another-long-segment/third-long-segment/fourth-long-segment/fifth-long-segment/sixth-long-segment'
for ((n=0; n<80; n++)); do
    categories+=("artifact-$n")
    size_values+=(1024); recent_values+=(false); age_values+=(30d)
    PURGE_CATEGORY_PROJECT_IDS_ARRAY+=("exact-project-$((n/20))")
    project_path="$long_path/项目-$((n/20))"
    [[ $n -lt 20 ]] && project_path="[cloud] $project_path"
    PURGE_CATEGORY_PROJECT_PATHS_ARRAY+=("$project_path")
    PURGE_CATEGORY_FULL_PATHS_ARRAY+=("$long_path/项目-$((n/20))/artifact-$n")
    PURGE_CATEGORY_SIZE_UNKNOWN_FLAGS_ARRAY+=(false)
done
PURGE_CATEGORY_SIZES=$(IFS=,; echo "${size_values[*]}")
PURGE_RECENT_CATEGORIES=$(IFS=,; echo "${recent_values[*]}")
PURGE_AGE_LABELS=$(IFS=,; echo "${age_values[*]}")
'''
script = setup + '\nif select_purge_categories "${categories[@]}"; then echo TEST_ACCEPTED; else echo TEST_CANCELLED; fi\n'
ansi = re.compile(rb'\x1b\[[0-?]*[ -/]*[@-~]')

def plain(frame: bytes) -> str:
    return ansi.sub(b'', frame).decode('utf-8').replace('\r', '')

def position(frame: bytes) -> int:
    matches = re.findall(r'\[(\d+)/80\]', plain(frame))
    assert matches, plain(frame)
    return int(matches[-1])

def width(line: str) -> int:
    return sum(
        0 if unicodedata.combining(c)
        else 2 if unicodedata.east_asian_width(c) in 'WF'
        else 1
        for c in line
    )

def fits(frame: bytes, rows: int, cols: int) -> None:
    lines = plain(frame).splitlines()
    overflow = [(width(line), line) for line in lines if width(line) > cols]
    assert not overflow, overflow
    assert len(lines) < rows, ('frame fills/overruns terminal', len(lines), rows)
master, slave = pty.openpty()

def resize(rows: int, cols: int) -> None:
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
resize(40, 120)

def own_terminal() -> None:
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)
p = subprocess.Popen(['/bin/bash', '--noprofile', '--norc', '-c', script],
                     stdin=slave, stdout=slave, stderr=slave, env=env, preexec_fn=own_terminal)
os.close(slave)
pending = b''

def receive(marker: bytes = b'\x1b[J') -> bytes:
    global pending
    deadline = time.monotonic() + 10
    while marker not in pending:
        assert time.monotonic() < deadline, ('timeout', pending[-1000:])
        if select.select([master], [], [], .05)[0]:
            try:
                chunk = os.read(master, 65536)
            except OSError as exc:
                raise AssertionError(('terminal ended', p.poll(), pending[-1000:])) from exc
            assert chunk, ('EOF', pending[-1000:])
            pending += chunk
    end = pending.index(marker) + len(marker)
    frame, pending = pending[:end], pending[end:]
    return frame
try:
    initial_frame = receive()
    fits(initial_frame, 40, 120)
    assert re.search(r'\[cloud\].*artifact-0', plain(initial_frame)), plain(initial_frame)
    os.write(master, b' ')
    assert '79 selected' in plain(receive())
    resize(10, 25)
    os.write(master, b'\n')
    resize_frame = receive()
    assert b'Resize' in resize_frame  # Enter cannot confirm an unreadable menu.
    fits(resize_frame, 10, 25)
    resize(40, 120)
    os.write(master, b'~')
    fits(receive(), 40, 120)
    for _ in range(29):
        os.write(master, b'j')
        frame = receive()
    assert position(frame) == 30
    resize(24, 80)
    os.write(master, b'~')  # Unbound key causes a redraw without changing selection.
    frame = receive()
    assert position(frame) == 30
    fits(frame, 24, 80)
    os.write(master, b'\x1b[6~')
    frame = receive()
    assert 40 <= position(frame) <= 60, ('Page Down did not move a page', position(frame))
    os.write(master, b'[')
    frame = receive()
    assert position(frame) == 21
    os.write(master, b']')
    frame = receive()
    assert position(frame) == 41
    fits(frame, 24, 80)
    os.write(master, '/项目-3错误'.encode() + b'\x7f\x7f\n')
    frame = receive()
    assert position(frame) == 61
    assert '79 selected' in plain(frame)
    os.write(master, b'n')
    frame = receive()
    assert position(frame) == 62
    assert '79 selected' in plain(frame)
    os.write(master, b'q')
    receive(b'TEST_CANCELLED')
    assert p.wait(timeout=2) == 0
finally:
    if p.poll() is None:
        os.killpg(p.pid, signal.SIGTERM)
        try:
            p.wait(timeout=2)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)
            p.wait(timeout=2)
    os.close(master)
# Pipe EOF is deterministic; closing a PTY master instead tests SIGHUP handling.
for input_bytes in (b'', b'/'):
    r = subprocess.run(['/bin/bash', '--noprofile', '--norc', '-c', script], env=env,
                       input=input_bytes, capture_output=True, timeout=10)
    assert r.returncode == 0 and b'TEST_CANCELLED' in r.stdout and b'TEST_ACCEPTED' not in r.stdout, r.stdout[-1000:]
print('PASS: focus survives resize; rows fit; paging/project jumps work; quit and EOF cancel')

fixture.cleanup()
