#!/usr/bin/env python3
"""Real two-UID sudo gate; run only in the privileged disposable lab container."""
import hashlib
import http.server
import io
import os
from pathlib import Path
import signal
import ssl
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
sys.path.insert(0,str(Path(__file__).resolve().parent))
from service_storage_test import jail, Handler, executable
ROOT=Path(__file__).resolve().parents[1]


def inside():
    assert os.geteuid()==0
    from tls_fixture import generate_certificate
    home=Path('/home/tester'); home.mkdir(parents=True); os.chown(home,1000,1000); home.chmod(0o700)
    fixture=Path('/fixtures/sudo'); fixture.mkdir(); fixture.chmod(0o755)
    generate_certificate(fixture); (fixture/'ca.crt').chmod(0o644)
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
    tls=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); tls.load_cert_chain(fixture/'server.crt',fixture/'server.key')
    server.socket=tls.wrap_socket(server.socket,server_side=True)
    thread=threading.Thread(target=server.serve_forever,daemon=True); thread.start()
    executable(fixture/'systemctl', """#!/bin/sh
set -eu
state=/fixtures/sudo/active
case "$1" in
 show) [ ! -f /etc/systemd/system/com.linkease.ddnstoshell.service ] || echo /etc/systemd/system/com.linkease.ddnstoshell.service ;;
 is-active|is-enabled) [ -f "$state" ] ;;
 start|enable) : > "$state" ;;
 stop|disable) rm -f "$state" ;;
 daemon-reload) : ;;
 *) exit 2 ;;
esac
""")
    subprocess.run(['mount','--bind',str(fixture/'systemctl'),'/usr/bin/systemctl'],check=True)
    prefix='/opt/sudo-ddnsto'
    def artifact(version, block=False):
        body=f"""#!/bin/sh
set -eu
case "$1" in
 -v) echo 'ddnsto {version}'; exit 0 ;;
 -u)
  id -u > /fixtures/sudo/business-uid
  mkdir -p /etc/ddnsto
  printf '%s\\n' "$2" > /etc/ddnsto/ddnsto-config.json
  printf '[Service]\\nExecStart=%s "run"\\n' "$0" > /etc/systemd/system/com.linkease.ddnstoshell.service
"""
        if block:
            body+="""  sleep 60 & child=$!
  echo "$child" > /fixtures/sudo/child
  : > /fixtures/sudo/ready
  wait "$child"
"""
        body+='  ;;\nesac\n'
        stream=io.BytesIO()
        with tarfile.open(fileobj=stream,mode='w:gz') as archive:
            info=tarfile.TarInfo(f'ddnsto-standard-{version}/ddnsto.x86_64'); data=body.encode(); info.size=len(data); info.mode=0o755; archive.addfile(info,io.BytesIO(data))
        name=f'ddnsto-standard-{version}.tar.gz'; payload=stream.getvalue()
        Handler.bodies['/ddnsto/linux-binary/'+name]=payload
        Handler.bodies['/ddnsto/linux-binary/SHA256SUMS']=(hashlib.sha256(payload).hexdigest()+'  '+name+'\n').encode()
        return '/ddnsto/linux-binary/'+name
    base=f'https://127.0.0.1:{server.server_port}'
    env=['PATH=/usr/bin:/bin','HOME=/home/tester','ZSETUP_INSTALLER_MODE=1','ZSETUP_BIN=/tools/zsetup',
         'ZSETUP_OS=ubuntu','ZSETUP_PACKAGE_MANAGER=apt','ZSETUP_ARCH=x86_64',
         'ZSETUP_SOURCE_BASES='+base,'ZSETUP_SOURCE_FALLBACK=','ZSETUP_CA_FILE='+str(fixture/'ca.crt')]
    def command(version):
        # sh -c models the supported curl-substitution entry, without a readable $0.
        return ['/usr/sbin/runuser','-u','tester','--','/usr/bin/env','-i',*env,'DDNSTO_VERSION='+version,
                '/bin/sh','-c','printf \'%s\\n\' \"$$\" > \"$HOME/coordinator-pid\";\n'+(ROOT/'ddnsto/ddnsto-install.sh').read_text(),'one-key',
                '--installer-prefix',prefix,'--installer-work-dir','/home/tester/中文 staging','--','--token','中文 $() token']
    def run(version):
        result=subprocess.run(command(version),stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=60)
        assert result.returncode==0,result.stderr.decode(); return result
    try:
        url=artifact('1.0.0')
        denied=subprocess.run(command('1.0.0'),stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=15)
        assert denied.returncode==2,denied.stderr
        assert Handler.counts.get(url,0)==0
        sudoers=Path('/etc/sudoers'); sudoers.write_text('Defaults !use_pty\ntester ALL=(root) NOPASSWD: ALL\n'); sudoers.chmod(0o440)
        run('1.0.0')
        assert (fixture/'business-uid').read_text().strip()=='0'
        alias=home/'.local/bin/ddnsto'
        assert alias.is_symlink() and alias.lstat().st_uid==1000
        assert os.readlink(prefix+'/current')=='versions/1.0.0'
        assert Handler.counts.get(url)==1,Handler.counts
        assert not list(home.rglob('.transaction.*'))
        assert not list(Path('/tmp').glob('zsetup-privileged.*'))
        run('1.0.0'); assert Handler.counts.get(url)==1,Handler.counts
        # TERM of the unprivileged coordinator closes control, joins root
        # rollback, then removes user staging. No unprivileged root kill.
        artifact('2.0.0',True)
        proc=subprocess.Popen(command('2.0.0'),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        deadline=time.monotonic()+20
        while not (fixture/'ready').exists() and time.monotonic()<deadline: time.sleep(.05)
        if not (fixture/'ready').exists():
            proc.terminate(); out,err=proc.communicate(timeout=15); raise AssertionError(err.decode())
        assert proc.poll() is None, proc.communicate(timeout=10)
        os.kill(int((home/'coordinator-pid').read_text()),signal.SIGTERM)
        out,err=proc.communicate(timeout=30)
        assert proc.returncode==143,(proc.returncode,err.decode())
        assert os.readlink(prefix+'/current')=='versions/1.0.0'
        assert not Path('/proc', (fixture/'child').read_text().strip()).exists()
        assert not list(home.rglob('.transaction.*'))
        assert not list(Path('/tmp').glob('zsetup-privileged.*'))
        assert not Path(prefix+'/.service-lock').exists()
        print('native sudo: denied credentials, actual UID 1000→0, root verification, one-key entry, alias ownership, cache, TERM rollback and complete cleanup passed')
    finally:
        server.shutdown(); server.server_close(); thread.join()

if __name__=='__main__':
    if sys.argv[1]=='--inside': inside()
    else:
        assert os.geteuid()==0, 'use isolated root lab container, never host services'
        jail(Path(sys.argv[1]).resolve(),'/source/tests/sudo_privilege_test.py')
