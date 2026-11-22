#!/usr/bin/env python3
"""Native HTTPS and filesystem policy; package managers/services are stubs."""
import hashlib
import http.server
import os
import re
import signal
import time
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
 list-installed)
  if [ \"${BLOCK_QUERY:-0}\" = 1 ]; then sleep 60 & child=$!; echo \"$child\" > \"$QUERY_CHILD\"; : > \"$QUERY_READY\"; wait \"$child\"; fi
  echo 'luci-lua-runtime - fixture'
  [ ! -f "$TEST_PACKAGE_STATE" ] || echo 'ddnsto - 4.2.8' ;;
 search) [ -f "$TEST_PACKAGE_STATE" ] && echo 'ddnsto - 4.2.8' ;;
 install|add)
  [ "${PKG_FAIL:-0}" = 0 ] || exit "$PKG_FAIL"
  case "$*" in *ddnsto_*)
    mkdir -p "${DDNSTO_CONFIG_PATH%/*}"
    printf "config ddnsto 'ddnsto'\n option token 'fixture-token'\n" > "$DDNSTO_CONFIG_PATH"
    chmod 0600 "$DDNSTO_CONFIG_PATH"
    : > "$TEST_PACKAGE_STATE" ;;
  esac ;;
 -q) [ "$2" = info ] && [ "$3" = --who-owns ] && [ -f "$TEST_PACKAGE_STATE" ] && echo ddnsto ;;
 info)
  if [ "${2:-}" = -e ]; then [ "$3" = luci-lua-runtime ];
  elif [ -f "$TEST_PACKAGE_STATE" ]; then printf 'luci-lua-runtime\nddnsto\n'; else echo luci-lua-runtime; fi ;;
esac
''')
            for command in ('ddnsto','linkease','service','pgrep'):
                executable(fake/command, '#!/bin/sh\nexit 0\n')
            executable(fake/'uci', '''#!/bin/sh
case "$*" in
 *'changes ddnsto') exit 0 ;;
 *"get ddnsto.@ddnsto[0].token") printf 'fixture-token\n' ;;
 *"get ddnsto.@ddnsto[0]") printf 'ddnsto\n' ;;
 *"get ddnsto.@ddnsto[1]") exit 1 ;;
 *' set '*|*' commit '*) exit 0 ;;
esac
exit 0
''')
            for app, managers, arches in [('ddnsto',('opkg','apk'),('x86_64','aarch64','armv7','mipsel')),('linkease',('opkg',),('x86_64','aarch64','armv7'))]:
                if os.environ.get('ZSETUP_TEST_APP') not in ('',None,app): continue
                remote='ddnsto' if app=='ddnsto' else 'LinkEase'
                for manager in managers:
                    ext='ipk' if manager=='opkg' else 'apk'
                    variants=('lite','standard') if app=='ddnsto' else ('',)
                    fixture_pins={}
                    for variant in variants:
                        pointer='openwrt/VERSION_LITE' if variant=='lite' else ('openwrt/VERSION' if app=='ddnsto' else 'Openwrt/VERSION')
                        version='4.2.8' if app=='ddnsto' else '4.2.3'
                        Handler.bodies[f'/binary/{remote}/{pointer}']=(version+'\n').encode()
                        folder=f'openwrt/{variant}{"-apk" if manager=="apk" else ""}/{version}' if app=='ddnsto' else 'Openwrt/4.2.3'
                        files={}
                        for arch in arches:
                            pa='arm' if arch=='armv7' else arch
                            names=[f'{app}_{pa}.{ext}',f'luci-app-{app}.{ext}',f'luci-i18n-{app}-zh-cn.{ext}']
                            if app=='linkease' and arch in ('x86_64','aarch64'): names += [f'linkmount_{arch}.ipk',f'ffmpeg-remux_{arch}.ipk']
                            for filename in names: files[filename]=f'fixture {filename}'.encode()
                        for filename,data in files.items():
                            relative = f'{folder}/{filename}'
                            if app == 'ddnsto' and filename.startswith('luci-'):
                                relative = f'openwrt/{filename}'
                            Handler.bodies[f'/binary/{remote}/{relative}']=data
                            if app == 'ddnsto': fixture_pins[relative]=hashlib.sha256(data).hexdigest()
                        Handler.bodies[f'/binary/{remote}/{folder}/SHA256SUMS']=''.join(f'{hashlib.sha256(data).hexdigest()}  {filename}\n' for filename,data in files.items()).encode()
                    script=ROOT/app/f'{app}-install.sh'
                    if app == 'ddnsto':
                        source=script.read_text()
                        pins=(ROOT/'ddnsto/product-pins.sh').read_text()
                        for relative,digest in fixture_pins.items():
                            match=re.search(re.escape(relative)+r"\) printf '%s\\n' ([0-9a-f]{64})",pins)
                            assert match,relative
                            assert match.group(1) in source,relative
                            source=source.replace(match.group(1),digest)
                        script=root/f'ddnsto-{manager}-install.sh'
                        script.write_text(source); script.chmod(0o755)
                    for arch in arches:
                        case=root/f'{app}-{manager}-{arch}'; case.mkdir()
                        prefix=case/'managed'; work=case/'下载 staging'; log=case/'actions'
                        package_state=case/'package-installed'
                        config_dir=case/'uci'; config_dir.mkdir()
                        env=os.environ | {'PATH':f'{fake}:/usr/bin:/bin','ZSETUP_BIN':'/tools/zsetup','ZSETUP_INSTALLER_MODE':'1',
                            'ZSETUP_OS':'openwrt','ZSETUP_PACKAGE_MANAGER':manager,'ZSETUP_ARCH':arch,
                            'ZSETUP_SOURCE_BASES':f'https://127.0.0.1:{server.server_port}/binary','ZSETUP_SOURCE_FALLBACK':'',
                            'ZSETUP_CA_FILE':str(root/'ca.crt'),'DDNSTO_SERVICE_PATH':str(fake/'service'),
                            'DDNSTO_OPENWRT_BIN_PATH':str(fake/'ddnsto'), 'DDNSTO_CONFIG_PATH':str(config_dir/'ddnsto'),
                            'DDNSTO_MEM_MB':'512','TEST_LOG':str(log),'TEST_PACKAGE_STATE':str(package_state)}
                        command=['sh',str(script),'--installer-prefix',str(prefix),'--installer-work-dir',str(work)]
                        if app == 'ddnsto': command += ['--action','install','--token','fixture-token']
                        good=subprocess.run(command,env=env,text=True,capture_output=True,timeout=30)
                        actions=log.read_text() if log.exists() else ''
                        assert good.returncode==0,(good,actions)
                        lines=log.read_text().splitlines()
                        mutations=[line for line in lines if ' install ' in line or ' add ' in line]
                        assert mutations and all(str(work) in line for line in mutations),lines
                        assert not list(work.iterdir()),list(work.iterdir())
                        assert any('cache' in line and 'tmp' in line for line in mutations),lines
                        assert not any('/tmp/' in line for line in lines),lines
                        if app == 'ddnsto':
                            package_state.unlink(missing_ok=True)
                            (config_dir/'ddnsto').unlink(missing_ok=True)
                        # Target lease is shared even when callers select different staging.
                        lock=prefix/'.package-lock'; lock.mkdir()
                        conflict=subprocess.run(['sh',str(script),'--installer-prefix',str(prefix),'--installer-work-dir',str(case/'other staging')],env=env,text=True,capture_output=True,timeout=30)
                        assert conflict.returncode==2,conflict
                        lock.rmdir()
                        marker=prefix/'.managed'; marker.chmod(0o666)
                        unsafe=subprocess.run(command,env=env,text=True,capture_output=True,timeout=30)
                        assert unsafe.returncode==12,unsafe
                        marker.chmod(0o644)
                        cache_counts=dict(Handler.counts)
                        # A PM transaction owns global app state even if its
                        # caller chooses an entirely different cache prefix.
                        global_lock=Path('/etc/zsetup/install-locks')/app
                        global_lock.mkdir(parents=True)
                        other=subprocess.run(['sh',str(script),'--installer-prefix',str(case/'other-prefix'),'--installer-work-dir',str(case/'other-work')],env=env,text=True,capture_output=True,timeout=30)
                        assert other.returncode==2,other
                        global_lock.rmdir()
                        failed=subprocess.run(command,env=env|{'PKG_FAIL':'23'},text=True,capture_output=True,timeout=30)
                        assert failed.returncode==23,failed
                        assert all(Handler.counts[k]==v for k,v in cache_counts.items() if not k.endswith(('SHA256SUMS','VERSION','VERSION_LITE'))),Handler.counts
                        assert not list(work.iterdir())
                        assert '23' in (prefix/'package-result').read_text()
                        assert not (prefix/'current').exists(), 'package error silently selected raw binaries'
                        # A complete digest failure must happen before any PM operation.
                        selected=f'openwrt/lite{"-apk" if manager=="apk" else ""}/4.2.8' if app=='ddnsto' else 'Openwrt/4.2.3'
                        sums=f'/binary/{remote}/{selected}/SHA256SUMS'
                        main=f'{app}_{"arm" if arch=="armv7" else arch}.{ext}'
                        artifact=f'/binary/{remote}/{selected}/{main}'
                        if app == 'ddnsto':
                            original=Handler.bodies[artifact]
                            Handler.bodies[artifact]=b'corrupt-'+original
                            for cached in prefix.rglob(main+'*'):
                                if cached.is_file(): cached.unlink()
                        else:
                            original=Handler.bodies[sums]
                            digest=hashlib.sha256(Handler.bodies[artifact]).hexdigest().encode()
                            Handler.bodies[sums]=original.replace(digest,b'0'*64)
                        before=[line for line in log.read_text().splitlines() if ' install ' in line or ' add ' in line]
                        corrupt=subprocess.run(command,env=env,text=True,capture_output=True,timeout=30)
                        after=[line for line in log.read_text().splitlines() if ' install ' in line or ' add ' in line]
                        assert corrupt.returncode==11 and after==before,corrupt
                        assert not list(work.iterdir())
                        if app == 'ddnsto': Handler.bodies[artifact]=original
                        else: Handler.bodies[sums]=original
                        if app=='ddnsto' and manager=='opkg' and arch=='x86_64':
                            config=case/'legacy-config'
                            config.write_text('global '+('x'*17000))
                            before=[line for line in log.read_text().splitlines() if ' install ' in line or ' add ' in line]
                            oversized=subprocess.run(command,env=env|{'DDNSTO_CONFIG_PATH':str(config)},text=True,capture_output=True,timeout=30)
                            after=[line for line in log.read_text().splitlines() if ' install ' in line or ' add ' in line]
                            assert oversized.returncode==2 and after==before,oversized
                            original='global legacy configuration\n'; config.write_text(original)
                            config_failure=subprocess.run(command,env=env|{'DDNSTO_CONFIG_PATH':str(config),'PKG_FAIL':'23'},text=True,capture_output=True,timeout=30)
                            assert config_failure.returncode==2 and config.read_text()==original,config_failure
                            ready=case/'query-ready'; child=case/'query-child'
                            proc=subprocess.Popen(command,env=env|{'BLOCK_QUERY':'1','QUERY_READY':str(ready),'QUERY_CHILD':str(child)},stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
                            deadline=time.monotonic()+10
                            while not ready.exists() and proc.poll() is None and time.monotonic()<deadline: time.sleep(.02)
                            assert ready.exists(),proc.communicate(timeout=2)
                            os.killpg(proc.pid,signal.SIGTERM); out,err=proc.communicate(timeout=10)
                            assert proc.returncode in (143,-signal.SIGTERM),(proc.returncode,err)
                            assert not Path('/proc',child.read_text().strip()).exists()
                            assert not list(work.iterdir()) and not (prefix/'.package-lock').exists()
                            for memory, selected in [('899','lite'),('900','standard'),('unknown','standard')]:
                                threshold=subprocess.run(command,env=env|{'DDNSTO_MEM_MB':memory},text=True,capture_output=True,timeout=30)
                                assert threshold.returncode==0 and f'Checking DDNSTO {selected} version' in threshold.stderr,threshold
                                package_state.unlink(missing_ok=True)
                                (config_dir/'ddnsto').unlink(missing_ok=True)
                            alias=case/'setup_ddnsto.sh'; alias.symlink_to(script)
                            compatibility=subprocess.run(['sh',str(alias),'fixture-token','--action','install'],env=env|{'ZSETUP_INSTALL_PREFIX':str(prefix),'ZSETUP_WORK_DIR':str(work)},text=True,capture_output=True,timeout=30)
                            assert compatibility.returncode==0,compatibility
                            for argument in ['--unknown','--force-version=bad','--token=']:
                                assert subprocess.run([*command,argument],env=env,capture_output=True,timeout=10).returncode==2
                if app=='linkease':
                    unsupported=subprocess.run(['sh',str(script)],env=env|{'ZSETUP_PACKAGE_MANAGER':'apk'},capture_output=True)
                    assert unsupported.returncode==2
            print('native packages: opkg/apk mappings, persistent PM cache/tmp/lists, bounded inputs, failure and cleanup passed')
        finally: server.shutdown(); server.server_close(); thread.join(timeout=2)


if __name__=='__main__':
    if sys.argv[1]=='--inside': inside()
    else: jail(Path(sys.argv[1]).resolve(), '/source/tests/package_storage_test.py')
