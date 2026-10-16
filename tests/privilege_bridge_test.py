#!/usr/bin/env python3
"""Protocol bootstrap test. A real two-UID sudo run is a separate native gate.

This local test uses a disposable namespace as root, but no host sudo/service.
It checks the root coordinator's ready/go, verified private copies, literal
arguments and cancellation; it does not pretend a one-UID map proves sudo.
"""
import hashlib
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tests'))
from service_storage_test import jail


def inside():
    native='/tools/zsetup'
    library=ROOT/'lib/install-privilege.sh'
    assert library.is_file(), 'privilege protocol missing'
    code=subprocess.check_output(['sh','-eu','-c','. "$1"; installer_privilege_root_code','root-code',str(library)],text=True)
    with tempfile.TemporaryDirectory(prefix='privilege-bridge-') as name:
        root=Path(name); program=root/'program.sh'
        program.write_text('''#!/bin/sh
set -eu
[ "${1:-}" != --installer-prefix ] || shift 3
printf '<%s>' "$@" > /fixtures/bridge-args
id -u > /fixtures/bridge-uid
if [ "${1:-}" = block ]; then
    sleep 60 & child=$!
    printf '%s\n' "$child" > /fixtures/bridge-child
    trap 'kill -TERM "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; : > /fixtures/bridge-joined; exit 143' TERM
    : > /fixtures/bridge-ready
    wait "$child"
fi
exit 0
''')
        sha=lambda path:hashlib.sha256(Path(path).read_bytes()).hexdigest()
        def command(arguments, digest=None):
            return ['sh','-eu','-c',code,'root-bridge','0',native,sha(native),str(program),digest or sha(program),'','',str(root),'ubuntu','apt','x86_64','https://fixture.invalid','','/opt/bridge-test','1.0.0',*arguments]
        def spawn(arguments, digest=None):
            proc=subprocess.Popen(command(arguments,digest),env=os.environ|{'SUDO_UID':'0'},stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            return proc
        proc=spawn(['中文 space','','literal $() "quote"'])
        first=proc.stdout.read(1)
        assert first==b'R', (first, proc.communicate(timeout=10))
        assert not Path('/fixtures/bridge-args').exists(), 'payload executed before GO'
        proc.stdin.write(b'G\n'); proc.stdin.flush()
        assert proc.stdout.read(4)==b'000\n'
        proc.stdin.close(); proc.wait(timeout=10)
        assert proc.returncode==0,proc.stderr.read()
        assert Path('/fixtures/bridge-args').read_text()=='<中文 space><><literal $() "quote">'
        assert Path('/fixtures/bridge-uid').read_text().strip()=='0'
        proc=spawn([], '0'*64)
        assert proc.stdout.read(5)==b'E011\n', proc.stderr.read()
        proc.stdin.close(); proc.wait(timeout=10); assert proc.returncode==11
        proc=spawn(['block'])
        assert proc.stdout.read(1)==b'R'
        proc.stdin.write(b'G\n'); proc.stdin.flush()
        ready=Path('/fixtures/bridge-ready')
        deadline=time.monotonic()+10
        while not ready.exists() and time.monotonic()<deadline: time.sleep(.02)
        assert ready.exists()
        proc.stdin.close()  # the root owner observes EOF, not an unprivileged kill
        assert proc.stdout.read(4)==b'143\n'
        proc.wait(timeout=10); assert proc.returncode==143,proc.stderr.read()
        assert Path('/fixtures/bridge-joined').exists()
        assert not Path('/proc',Path('/fixtures/bridge-child').read_text().strip()).exists()
        # EOF before GO also tears down verified bootstrap copies.
        proc=spawn([]); assert proc.stdout.read(1)==b'R'
        proc.stdin.close(); assert proc.stdout.read(4)==b'143\n'; proc.wait(timeout=10)
        assert not list(Path('/tmp').glob('zsetup-privileged.*'))
        print('privilege root protocol: ready/go, private SHA copies, literal argv, EOF join and cleanup passed')


if __name__=='__main__':
    if sys.argv[1]=='--inside': inside()
    else: jail(Path(sys.argv[1]).resolve(),'/source/tests/privilege_bridge_test.py')
