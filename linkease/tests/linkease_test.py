#!/usr/bin/env python3
"""LinkEase real-downloader tests against isolated products and service/package adapters."""
import hashlib
import http.server
import io
import json
import os
from pathlib import Path
import ssl
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import signal
import shutil
import zipfile

ROOT = Path(__file__).resolve().parents[2]
ZSETUP = Path(sys.argv[1]).resolve()
SCRIPT = ROOT / 'linkease/linkease-install.sh'


def program(kind):
    return f'''#!/bin/sh
case "$1" in
 showVersion) echo 'LinkEase fixture {kind}'; exit "${{VERSION_FAIL:-0}}" ;;
 --serviceControl)
   printf '{kind} service %s\\n' "$2" >> "$TEST_LOG"
   case "$2" in
     uninstall) rm -f "$SERVICE_REGISTRY" ;;
     install) [ ! -e "$SERVICE_REGISTRY" ] || exit 41; : > "$SERVICE_REGISTRY" ;;
   esac
   if [ '{kind}' = new ]; then
     case "$2" in install) exit "${{INSTALL_FAIL:-0}}" ;; start) exit "${{START_FAIL:-0}}" ;; esac
   fi
   if [ '{kind}' = old ] && [ "$2" = start ]; then exit "${{OLD_START_FAIL:-0}}"; fi ;;
esac
'''.encode()


def executable(path, body):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(body if isinstance(body, bytes) else body.encode())
    path.chmod(0o755)


def archive(version):
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode='w:gz') as tar:
        for arch in ('x86_64', 'aarch64', 'arm'):
            for name in ('linkease', 'heif-converter', 'linkease-media'):
                body = program('new') if name == 'linkease' else b'#!/bin/sh\nexit 0\n'
                info = tarfile.TarInfo(f'linkease-binary-{version}/{name}.{arch}')
                info.size = len(body); info.mode = 0o755
                tar.addfile(info, io.BytesIO(body))
    return stream.getvalue()


def mount_zip(arch):
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, 'w') as zip:
        zip.writestr(f'{arch}/bin/linkmount_bin', b'fixture mount')
        zip.writestr(f'{arch}/bin/lib/libfixture.so', b'fixture library')
    return stream.getvalue()


class Handler(http.server.BaseHTTPRequestHandler):
    bodies = {}; counts = {}; broken = set()
    def do_GET(self):
        cls = type(self)
        cls.counts[self.path] = cls.counts.get(self.path, 0) + 1
        body = cls.bodies.get(self.path)
        if body is None or self.path in cls.broken:
            self.send_error(404); return
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def log_message(self, *_):
        pass


def main():
    assert SCRIPT.is_file(), 'LinkEase canonical installer missing'
    with tempfile.TemporaryDirectory(prefix='linkease-test-') as temporary:
        root = Path(temporary)
        cert, key = root / 'server.crt', root / 'server.key'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-subj', '/CN=127.0.0.1', '-addext', 'subjectAltName=IP:127.0.0.1', '-keyout', str(key), '-out', str(cert)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); tls.load_cert_chain(cert, key)
        server.socket = tls.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            base = f'https://127.0.0.1:{server.server_address[1]}/binary'
            bodies = Handler.bodies
            bodies['/binary/linkease/0.1.5/linkease-install.sh'] = SCRIPT.read_bytes()
            bodies['/binary/zsetup/stable'] = b'0.2.4\n'
            for version in ('1.7.5', '2.0.0'):
                folder = f'/binary/LinkEase/LinuxStorage/{version}'
                files = {f'linkease-binary-{version}.tar.gz': archive(version)}
                for arch in ('amd64', 'arm64', 'arm'):
                    files[f'{arch}.zip'] = mount_zip(arch)
                for name, body in files.items(): bodies[f'{folder}/{name}'] = body
                bodies[f'{folder}/SHA256SUMS'] = ''.join(f'{hashlib.sha256(body).hexdigest()}  {name}\n' for name, body in files.items()).encode()
            bodies['/binary/LinkEase/Openwrt/VERSION'] = b'2.0.0\n'
            folder = '/binary/LinkEase/Openwrt/2.0.0'
            files = {name: f'fixture {name}'.encode() for name in (
                'linkease_x86_64.ipk', 'linkease_aarch64.ipk', 'linkease_arm.ipk',
                'luci-app-linkease.ipk', 'luci-i18n-linkease-zh-cn.ipk',
                'linkmount_x86_64.ipk', 'ffmpeg-remux_x86_64.ipk',
                'linkmount_aarch64.ipk', 'ffmpeg-remux_aarch64.ipk')}
            for name, body in files.items(): bodies[f'{folder}/{name}'] = body
            bodies[f'{folder}/SHA256SUMS'] = ''.join(f'{hashlib.sha256(body).hexdigest()}  {name}\n' for name, body in files.items()).encode()
            fakebin = root / 'bin'; fakebin.mkdir()
            for name in ('awk', 'sed', 'curl', 'wget'):
                executable(fakebin/name, '#!/bin/sh\nexit 97\n')
            stable = root/'stable'; stable.write_text('0.2.4\n')
            # First bootstrap may use curl; business requests must use the real zsetup.
            executable(fakebin/'curl', r"""#!/bin/sh
out=; url=
while [ "$#" -gt 0 ]; do
    [ "$1" != -o ] || { shift; out=$1; shift; continue; }
    case "$1" in https://*) url=$1 ;; esac
    shift
done
case "$url" in */binary/zsetup/stable) cp "$TEST_STABLE" "$out" ;; *) exit 97 ;; esac
""")
            executable(fakebin/'opkg' , '#!/bin/sh\nprintf "opkg %s\\n" "$*" >> "$TEST_LOG"\nexit "${PKG_FAIL:-0}"\n')
            executable(fakebin/'linkease', '#!/bin/sh\necho "OpenWrt fixture"\n')
            executable(fakebin/'systemctl', '#!/bin/sh\nprintf "systemctl %s\\n" "$*" >> "$TEST_LOG"\nexit "${STOP_FAIL:-0}"\n')
            config = {'schema_version':1, 'config_version':'linkease-fixture',
                      'source_groups':[{'id':'fixture','primary_bases':[base]}],
                      'stable_zsetup':{'version':'0.2.4','source_group':'fixture','artifacts':[{'arch':'x86_64','path':'zsetup/unused','sha256':'00'*32,'size':1}]},
                      'installers':[{'application':'linkease','os':'*','package_manager':'*','arch':'*','source_group':'fixture','path':'linkease/0.1.5/linkease-install.sh','sha256':hashlib.sha256(SCRIPT.read_bytes()).hexdigest(),'size':SCRIPT.stat().st_size,'background':False,'min_version':'0.2.4'}]}
            cfg=root/'config.json'; cfg.write_text(json.dumps(config))
            env=os.environ | {'PATH':f'{fakebin}:/usr/bin:/bin','ZSETUP_BIN':str(ZSETUP),'ZSETUP_CA_FILE':str(cert), 'ZSETUP_CONFIG':str(cfg), 'ZSETUP_CONFIG_CACHE':str(root/'config-cache'), 'ZSETUP_MANAGED_ROOT':str(root/'managed'),
                              'ZSETUP_SOURCE_BASES':base,'ZSETUP_SOURCE_FALLBACK':'','ZSETUP_BOOTSTRAP_BASES':base,
                              'ZSETUP_ROOT':str(root/'bootstrap'),'ZSETUP_WORK_DIR':str(root/'work'),
                              'ZSETUP_OS':'ubuntu','ZSETUP_PACKAGE_MANAGER':'apt','ZSETUP_ARCH':'x86_64',
                              'LINKEASE_APP_DIR':str(root/'installed'),'SERVICE_REGISTRY':str(root/'service-registration'),'TEST_STABLE':str(stable),'TEST_LOG':str(root/'log')}
            (root/'installed').mkdir()
            def run(args=(), overrides=None, indexed=False):
                cmd = [str(ZSETUP),'install','linkease','--foreground','--',*args] if indexed else ['sh',str(SCRIPT),*args]
                return subprocess.run(cmd, env=env | (overrides or {}), text=True, capture_output=True, timeout=30)
            def log():
                return (root/'log').read_text() if (root/'log').exists() else ''
            first = run()
            assert first.returncode == 0, first
            assert not Handler.counts.get('/binary/linkease/0.1.5/linkease-install.sh',0), 'running script must not download itself'
            for step in ('[1/4]','[2/4]','[3/4]','[4/4]'): assert step in first.stderr, first.stderr
            assert (root/'installed/linkmount/lib/libfixture.so').read_bytes() == b'fixture library'
            for name in ('linkease','heif-converter','linkease-media'): assert (root/'installed'/name).is_file()
            downloads = Handler.counts['/binary/LinkEase/LinuxStorage/1.7.5/linkease-binary-1.7.5.tar.gz']
            second=run(indexed=True)
            assert second.returncode==0 and 'cached' in second.stderr, second
            assert Handler.counts['/binary/LinkEase/LinuxStorage/1.7.5/linkease-binary-1.7.5.tar.gz']==downloads
            explicit=run(['--version','2.0.0'], indexed=True)
            assert explicit.returncode==0, explicit
            assert Handler.counts.get('/binary/LinkEase/LinuxStorage/2.0.0/linkease-binary-2.0.0.tar.gz')
            for arch in ('aarch64','armv7'):
                selected=run(['--version','2.0.0'], {'ZSETUP_INSTALLER_MODE':'1','ZSETUP_ARCH':arch})
                assert selected.returncode==0, selected
            fallback=run(['--version','2.0.0'], {'ZSETUP_INSTALLER_MODE':'1','ZSETUP_SOURCE_BASES':base+'/missing','ZSETUP_SOURCE_FALLBACK':base,'ZSETUP_WORK_DIR':str(root/'fallback-work')})
            assert fallback.returncode==0, fallback
            assert Handler.counts.get('/binary/missing/LinkEase/LinuxStorage/2.0.0/SHA256SUMS')
            for args,overrides in ((['--version'],{}),(['--bogus'],{}),(['--version','../escape'],{}),([] ,{'ZSETUP_ARCH':'mipsel'}),([] ,{'ZSETUP_OS':'openwrt','ZSETUP_PACKAGE_MANAGER':'apk'})):
                before=log()
                bad=run(args, {'ZSETUP_INSTALLER_MODE':'1'}|overrides)
                assert bad.returncode==2 and log()==before, bad
            # Pre-install version or digest failures cannot stop or replace an existing service.
            before=(root/'installed/linkease').read_bytes(); actions=log()
            bad=run(overrides={'ZSETUP_INSTALLER_MODE':'1','VERSION_FAIL':'31'})
            assert bad.returncode==31 and (root/'installed/linkease').read_bytes()==before and log()==actions, bad
            tarpath='/binary/LinkEase/LinuxStorage/1.7.5/linkease-binary-1.7.5.tar.gz'
            original=bodies[tarpath]; bodies[tarpath]=b'corrupt downloaded product'
            bad=run(overrides={'ZSETUP_INSTALLER_MODE':'1','ZSETUP_WORK_DIR':str(root/'fresh-work')})
            assert bad.returncode!=0 and log()==actions and (root/'installed/linkease').read_bytes()==before, bad
            bodies[tarpath]=original
            # Replacement failures restore all old files plus the old service.
            for failure in ('START_FAIL','INSTALL_FAIL'):
                executable(root/'installed/linkease', program('old'))
                (root/'installed/heif-converter').write_bytes(b'old converter')
                (root/'installed/linkease-media').write_bytes(b'old media')
                (root/'installed/linkmount/linkmount_bin').write_bytes(b'old mount')
                bad=run(overrides={'ZSETUP_INSTALLER_MODE':'1',failure:'37'})
                assert bad.returncode==37, bad
                assert (root/'installed/linkease').read_bytes()==program('old')
                assert (root/'installed/heif-converter').read_bytes()==b'old converter'
                assert (root/'installed/linkease-media').read_bytes()==b'old media'
                assert (root/'installed/linkmount/linkmount_bin').read_bytes()==b'old mount'
                assert 'old service start' in log(), log()
            failed_recovery=run(overrides={'ZSETUP_INSTALLER_MODE':'1','START_FAIL':'37','OLD_START_FAIL':'39'})
            assert failed_recovery.returncode==37 and 'recovery files retained' in failed_recovery.stderr, failed_recovery
            backups=list((root/'installed').glob('.linkease-backup.*'))
            assert len(backups)==1 and (backups[0]/'linkease').read_bytes()==program('old')
            # The test operator reaps the deliberately retained recovery copy after asserting it.
            shutil.rmtree(backups[0])
            actions=log(); before=(root/'installed/linkease').read_bytes()
            bad=run(overrides={'ZSETUP_INSTALLER_MODE':'1','STOP_FAIL':'38'})
            assert bad.returncode==38 and (root/'installed/linkease').read_bytes()==before, bad
            first_target=root/'first-failure'; first_target.mkdir()
            bad=run(overrides={'ZSETUP_INSTALLER_MODE':'1','LINKEASE_APP_DIR':str(first_target),'SERVICE_REGISTRY':str(root/'first-registration'),'START_FAIL':'37'})
            assert bad.returncode==37 and not list(first_target.iterdir()), bad
            # Validate zip member paths without allowing archive writes outside staging.
            stream=io.BytesIO()
            with zipfile.ZipFile(stream,'w') as zip: zip.writestr('amd64/bin/../../outside',b'escape')
            zipname='/binary/LinkEase/LinuxStorage/1.7.5/amd64.zip'; oldzip=bodies[zipname]
            sumsname='/binary/LinkEase/LinuxStorage/1.7.5/SHA256SUMS'; oldsums=bodies[sumsname]
            bodies[zipname]=stream.getvalue()
            bodies[sumsname]=oldsums.replace(hashlib.sha256(oldzip).hexdigest().encode(),hashlib.sha256(stream.getvalue()).hexdigest().encode())
            actions=log()
            bad=run(overrides={'ZSETUP_INSTALLER_MODE':'1'})
            assert bad.returncode==11 and log()==actions, bad
            bodies[zipname]=oldzip; bodies[sumsname]=oldsums
            # OpenWrt matrix: unsupported apk/MIPS never claims support; all assets precede opkg.
            for arch,packages in (('x86_64',5),('aarch64',5),('armv7',3)):
                actions=log()
                good=run(overrides={'ZSETUP_INSTALLER_MODE':'1','ZSETUP_OS':'openwrt','ZSETUP_PACKAGE_MANAGER':'opkg','ZSETUP_ARCH':arch})
                assert good.returncode==0, good
                assert log()[len(actions):].count('opkg install')==packages, log()
            missing='/binary/LinkEase/Openwrt/2.0.0/linkmount_x86_64.ipk'
            Handler.broken.add(missing); actions=log()
            bad=run(overrides={'ZSETUP_INSTALLER_MODE':'1','ZSETUP_OS':'openwrt','ZSETUP_PACKAGE_MANAGER':'opkg','ZSETUP_WORK_DIR':str(root/'openwrt-fresh')})
            assert bad.returncode!=0 and log()==actions, bad
            Handler.broken.clear()
            pkg_failure=run(overrides={'ZSETUP_INSTALLER_MODE':'1','ZSETUP_OS':'openwrt','ZSETUP_PACKAGE_MANAGER':'opkg','PKG_FAIL':'23'})
            assert pkg_failure.returncode==23, pkg_failure
            # Existing detached execution protocol supplies the final installation exit status.
            background=subprocess.run([str(ZSETUP),'install','linkease','--background','--','--version','2.0.0'],env=env,text=True,capture_output=True,timeout=10)
            assert background.returncode==0, background
            fields=dict(item.split('=',1) for item in background.stdout.strip().split())
            result_file=Path(fields['result']); deadline=time.monotonic()+10
            while not result_file.exists() and time.monotonic()<deadline: time.sleep(0.01)
            assert result_file.read_text().strip()=='0'
            assert '[4/4]' in Path(fields['log']).read_text()
            # A waiting business download is interrupted without retaining its transaction.
            blocked=root/'blocked-zsetup'; ready=root/'download-ready'
            executable(blocked,'#!/bin/sh\nif [ "$1" = download ]; then : > "$DOWNLOAD_READY"; sleep 1; exit 13; fi\nexit 97\n')
            process=subprocess.Popen(['sh',str(SCRIPT)],env=env|{'ZSETUP_INSTALLER_MODE':'1','ZSETUP_BIN':str(blocked),'DOWNLOAD_READY':str(ready)},stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            deadline=time.monotonic()+5
            while not ready.exists() and time.monotonic()<deadline: time.sleep(0.01)
            assert ready.exists()
            process.send_signal(signal.SIGTERM); _out,_err=process.communicate(timeout=5)
            assert process.returncode==143, (process.returncode,_err)
            # Every failed and successful transaction is reaped, backups only remain on rollback failure.
            assert not list(root.rglob('.transaction.*'))
            assert not list((root/'installed').glob('.linkease-*'))
            print('LinkEase: HTTPS direct/index, architecture, parameters, cache, progress, pre-install failures, full Linux rollback, opkg, fallback, background result and signal cleanup passed')
        finally:
            server.shutdown(); server.server_close(); thread.join(timeout=2)

if __name__ == '__main__':
    main()
