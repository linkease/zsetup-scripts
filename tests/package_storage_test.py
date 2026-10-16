#!/usr/bin/env python3
"""Native HTTPS and filesystem policy; package managers/services are stubs."""
import hashlib
import http.server
import os
from pathlib import Path
import ssl
import subprocess
import sys
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT / 'tests'))
from service_storage_test import jail, executable, Handler
from tls_fixture import generate_certificate


def inside():
    os.umask(0o022)
    with tempfile.TemporaryDirectory(prefix='package-suite-') as name:
        root=Path(name); generate_certificate(root)
        server=http.server.ThreadingHTTPServer(('127.0.0.1',0), Handler)
        tls=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); tls.load_cert_chain(root/'server.crt',root/'server.key')
        server.socket=tls.wrap_socket(server.socket,server_side=True)
        thread=threading.Thread(target=server.serve_forever,daemon=True); thread.start()
        try:
            fake=root/'bin'; fake.mkdir()
            for manager in ('opkg','apk'):
                executable(fake/manager,'''#!/bin/sh
printf '%s|%s|%s\n' "${0##*/}" "$*" "$TMPDIR" >> "$TEST_LOG"
while [ "$#" -gt 0 ]; do
 case "$1" in --cache|--cache-dir|--tmp-dir|--lists-dir) shift 2 ;; *) break ;; esac
done
case "$1" in
 list-installed) echo 'luci-lua-runtime - fixture' ;;
 install|add) exit "${PKG_FAIL:-0}" ;;
esac
''')
            for command in ('ddnsto','linkease','uci','service','pgrep'):
                executable(fake/command, '#!/bin/sh\nexit 0\n')
            for app, managers, arches in [('ddnsto',('opkg','apk'),('x86_64','aarch64','armv7','mipsel')),('linkease',('opkg',),('x86_64','aarch64','armv7'))]:
                remote='ddnsto' if app=='ddnsto' else 'LinkEase'
                for manager in managers:
                    ext='ipk' if manager=='opkg' else 'apk'
                    variants=('lite','standard') if app=='ddnsto' else ('',)
                    for variant in variants:
                        pointer='openwrt/VERSION_LITE' if variant=='lite' else ('openwrt/VERSION' if app=='ddnsto' else 'Openwrt/VERSION')
                        Handler.bodies[f'/binary/{remote}/{pointer}']=b'4.2.3\n'
                        folder=f'openwrt/{variant}{"-apk" if manager=="apk" else ""}/4.2.3' if app=='ddnsto' else 'Openwrt/4.2.3'
                        files={}
                        for arch in arches:
                            pa='arm' if arch=='armv7' else arch
                            names=[f'{app}_{pa}.{ext}',f'luci-app-{app}.{ext}',f'luci-i18n-{app}-zh-cn.{ext}']
                            if app=='linkease' and arch in ('x86_64','aarch64'): names += [f'linkmount_{arch}.ipk',f'ffmpeg-remux_{arch}.ipk']
                            for filename in names: files[filename]=f'fixture {filename}'.encode()
                        for filename,data in files.items(): Handler.bodies[f'/binary/{remote}/{folder}/{filename}']=data
                        Handler.bodies[f'/binary/{remote}/{folder}/SHA256SUMS']=''.join(f'{hashlib.sha256(data).hexdigest()}  {filename}\n' for filename,data in files.items()).encode()
                    for arch in arches:
                        case=root/f'{app}-{manager}-{arch}'; case.mkdir()
                        prefix=case/'managed'; work=case/'下载 staging'; log=case/'actions'
                        env=os.environ | {'PATH':f'{fake}:/usr/bin:/bin','ZSETUP_BIN':'/tools/zsetup','ZSETUP_INSTALLER_MODE':'1',
                            'ZSETUP_OS':'openwrt','ZSETUP_PACKAGE_MANAGER':manager,'ZSETUP_ARCH':arch,
                            'ZSETUP_SOURCE_BASES':f'https://127.0.0.1:{server.server_port}/binary','ZSETUP_SOURCE_FALLBACK':'',
                            'ZSETUP_CA_FILE':str(root/'ca.crt'),'DDNSTO_MEM_MB':'512','TEST_LOG':str(log)}
                        script=ROOT/app/f'{app}-install.sh'
                        command=['sh',str(script),'--installer-prefix',str(prefix),'--installer-work-dir',str(work)]
                        good=subprocess.run(command,env=env,text=True,capture_output=True,timeout=30)
                        assert good.returncode==0,good
                        lines=log.read_text().splitlines()
                        assert all(str(work) in line for line in lines),lines
                        assert not list(work.iterdir()),list(work.iterdir())
                        assert 'cache' in lines[-1] and 'tmp' in lines[-1],lines
                        assert not any('/tmp/' in line for line in lines),lines
                        failed=subprocess.run(command,env=env|{'PKG_FAIL':'23'},text=True,capture_output=True,timeout=30)
                        assert failed.returncode==23,failed
                        assert not list(work.iterdir())
                        assert '23' in (prefix/'package-result').read_text()
                        assert not (prefix/'current').exists(), 'package error silently selected raw binaries'
                        # A complete digest failure must happen before any PM operation.
                        selected=f'openwrt/lite{"-apk" if manager=="apk" else ""}/4.2.3' if app=='ddnsto' else 'Openwrt/4.2.3'
                        sums=f'/binary/{remote}/{selected}/SHA256SUMS'
                        main=f'{app}_{"arm" if arch=="armv7" else arch}.{ext}'
                        original=Handler.bodies[sums]
                        digest=hashlib.sha256(Handler.bodies[f'/binary/{remote}/{selected}/{main}']).hexdigest().encode()
                        Handler.bodies[sums]=original.replace(digest,b'0'*64)
                        before=log.read_bytes()
                        corrupt=subprocess.run(command,env=env,text=True,capture_output=True,timeout=30)
                        assert corrupt.returncode==11 and log.read_bytes()==before,corrupt
                        assert not list(work.iterdir())
                        Handler.bodies[sums]=original
                if app=='linkease':
                    unsupported=subprocess.run(['sh',str(script)],env=env|{'ZSETUP_PACKAGE_MANAGER':'apk'},capture_output=True)
                    assert unsupported.returncode==2
            print('native packages: opkg/apk mappings, persistent PM cache/tmp/lists, bounded inputs, failure and cleanup passed')
        finally: server.shutdown(); server.server_close(); thread.join(timeout=2)


if __name__=='__main__':
    if sys.argv[1]=='--inside': inside()
    else: jail(Path(sys.argv[1]).resolve(), '/source/tests/package_storage_test.py')
