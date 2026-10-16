#!/usr/bin/env python3
"""Actual systemd manager in a disposable lab container; products are stubs."""
import hashlib
import http.server
import io
import os
from pathlib import Path
import ssl
import subprocess
import sys
import tarfile
import tempfile
import threading
import zipfile
sys.path.insert(0,str(Path(__file__).resolve().parent))
from service_storage_test import Handler
from tls_fixture import generate_certificate
ROOT=Path(__file__).resolve().parents[1]
native=sys.argv[1]
assert os.geteuid()==0 and Path('/run/systemd/system').is_dir()
assert subprocess.check_output(['systemctl','is-system-running'],text=True).strip()=='running'
with tempfile.TemporaryDirectory(prefix='systemd-native-',dir='/lab') as name:
 root=Path(name); generate_certificate(root)
 server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
 tls=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); tls.load_cert_chain(root/'server.crt',root/'server.key')
 server.socket=tls.wrap_socket(server.socket,server_side=True); thread=threading.Thread(target=server.serve_forever,daemon=True); thread.start()
 try:
  for app in ('ddnsto','linkease'):
   unit=f'com.linkease.{"ddnstoshell" if app=="ddnsto" else "linkeasedaemon"}.service'
   prefix=root/'protected 中文 space'/app
   body=f"""#!/bin/sh
set -eu
case "$1" in
 -v|showVersion) echo '{app} fixture 1.0.0' ;;
 -u|--serviceControl)
  mkdir -p /etc/ddnsto
  [ '{app}' != ddnsto ] || printf '%s\\n' "$2" > /etc/ddnsto/ddnsto-config.json
  printf '[Unit]\\nDescription=zsetup isolated acceptance\\n[Service]\\nExecStart=%s "run"\\n[Install]\\nWantedBy=multi-user.target\\n' "$0" > /etc/systemd/system/{unit}
  ;;
 run)
  trap 'exit 0' TERM INT
  while :; do sleep 1; done ;;
esac
""".encode()
   stream=io.BytesIO()
   with tarfile.open(fileobj=stream,mode='w:gz') as tar:
    for name in ([app] if app=='ddnsto' else [app,'heif-converter','linkease-media']):
     data=body if name==app else b'#!/bin/sh\nexit 0\n'
     member=f'ddnsto-standard-1.0.0/{name}.x86_64' if app=='ddnsto' else f'linkease-binary-1.0.0/{name}.x86_64'
     info=tarfile.TarInfo(member); info.size=len(data); tar.addfile(info,io.BytesIO(data))
   archive=f'ddnsto-standard-1.0.0.tar.gz' if app=='ddnsto' else 'linkease-binary-1.0.0.tar.gz'
   files={archive:stream.getvalue()}
   if app=='linkease':
    stream=io.BytesIO()
    with zipfile.ZipFile(stream,'w') as zip: zip.writestr('amd64/bin/linkmount_bin',b'fixture'); zip.writestr('amd64/bin/lib/libfixture.so',b'fixture')
    files['amd64.zip']=stream.getvalue()
   folder='/ddnsto/linux-binary' if app=='ddnsto' else '/LinkEase/LinuxStorage/1.0.0'
   for filename,data in files.items(): Handler.bodies[folder+'/'+filename]=data
   Handler.bodies[folder+'/SHA256SUMS']=''.join(hashlib.sha256(v).hexdigest()+'  '+k+'\n' for k,v in files.items()).encode()
   env=os.environ|{'ZSETUP_INSTALLER_MODE':'1','ZSETUP_BIN':native,'ZSETUP_OS':'ubuntu','ZSETUP_PACKAGE_MANAGER':'apt','ZSETUP_ARCH':'x86_64','ZSETUP_SOURCE_BASES':f'https://127.0.0.1:{server.server_port}','ZSETUP_SOURCE_FALLBACK':'','ZSETUP_CA_FILE':str(root/'ca.crt'),'DDNSTO_VERSION':'1.0.0','HOME':'/root'}
   args=['--token','isolated test'] if app=='ddnsto' else ['--version','1.0.0']
   command=['sh',str(ROOT/app/f'{app}-install.sh'),'--installer-prefix',str(prefix),'--',*args]
   result=subprocess.run(command,env=env,text=True,capture_output=True,timeout=30)
   assert result.returncode==0,result
   assert subprocess.check_output(['systemctl','is-active',unit],text=True).strip()=='active'
   pid=int(subprocess.check_output(['systemctl','show','-p','MainPID','--value',unit],text=True))
   assert pid>1 and Path('/proc',str(pid)).exists()
   assert (prefix/'current/bin'/app).is_file()
   before=dict(Handler.counts)
   repeated=subprocess.run(command,env=env,text=True,capture_output=True,timeout=30)
   assert repeated.returncode==0,repeated
   assert all(Handler.counts[k]==v for k,v in before.items() if not k.endswith('SHA256SUMS'))
   subprocess.run(['systemctl','disable','--now',unit],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
   assert not Path('/proc',str(pid)).exists()
   Path('/etc/systemd/system',unit).unlink(); subprocess.run(['systemctl','daemon-reload'],check=True)
   Path('/root/.local/bin',app).unlink()
  print('real systemd 255: two app registrations, protected Chinese paths, native extraction, live MainPID/health, cache restart and manager stop/reap passed; fixture business payloads only')
 finally: server.shutdown(); server.server_close(); thread.join()
