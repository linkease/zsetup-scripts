"""Actual UID 1000 -> sudo -> UID 0, in a private chroot/mount namespace only."""
import hashlib
import http.server
import json
import os
from pathlib import Path
import ssl
import subprocess
import sys
import threading

from service_storage_test import jail, Handler, executable
from tls_fixture import generate_certificate

ROOT = Path(__file__).resolve().parents[1]


def inside():
    Path('/tmp').chmod(0o1777)
    fixture = Path('/fixtures/zig-sudo'); fixture.mkdir()
    home = Path('/home/tester'); home.mkdir(parents=True)
    os.chown(home, 1000, 1000); home.chmod(0o700)
    generate_certificate(fixture)
    executable(fixture / 'systemctl', '''#!/bin/sh
set -eu
unit=/etc/systemd/system/com.linkease.ddnstoshell.service
state=/fixtures/zig-sudo
case "$1" in
 is-active|is-enabled) test ! -f "$state/stopped" ;;
 stop|disable) : > "$state/stopped" ;;
 start|enable) rm -f "$state/stopped" ;;
 daemon-reload) : ;;
 show)
  case "$*" in
   *MainPID*) echo 111 ;;
   *ActiveState*) if [ -f "$state/stopped" ]; then echo inactive; else echo active; fi ;;
   *FragmentPath*) test ! -f "$unit" || echo "$unit" ;;
   *LoadState*) if [ -f "$unit" ]; then echo loaded; else echo not-found; fi ;;
   *NeedDaemonReload*) echo no ;;
   *ExecStartPre*|*ExecStartPost*) : ;;
   *ExecStart*) echo '{ path=/bin/sh ; argv[]=/bin/sh /opt/zig-sudo/versions/4.2.1/bin/.service-run ; ignore_errors=no ; start_time=[n/a] ; }' ;;
   *EnvironmentFiles*) : ;;
   *Environment*) echo 'DDNSTO_TEST_SERVER_ASSIGNMENT_JSON={"serverDomain":"kooldns.cn","legacyControlAddr":"tunnel.kooldns.cn:4445"}' ;;
   *UnitFileState*) echo enabled ;;
   *) : ;;
  esac ;;
 *) exit 97 ;;
esac
''')
    subprocess.run(['mount', '--bind', str(fixture/'systemctl'), '/usr/bin/systemctl'], check=True)
    sudoers = Path('/etc/sudoers')
    sudoers.write_text('Defaults !use_pty\ntester ALL=(root) NOPASSWD: ALL\n')
    sudoers.chmod(0o440)
    payload = b'#!/bin/sh\ncase "$1" in -v) echo 4.2.1 ;; --config) test -s "$2" ;; *) exit 97 ;; esac\n'
    url = '/ddnsto/ddnsto-zig/ddnsto.x86_64'
    Handler.bodies[url] = payload
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(fixture/'server.crt', fixture/'server.key')
    server.socket = context.wrap_socket(server.socket, server_side=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
    try:
        version = json.loads((ROOT/'apps/ddnsto/app.json').read_text())['version']
        source = (ROOT/f'apps/ddnsto/versions/{version}/install.sh').read_text()
        # Expose child errors only in the isolated fixture (all accounts fake).
        source = source.replace(') >/dev/null 2>&1 &', ') &')
        source = source.replace('76e21cb89b623ae57ac928380d2fce3c51b502c04a4b58f36bb59ab5cdd3ca5d',
                                hashlib.sha256(payload).hexdigest()).replace(
                                'PROCESS_DOWNLOAD_BYTES=752664', f'PROCESS_DOWNLOAD_BYTES={len(payload)}')
        installer = fixture/'install.sh'; installer.write_text(source); installer.chmod(0o755)
        command = ['/usr/sbin/runuser','-u','tester','--','/usr/bin/env','-i',
                   'PATH=/usr/bin:/bin','HOME=/home/tester','ZSETUP_INSTALLER_MODE=1',
                   'ZSETUP_BIN=/tools/zsetup','ZSETUP_OS=linux','ZSETUP_ARCH=x86_64',
                   'ZSETUP_PACKAGE_MANAGER=apt',f'ZSETUP_SOURCE_BASES=https://127.0.0.1:{server.server_port}',
                   'ZSETUP_SOURCE_FALLBACK=',f'ZSETUP_CA_FILE={fixture}/ca.crt',
                   '/bin/sh',str(installer),'--installer-prefix','/opt/zig-sudo','--',
                   '--token','fixture-token','--force-version','lite']
        for _ in range(2):
            result = subprocess.run(command, capture_output=True, text=True, timeout=45)
            assert result.returncode == 0, result
        assert Handler.counts[url] == 1, Handler.counts
        binary = Path('/opt/zig-sudo/current/bin/ddnsto')
        assert binary.stat().st_uid == 0
        alias = home/'.local/bin/ddnsto'
        assert alias.is_symlink() and alias.lstat().st_uid == 1000
        assert 'userToken: "fixture-token"' in Path('/etc/ddnsto/.ddnsto-zig.yaml').read_text()
        assert not list(home.rglob('.transaction.*'))
        assert not list(Path('/tmp').glob('zsetup-privileged.*'))
        print('Zig sudo: actual UID transition, pinned raw handoff, single download, repeat, root files and user alias passed')
    finally:
        server.shutdown(); server.server_close(); thread.join(timeout=2)


if __name__ == '__main__':
    if sys.argv[1] == '--inside':
        inside()
    else:
        jail(Path(sys.argv[1]).resolve(), '/source/tests/ddnsto_sudo_zig_native_test.py')
