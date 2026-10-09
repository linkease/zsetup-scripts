#!/usr/bin/env python3
"""Real zsetup HTTPS downloads; fake PVE/product commands, no host installation."""
import hashlib
import http.server
import json
import os
from pathlib import Path
import signal
import ssl
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'fastpve/fastpve-install.sh'
ZSETUP = Path(sys.argv[1]).resolve()
PRODUCT = b'''#!/bin/sh
if [ "${1:-}" = version ]; then echo 'FastPVE fixture'; exit "${VERSION_FAIL:-0}"; fi
printf '<%s>' "$@" > "$TEST_OUTPUT"
exit "${PRODUCT_EXIT:-0}"
'''


def executable(path, body):
    path.write_bytes(body.encode() if isinstance(body, str) else body)
    path.chmod(0o755)


class Handler(http.server.BaseHTTPRequestHandler):
    bodies = {}; counts = {}; fresh = False
    def do_GET(self):
        cls = type(self)
        cls.counts[self.path] = cls.counts.get(self.path, 0) + 1
        body = cls.bodies.get(self.path)
        if body is None:
            self.send_error(404); return
        if self.path.endswith('/version.txt'):
            cls.fresh = self.headers.get('Cache-Control') == 'no-cache'
        self.send_response(200); self.send_header('Content-Length', str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def log_message(self, *_): pass


def main():
    assert SCRIPT.is_file(), 'FastPVE canonical installer missing'
    with tempfile.TemporaryDirectory(prefix='fastpve-test-') as temp:
        root = Path(temp); cert = root/'cert'; key = root/'key'
        subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1','-subj','/CN=127.0.0.1','-addext','subjectAltName=IP:127.0.0.1','-keyout',str(key),'-out',str(cert)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        server = http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
        tls=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); tls.load_cert_chain(cert,key)
        server.socket=tls.wrap_socket(server.socket,server_side=True)
        thread=threading.Thread(target=server.serve_forever,daemon=True); thread.start()
        try:
            base=f'https://127.0.0.1:{server.server_address[1]}/binary'
            entry='/binary/fastpve/0.1.6/fastpve-install.sh'
            Handler.bodies[entry]=SCRIPT.read_bytes()
            def publish(version='0.1.8', product=PRODUCT):
                Handler.bodies['/binary/fastpve/version.txt']=(f'VERSION={version}\nFASTPVE_SHA256={hashlib.sha256(product).hexdigest()}\n').encode()
                Handler.bodies[f'/binary/fastpve/FastPVE-{version}']=product
            publish()
            fakebin=root/'bin'; fakebin.mkdir()
            for name in ('awk','sed','wget','sha256sum','shasum','openssl','opkg','apt','systemctl'):
                executable(fakebin/name,'#!/bin/sh\nexit 97\n')
            executable(fakebin/'pveversion','#!/bin/sh\necho "pve-manager/8.4.1/fixture"\nexit "${PVE_FAIL:-0}"\n')
            executable(fakebin/'id','#!/bin/sh\necho "${TEST_UID:-0}"\n')
            stable=root/'stable'; stable.write_text('0.2.4\n')
            executable(fakebin/'curl',r'''#!/bin/sh
out=; url=
while [ "$#" -gt 0 ]; do
    [ "$1" != -o ] || { shift; out=$1; shift; continue; }
    case "$1" in https://*) url=$1 ;; esac
    shift
done
case "$url" in */binary/zsetup/stable) cp "$TEST_STABLE" "$out" ;; *) exit 97 ;; esac
''')
            # Wildcard selectors only in this fixture: host Ubuntu runs a mocked PVE.
            # Production selectors are separately checked as Debian/apt/x86_64 only.
            config={'schema_version':1,'config_version':'fastpve-fixture','source_groups':[{'id':'fixture','primary_bases':[base]}],
                    'stable_zsetup':{'version':'0.2.4','source_group':'fixture','artifacts':[{'arch':'x86_64','path':'zsetup/unused','sha256':'00'*32,'size':1}]},
                    'installers':[{'application':'fastpve','os':'*','package_manager':'*','arch':'x86_64','source_group':'fixture','path':'fastpve/0.1.6/fastpve-install.sh','sha256':hashlib.sha256(SCRIPT.read_bytes()).hexdigest(),'size':SCRIPT.stat().st_size,'background':False,'min_version':'0.2.4'}]}
            cfg=root/'config'; cfg.write_text(json.dumps(config))
            work=root/'work'; output=root/'args'
            env=os.environ | {'PATH':f'{fakebin}:/usr/bin:/bin','ZSETUP_BIN':str(ZSETUP),'ZSETUP_CA_FILE':str(cert),'ZSETUP_CONFIG':str(cfg),
                'ZSETUP_CONFIG_CACHE':str(root/'config-cache'),'ZSETUP_MANAGED_ROOT':str(root/'managed'),'ZSETUP_ROOT':str(root/'bootstrap'),
                'ZSETUP_WORK_DIR':str(work),'ZSETUP_ARCH':'x86_64','ZSETUP_PACKAGE_MANAGER':'apt','ZSETUP_OS':'debian',
                'ZSETUP_SOURCE_BASES':base,'ZSETUP_SOURCE_FALLBACK':'','ZSETUP_BOOTSTRAP_BASES':base,'TEST_STABLE':str(stable),'TEST_OUTPUT':str(output)}
            def run(args=(), overrides=None, indexed=False):
                command=[str(ZSETUP),'install','fastpve','--foreground','--',*args] if indexed else ['sh',str(SCRIPT),*args]
                return subprocess.run(command,env=env | (overrides or {}),capture_output=True,text=True,timeout=20)
            def clean():
                assert not list(work.glob('.transaction.*')), 'temporary transaction leaked'
            first=run(['one two','','--opaque'])
            assert first.returncode==0, first
            assert output.read_text()=='<one two><><--opaque>'
            assert not Handler.counts.get(entry), 'direct installer must not fetch itself'
            for step in ('[1/4]','[2/4]','[3/4]','[4/4]'): assert step in first.stderr,first.stderr
            assert Handler.fresh
            cached=work/'FastPVE-0.1.8'; assert cached.read_bytes()==PRODUCT
            product_path='/binary/fastpve/FastPVE-0.1.8'
            downloads=Handler.counts[product_path]
            second=run(['indexed'],indexed=True)
            assert second.returncode==0 and 'cached' in second.stderr,second
            assert Handler.counts[product_path]==downloads and output.read_text()=='<indexed>'
            assert Handler.counts.get(entry), 'index must fetch verified installer'
            # Cache marker/size must agree; unmarked and truncated contents are re-fetched.
            cached.write_bytes(b'corrupt cache')
            assert run(indexed=True).returncode==0
            assert cached.read_bytes()==PRODUCT and Handler.counts[product_path]>downloads
            (work/'FastPVE-0.1.8.verified').unlink()
            before=Handler.counts[product_path]
            assert run().returncode==0 and Handler.counts[product_path]>before
            # All preflight errors fail before metadata/product requests or program launch.
            output.unlink(); before=sum(Handler.counts.values())
            for overrides in ({'ZSETUP_ARCH':'aarch64'},{'ZSETUP_PACKAGE_MANAGER':'opkg'},{'PVE_FAIL':'1'},{'TEST_UID':'1000'}):
                bad=run(overrides={'ZSETUP_INSTALLER_MODE':'1'} | overrides)
                assert bad.returncode==2 and not output.exists(),bad
                assert sum(Handler.counts.values())==before
            (fakebin/'pveversion').rename(fakebin/'pveversion.saved')
            bad=run(overrides={'ZSETUP_INSTALLER_MODE':'1'})
            assert bad.returncode==2 and sum(Handler.counts.values())==before,bad
            (fakebin/'pveversion.saved').rename(fakebin/'pveversion')
            clean()
            # Invalid metadata is never evaluated; old cache survives and menu never runs.
            for metadata in (b'VERSION=../escape\nFASTPVE_SHA256=00\n',b'VERSION=0.1.8\nFASTPVE_SHA256=00\n',Handler.bodies['/binary/fastpve/version.txt']+b'VERSION=0.1.8\n'):
                Handler.bodies['/binary/fastpve/version.txt']=metadata
                bad=run(indexed=True)
                assert bad.returncode==11 and cached.read_bytes()==PRODUCT and not output.exists(),bad
                clean()
            # Wrong bytes, HTTP downgrade, and a validly hashed but unusable new program.
            publish('0.1.9'); Handler.bodies['/binary/fastpve/FastPVE-0.1.9']=b'wrong bytes'
            bad=run(); assert bad.returncode!=0 and not output.exists(),bad
            assert cached.read_bytes()==PRODUCT and not (work/'FastPVE-0.1.9').exists(); clean()
            publish('0.1.9')
            bad=run(overrides={'VERSION_FAIL':'41'})
            assert bad.returncode==41 and not output.exists(),bad
            assert not (work/'FastPVE-0.1.9').exists(); clean()
            bad=run(overrides={'ZSETUP_INSTALLER_MODE':'1','ZSETUP_SOURCE_BASES':base.replace('https:','http:')})
            assert bad.returncode!=0 and not output.exists(),bad
            clean()
            # Version switching retains old immutable cache; business exit remains observable.
            new=run(['new'],indexed=True); assert new.returncode==0,new
            assert cached.read_bytes()==PRODUCT and (work/'FastPVE-0.1.9').is_file()
            result=run(['exit'],overrides={'PRODUCT_EXIT':'37'},indexed=True)
            assert result.returncode==37,result
            fallback=run(overrides={'ZSETUP_INSTALLER_MODE':'1','ZSETUP_SOURCE_BASES':base+'/missing','ZSETUP_SOURCE_FALLBACK':base,'ZSETUP_WORK_DIR':str(root/'fallback')})
            assert fallback.returncode==0,fallback
            assert Handler.counts.get('/binary/missing/fastpve/version.txt')
            # Background only proves native result propagation for a mock noninteractive program.
            launched=subprocess.run([str(ZSETUP),'install','fastpve','--background','--','background'],env=env | {'PRODUCT_EXIT':'38'},capture_output=True,text=True,timeout=20)
            assert launched.returncode==0,launched
            fields=dict(line.split('=',1) for line in launched.stdout.split() if '=' in line)
            result_path=Path(fields['result']); deadline=time.monotonic()+10
            while not result_path.exists() and time.monotonic()<deadline: time.sleep(.05)
            assert result_path.read_text().strip()=='38',result_path
            # Interrupted shell cleans its transaction and preserves verified cached product.
            blocker=root/'blocker'; ready=root/'ready'
            executable(blocker,f'#!/bin/sh\nif [ "$1" = download ]; then touch "{ready}"; sleep 1; exit 13; fi\nexec "{ZSETUP}" "$@"\n')
            process=subprocess.Popen(['sh',str(SCRIPT)],env=env | {'ZSETUP_INSTALLER_MODE':'1','ZSETUP_BIN':str(blocker)},stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            deadline=time.monotonic()+5
            while not ready.exists() and time.monotonic()<deadline: time.sleep(.02)
            assert ready.exists()
            process.send_signal(signal.SIGTERM); process.communicate(timeout=5)
            assert process.returncode==143,process.returncode
            clean(); assert cached.read_bytes()==PRODUCT
        finally:
            server.shutdown(); server.server_close(); thread.join(timeout=2)
    print('FastPVE: direct/index, native HTTPS/SHA, platform/root, opaque args, cache, failure/cancel cleanup, version, fallback, progress and exit/result passed')


if __name__=='__main__': main()
