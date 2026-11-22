#!/usr/bin/env python3
"""Check the OSC 7501 records mo purge writes, on a real terminal and without deleting anything."""
import base64
import fcntl
import os
import pty
import re
import select
import subprocess
import tempfile
import termios
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RECORD = re.compile(rb'\x1b\]7501;([^\x1b\x07]*)\x1b\\')

# The command with discovery stubbed out: only the entry point's reports and
# exit status are under test.
COMMAND = r'''
MOLE_SKIP_MAIN=1
source "$ROOT/bin/purge.sh"
clean_project_artifacts() {
    PURGE_RUN_OUTCOME="$OUTCOME"
    [[ "$OUTCOME" != signal ]] || kill -TERM "$$"
    return 0
}
main "$@"
'''

# The real selector and confirmation, fed fabricated rows.
WIDGETS = r'''
source "$ROOT/lib/core/common.sh"
source "$ROOT/lib/clean/project.sh"
PURGE_CATEGORY_PROJECT_IDS_ARRAY=(p1 p2)
PURGE_CATEGORY_PROJECT_PATHS_ARRAY=(/fixture/one /fixture/two)
PURGE_CATEGORY_FULL_PATHS_ARRAY=(/fixture/one/node_modules /fixture/two/target)
PURGE_CATEGORY_SIZE_UNKNOWN_FLAGS_ARRAY=(false false)
PURGE_CATEGORY_SIZES="1024,2048"
PURGE_RECENT_CATEGORIES="false,false"
PURGE_AGE_LABELS="30d,30d"
rc=0
case "$WIDGET" in
    menu) select_purge_categories node_modules target || rc=$?; echo "MENU_RC=$rc" ;;
    confirm) confirm_purge_cleanup 1 1024 0 0 /fixture/one/node_modules || rc=$?; echo "CONFIRM_RC=$rc" ;;
esac
'''


def own_terminal():
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)


def run(script, args=(), keys=(), **extra):
    """Run script on a terminal; send each key once its trigger text appears."""
    with tempfile.TemporaryDirectory(prefix='mole-purge-status-') as home:
        env = dict(os.environ, ROOT=str(ROOT), HOME=home, TMPDIR=home,
                   XDG_CACHE_HOME=home + '/.cache', TERM='xterm-256color',
                   MOLE_TEST_NO_AUTH='1', MOLE_DRY_RUN='1', **extra)
        master, slave = pty.openpty()
        fcntl.ioctl(master, termios.TIOCSWINSZ, b'\x00\x28\x00\x78\x00\x00\x00\x00')
        process = subprocess.Popen(['/bin/bash', '--noprofile', '--norc', '-c', script, 'purge', *args],
                                   env=env, stdin=slave, stdout=slave, stderr=slave,
                                   preexec_fn=own_terminal)
        os.close(slave)
        pending = list(keys)
        output = bytearray()
        deadline = time.monotonic() + 20
        try:
            while time.monotonic() < deadline:
                if select.select([master], [], [], 0.1)[0]:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError:
                        break
                    if not chunk:
                        break
                    output.extend(chunk)
                    if pending and pending[0][0] in bytes(output):
                        # The prompts drain pending input right after they print.
                        time.sleep(0.3)
                        os.write(master, pending.pop(0)[1])
                elif process.poll() is not None:
                    break
            process.wait(timeout=max(0.1, deadline - time.monotonic()))
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)
        assert not pending, ('key trigger never appeared', pending, bytes(output))
        return process.returncode, bytes(output)


def states(output):
    result = []
    for record in RECORD.findall(output):
        fields = dict(pair.split('=', 1) for pair in record.decode('ascii').split(':'))
        assert fields.get('app') == 'mole', fields
        if fields['state'] != 'blocked':
            # A blocked record may leave the title out; every other one names the command.
            assert base64.b64decode(fields['title'], validate=True) == b'mole purge', fields
        result.append(fields['state'] + ('/' + fields['kind'] if 'kind' in fields else ''))
    return result


def check(name, script, expected, code=0, args=(), keys=(), contains=b'', **extra):
    returncode, output = run(script, args, keys, **extra)
    assert returncode == code, (name, returncode, output)
    assert states(output) == expected, (name, states(output), expected, output)
    assert contains in output, (name, contains, output)


check('completed run', COMMAND, ['working', 'done'], OUTCOME='completed')
check('cancelled run', COMMAND, ['working', 'idle'], OUTCOME='cancelled')
check('run without candidates', COMMAND, ['working', 'idle'], OUTCOME='no_candidates')
check('incomplete run', COMMAND, ['working', 'error'], code=1, OUTCOME='incomplete')
check('failed scan', COMMAND, ['working', 'error'], code=1, OUTCOME='scan_failed')
check('terminated run', COMMAND, ['working', 'idle'], code=130, OUTCOME='signal')
check('help', COMMAND, [], args=['--help'], contains=b'--dry-run', OUTCOME='completed')
check('rejected option', COMMAND, [], code=1, args=['--bogus'], contains=b'Unknown option', OUTCOME='completed')

check('menu waits for a choice', WIDGETS, ['blocked/question'], keys=[(b'Q Quit', b'q')],
      contains=b'MENU_RC=1', WIDGET='menu')
check('confirmation waits for Enter', WIDGETS, ['blocked/permission'], keys=[(b'confirm', b'\r')],
      contains=b'CONFIRM_RC=0', WIDGET='confirm')
check('confirmation cancelled with Escape', WIDGETS, ['blocked/permission'], keys=[(b'confirm', b'\x1b')],
      contains=b'CONFIRM_RC=1', WIDGET='confirm')
