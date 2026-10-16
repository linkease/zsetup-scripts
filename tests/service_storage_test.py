#!/usr/bin/env python3
"""Native HTTPS/service transactions in a private root, never host services.

The service manager and products are fixtures; path protection, download,
streaming extraction, cancellation and filesystem operations are real.
"""
import hashlib
import http.server
import io
import json
import os
from pathlib import Path
import signal
import shlex
import shutil
import ssl
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def executable(path, body):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body)
    path.chmod(0o755)


def jail(native, suite='/source/tests/service_storage_test.py'):
    os.umask(0o022)
    # A real persistent mount, rather than the host's unknown overlay /tmp.
    (ROOT / 'dist').mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='service-jail-', dir=ROOT / 'dist') as name:
        root = Path(name)
        root.chmod(0o755)  # the chroot / must be searchable by the second UID
        for folder in ('usr', 'bin', 'lib', 'lib64', 'proc', 'dev', 'source', 'tools',
                       'fixtures', 'root', 'opt', 'tmp', 'var/tmp', 'etc/systemd/system', 'run/systemd/system'):
            (root / folder).mkdir(parents=True, exist_ok=True)
        (root / 'tools/zsetup').touch()
        (root / 'etc/os-release').write_text('ID=ubuntu\nVERSION_ID="22.04"\n')
        if os.geteuid() == 0:
            # Actual root is used only inside the isolated remote lab container.
            # It allows a real second UID; the development user namespace does not.
            for folder in ('pam.d', 'security'):
                shutil.copytree('/etc/' + folder, root / 'etc' / folder, dirs_exist_ok=True)
            (root / 'etc/passwd').write_text('root:x:0:0:root:/root:/bin/sh\ntester:x:1000:1000:test:/home/tester:/bin/sh\n')
            (root / 'etc/group').write_text('root:x:0:\ntester:x:1000:\n')
            (root / 'etc/shadow').write_text('root:!:20000:0:99999:7:::\ntester:!:20000:0:99999:7:::\n')
            (root / 'etc/shadow').chmod(0o600)
            (root / 'etc/nsswitch.conf').write_text('passwd: files\ngroup: files\nshadow: files\n')
        setup = root / 'setup.sh'
        setup.write_text('''set -eu
jail=$1; source=$2; native=$3; suite=$4; test_app=$5
mount --make-rprivate /
mount --bind "$jail" "$jail"
for folder in usr bin lib lib64; do
    mount --bind "/$folder" "$jail/$folder"
    mount -o remount,bind,ro "$jail/$folder"
done
mount --bind "$source" "$jail/source"
mount -o remount,bind,ro "$jail/source"
mount --bind "$native" "$jail/tools/zsetup"
mount -o remount,bind,ro "$jail/tools/zsetup"
mount -t proc proc "$jail/proc"
for device in null zero urandom; do
    touch "$jail/dev/$device"
    mount --bind "/dev/$device" "$jail/dev/$device"
done
chroot "$jail" /usr/bin/env -i PATH=/usr/bin:/bin HOME=/root TMPDIR=/fixtures OPENSSL_CONF=/dev/null PYTHONDONTWRITEBYTECODE=1 ZSETUP_TEST_APP="$test_app" /usr/bin/python3 "$suite" --inside
''')
        flags = '-mpf' if os.geteuid() == 0 else '-Urmpf'
        result = subprocess.run(['unshare', flags, 'sh', str(setup), str(root), str(ROOT), str(native), suite, os.environ.get("ZSETUP_TEST_APP", "")], timeout=240)
        assert result.returncode == 0, f'isolated service suite exited {result.returncode}'


class Handler(http.server.BaseHTTPRequestHandler):
    bodies = {}
    counts = {}
    def do_GET(self):
        cls = type(self)
        cls.counts[self.path] = cls.counts.get(self.path, 0) + 1
        body = cls.bodies.get(self.path)
        if body is None:
            self.send_error(404); return
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def log_message(self, *_): pass


def product(app, version):
    return f'''#!/bin/sh
case "$1" in
 -v|showVersion) echo '{app} {version}'; exit "${{VERSION_FAIL:-0}}" ;;
 stop) exit "${{STOP_FAIL:-0}}" ;;
 run) printf '%s\\n' "$0" > "$TEST_RUN_PATH"; exit 0 ;;
 -u|--serviceControl)
   if [ "$1" = --serviceControl ] && [ "$2" = uninstall ]; then rm -f "$TEST_UNIT"; exit 0; fi
   if [ "$1" = --serviceControl ] && [ "$2" = start ]; then exit "${{START_FAIL:-0}}"; fi
   printf '%s\\n' "$0" >> "$TEST_ACTIONS"
   if [ '{app}' = ddnsto ]; then mkdir -p /etc/ddnsto; printf '%s\\n' "$2" > /etc/ddnsto/ddnsto-config.json; fi
   [ "${{FALSE_SUCCESS:-0}}" = 0 ] || exit 0
   # Real DDNSTO reports OK without rewriting an existing service definition.
   if [ '{app}' = ddnsto ] && [ -f "$TEST_UNIT" ]; then exit 0; fi
   printf '[Unit]\\nConditionFileIsExecutable=%s\\n[Service]\\nExecStart=%s "run"\\n' "$0" "$0" > "$TEST_UNIT"
   if [ '{version}' = 2.0.0 ] && [ "${{BLOCK_REGISTER:-0}}" = 1 ]; then
       sleep 60 &
       child=$!
       printf '%s\\n' "$child" > "$TEST_SLEEP_PID"
       : > "$TEST_READY"
       wait "$child"
   fi
   [ '{version}' != 2.0.0 ] || exit "${{INSTALL_FAIL:-0}}"
   exit 0 ;;
esac
'''


def inside():
    os.umask(0o022)
    sys.path.insert(0, '/source/tests')
    from tls_fixture import generate_certificate
    native = '/tools/zsetup'
    assert subprocess.check_output([native, 'storage', '/opt', 'get', 'system_protected']) == b'true\n'
    with tempfile.TemporaryDirectory(prefix='service-suite-') as name:
        root = Path(name); generate_certificate(root)
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(root / 'server.crt', root / 'server.key')
        server.socket = tls.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            bindir = root / 'bin'; bindir.mkdir()
            native_version = subprocess.check_output([native, '--version'], text=True).strip().removeprefix('zsetup ')
            stable = root / 'stable'; stable.write_text(native_version + '\n')
            executable(bindir / 'curl', '''#!/bin/sh
out=; url=
while [ "$#" -gt 0 ]; do
 [ "$1" != -o ] || { shift; out=$1; shift; continue; }
 case "$1" in https://*) url=$1 ;; esac
 shift
done
case "$url" in */zsetup/stable) cp "$TEST_STABLE" "$out" ;; *) exit 97 ;; esac
''')
            executable(bindir / 'systemctl', '''#!/bin/sh
printf 'manager %s\n' "$*" >> "$TEST_ACTIONS"
case "$1" in
 is-active) exit "${HEALTH_FAIL:-0}" ;;
 stop) exit "${STOP_FAIL:-0}" ;;
 start) exit "${MANAGER_START_FAIL:-0}" ;;
 show) [ ! -f "$TEST_UNIT" ] || printf '%s\n' "$TEST_UNIT" ;;
esac
''')
            for app in ('ddnsto', 'linkease'):
                if os.environ.get('ZSETUP_TEST_APP') not in ('', None, app): continue
                case = root / app; case.mkdir()
                prefix = case / '程序 space %n $literal "quote" apostrophe\'' / app
                home = case / 'home'; home.mkdir()
                unit = Path('/etc/systemd/system') / f'com.linkease.{"ddnstoshell" if app == "ddnsto" else "linkeasedaemon"}.service'
                script = ROOT / app / f'{app}-install.sh'
                entry = f'{app}/storage-test/{app}-install.sh'
                Handler.bodies[f'/binary/{entry}'] = script.read_bytes()
                base = f'https://127.0.0.1:{server.server_address[1]}/binary'
                config = case / 'config.json'
                config.write_text(json.dumps({'schema_version':1,'config_version':'service-storage',
                    'source_groups':[{'id':'fixture','primary_bases':[base]}],
                    'stable_zsetup':{'version':native_version,'source_group':'fixture','artifacts':[{'arch':'x86_64','path':'unused','sha256':'00'*32,'size':1}]},
                    'installers':[{'application':app,'os':'*','package_manager':'*','arch':'*','source_group':'fixture','path':entry,'sha256':hashlib.sha256(script.read_bytes()).hexdigest(),'size':script.stat().st_size,'background':False,'min_version':native_version}]}))
                env = os.environ | {'HOME':str(home), 'PATH':f'{bindir}:/usr/bin:/bin',
                    'ZSETUP_BIN':native, 'ZSETUP_INSTALLER_MODE':'1', 'ZSETUP_OS':'ubuntu',
                    'ZSETUP_PACKAGE_MANAGER':'apt', 'ZSETUP_ARCH':'x86_64',
                    'ZSETUP_SOURCE_BASES':f'https://127.0.0.1:{server.server_address[1]}/binary',
                    'ZSETUP_SOURCE_FALLBACK':'', 'ZSETUP_CA_FILE':str(root / 'ca.crt'),
                    'ZSETUP_CONFIG':str(config),'ZSETUP_CONFIG_CACHE':str(case / 'config-cache'),'ZSETUP_MANAGED_ROOT':str(case / 'managed'),
                    'ZSETUP_ROOT':str(case / 'bootstrap'),'ZSETUP_BOOTSTRAP_BASES':base,'TEST_STABLE':str(stable),
                    'ZSETUP_INSTALL_PREFIX':str(prefix), 'TEST_UNIT':str(unit), 'TEST_ACTIONS':str(case / 'actions'), 'TEST_RUN_PATH':str(case / 'run-path')}
                for version in ('1.0.0', '2.0.0', '3.0.0'):
                    stream = io.BytesIO()
                    with tarfile.open(fileobj=stream, mode='w:gz') as tar:
                        for binary in ([app] if app == 'ddnsto' else [app, 'heif-converter', 'linkease-media']):
                            body = product(app, version).encode() if binary == app else b'#!/bin/sh\nexit 0\n'
                            name = f'ddnsto-standard-{version}/{binary}.x86_64' if app == 'ddnsto' else f'linkease-binary-{version}/{binary}.x86_64'
                            info = tarfile.TarInfo(name); info.size = len(body); tar.addfile(info, io.BytesIO(body))
                    folder = '/binary/ddnsto/linux-binary' if app == 'ddnsto' else f'/binary/LinkEase/LinuxStorage/{version}'
                    archive = f'ddnsto-standard-{version}.tar.gz' if app == 'ddnsto' else f'linkease-binary-{version}.tar.gz'
                    files = {archive:stream.getvalue()}
                    if app == 'linkease':
                        stream = io.BytesIO()
                        with zipfile.ZipFile(stream, 'w') as zip:
                            zip.writestr('amd64/bin/linkmount_bin', b'mount fixture')
                            zip.writestr('amd64/bin/lib/libfixture.so', b'library fixture')
                        files['amd64.zip'] = stream.getvalue()
                    for filename, body in files.items(): Handler.bodies[f'{folder}/{filename}'] = body
                    sums = ''.join(f'{hashlib.sha256(body).hexdigest()}  {filename}\n' for filename, body in files.items()).encode()
                    if app == 'ddnsto': Handler.bodies[f'{folder}/SHA256SUMS'] = Handler.bodies.get(f'{folder}/SHA256SUMS', b'') + sums
                    else: Handler.bodies[f'{folder}/SHA256SUMS'] = sums
                def run(version='1.0.0', changes=None, extra=(), mode='ready'):
                    args = ['--token', (changes or {}).get('TEST_TOKEN', '令牌 space $literal')] if app == 'ddnsto' else ['--version', version]
                    command = [native,'install',app,'--foreground','--'] if mode == 'indexed' else ['sh',str(script)]
                    return subprocess.run([*command, *extra, *args], env=env | {'DDNSTO_VERSION':version,'ZSETUP_INSTALLER_MODE':'0' if mode == 'direct' else '1'} | (changes or {}), text=True, capture_output=True, timeout=30)
                first = run(mode='direct', extra=['--installer-prefix',str(prefix),'--'])
                assert first.returncode == 0, first
                assert not Handler.counts.get(f'/binary/{entry}'), 'running script downloaded itself'
                installed = prefix / 'current/bin' / app
                assert installed.is_file(), installed
                verified_unit = subprocess.run(['systemd-analyze', 'verify', str(unit)], cwd='/', text=True, capture_output=True)
                assert verified_unit.returncode == 0, verified_unit
                wrapper = subprocess.run(['sh', str(prefix / 'current/bin/.service-run')], env=env, text=True, capture_output=True, timeout=5)
                assert wrapper.returncode == 0 and (case / 'run-path').read_text().strip() == str(installed.resolve()), wrapper
                assert (home / '.local/bin' / app).resolve() == installed.resolve()
                assert not list((prefix / '.staging').glob('.transaction.*'))
                if app == 'linkease':
                    library = prefix / 'current/bin/linkmount/lib/libfixture.so'
                    library.chmod(0o666)
                    unsafe = run()
                    assert unsafe.returncode == 12, unsafe
                    library.chmod(0o755)
                counts = dict(Handler.counts)
                indexed = run(mode='indexed')
                assert indexed.returncode == 0, indexed
                assert Handler.counts[f'/binary/{entry}'] == 1
                assert all(Handler.counts[k] == count for k, count in counts.items() if not k.endswith('SHA256SUMS'))
                old = installed.resolve()
                old_config = Path('/etc/ddnsto/ddnsto-config.json').read_bytes() if app == 'ddnsto' else None
                for failure in ('VERSION_FAIL', 'INSTALL_FAIL', 'HEALTH_FAIL'):
                    bad = run('2.0.0', {failure:'37', 'TEST_TOKEN':'replacement token'})
                    assert bad.returncode != 0 and installed.resolve() == old, (failure, bad)
                    assert (prefix / 'current/bin' / app).resolve() == old
                    if app == 'ddnsto': assert Path('/etc/ddnsto/ddnsto-config.json').read_bytes() == old_config
                # Previously separate business regressions: stop-before-change,
                # malformed arguments and archive traversal never mutate service.
                stopped = run(changes={'STOP_FAIL':'38'})
                assert stopped.returncode == 38 and installed.resolve() == old, stopped
                for extra in (['--not-a-business-option'], ['--installer-scope','invalid']):
                    before=(case/'actions').read_bytes()
                    bad=run(extra=extra)
                    assert bad.returncode==2 and (case/'actions').read_bytes()==before, bad
                if app=='ddnsto':
                    assert run(extra=['--force-version','lite']).returncode==2
                    assert run(extra=['--verify-status']).returncode==2
                    missing=subprocess.run(['sh',str(script)],env=env,text=True,capture_output=True,timeout=10)
                    assert missing.returncode==2, missing
                else:
                    zip_path='/binary/LinkEase/LinuxStorage/2.0.0/amd64.zip'
                    sum_path='/binary/LinkEase/LinuxStorage/2.0.0/SHA256SUMS'
                    original_zip, original_sums=Handler.bodies[zip_path],Handler.bodies[sum_path]
                    stream=io.BytesIO()
                    with zipfile.ZipFile(stream,'w') as zip: zip.writestr('../escape',b'invalid')
                    bad_zip=stream.getvalue(); Handler.bodies[zip_path]=bad_zip
                    Handler.bodies[sum_path]=original_sums.replace(hashlib.sha256(original_zip).hexdigest().encode(),hashlib.sha256(bad_zip).hexdigest().encode())
                    before=(case/'actions').read_bytes()
                    traversal=run('2.0.0')
                    read_only=('manager show ', 'manager is-active ', 'manager is-enabled ')
                    mutations=lambda data:[line for line in data.decode().splitlines() if not line.startswith(read_only)]
                    assert traversal.returncode==11 and mutations((case/'actions').read_bytes())==mutations(before),traversal
                    assert not (root/'escape').exists()
                    Handler.bodies[zip_path],Handler.bodies[sum_path]=original_zip,original_sums
                false = run('2.0.0', {'FALSE_SUCCESS':'1'})
                assert false.returncode != 0 and installed.resolve() == old, false
                # Root coordinator cancellation joins the native register tree,
                # then restores service/config. Another staging root must not
                # bypass the destination lock while registration is blocked.
                ready = case / 'ready'; sleeper = case / 'sleep-pid'
                blocked_args = ['--token','replacement token'] if app == 'ddnsto' else ['--version','2.0.0']
                proc = subprocess.Popen(['sh',str(script),*blocked_args], env=env | {'DDNSTO_VERSION':'2.0.0', 'BLOCK_REGISTER':'1', 'TEST_READY':str(ready), 'TEST_SLEEP_PID':str(sleeper)}, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    deadline = time.monotonic() + 15
                    while not ready.exists() and proc.poll() is None and time.monotonic() < deadline: time.sleep(.02)
                    assert ready.exists(), proc.communicate(timeout=2)
                    concurrent = run('2.0.0', extra=['--installer-work-dir',str(case / 'other-staging')])
                    assert concurrent.returncode == 2 and proc.poll() is None, concurrent
                    proc.send_signal(signal.SIGTERM)
                    out, err = proc.communicate(timeout=15)
                    assert proc.returncode == 143 and installed.resolve() == old, (proc.returncode, out, err)
                    assert not Path('/proc',sleeper.read_text().strip()).exists()
                    assert not list((prefix / '.staging').iterdir())
                    assert not list((case / 'other-staging').iterdir())
                    assert not (prefix / '.service-lock').exists()
                    if app == 'ddnsto': assert Path('/etc/ddnsto/ddnsto-config.json').read_bytes() == old_config
                finally:
                    if proc.poll() is None: proc.terminate(); proc.communicate(timeout=15)
                recovery=run('2.0.0',{'MANAGER_START_FAIL':'37'})
                assert recovery.returncode==37 and 'recovery incomplete' in recovery.stderr,recovery
                assert (prefix/'.service-lock').exists()
                retained=list((prefix/'.staging').glob('.transaction.*'))
                assert len(retained)==1 and (retained[0]/'old-unit').is_file()
                assert installed.resolve()==old
                # The test operator performs manual recovery only in this private
                # fixture after all native children have returned/joined.
                shutil.rmtree(prefix/'versions/2.0.0')
                shutil.rmtree(retained[0]); shutil.rmtree(prefix/'.staging/.install-lock')
                shutil.rmtree(prefix/'.service-lock')
                second = run('2.0.0'); assert second.returncode == 0, second
                third = run('3.0.0'); assert third.returncode == 0, third
                assert sorted(p.name for p in (prefix / 'versions').iterdir()) == ['2.0.0', '3.0.0']
                bg_args=['--token','background token'] if app=='ddnsto' else ['--version','3.0.0']
                background=subprocess.run([native,'install',app,'--background','--',*bg_args],env=env|{'DDNSTO_VERSION':'3.0.0'},text=True,capture_output=True,timeout=10)
                assert background.returncode==0,background
                fields=dict(field.split('=',1) for field in shlex.split(background.stdout))
                result=Path(fields['result']); deadline=time.monotonic()+15
                while not result.exists() and time.monotonic()<deadline: time.sleep(.05)
                assert result.read_text().strip()=='0',Path(fields['log']).read_text()
                assert '[4/4]' in Path(fields['log']).read_text()
                assert run(extra=['--installer-scope','user']).returncode == 2
                # Non-systemd is an explicitly deferred mapping, with no unit mutation.
                actions = (case / 'actions').read_text()
                Path('/run/systemd/system').rmdir()
                try:
                    unsupported = run(mode='indexed')
                    assert unsupported.returncode == 2 and 'legacy' in unsupported.stderr, unsupported
                    assert (case / 'actions').read_text() == actions
                finally: Path('/run/systemd/system').mkdir()
                # Unknown installation/service must never be stopped or overwritten.
                foreign = case / 'foreign'; foreign.mkdir(); (foreign / 'foreign').write_text('unowned')
                before = (case / 'actions').read_text()
                refused = run(changes={'ZSETUP_INSTALL_PREFIX':str(foreign)})
                assert refused.returncode != 0 and (case / 'actions').read_text() == before
                assert (foreign / 'foreign').read_text() == 'unowned'
                unit.unlink()
                if app == 'ddnsto': Path('/etc/ddnsto/ddnsto-config.json').unlink()
            print('service storage: two apps, protected paths, bounded streams, cache, health, rollback, versions, conflicts passed')
        finally:
            server.shutdown(); server.server_close(); thread.join(timeout=2)


if __name__ == '__main__':
    if sys.argv[1] == '--inside': inside()
    else: jail(Path(sys.argv[1]).resolve())
