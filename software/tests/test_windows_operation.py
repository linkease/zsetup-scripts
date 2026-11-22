"""Exercise the same machine contract with an isolated native-provider fixture."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]


class WindowsOperation(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='windows provider 中文 ');self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name);self.bin=self.root/'bin';self.bin.mkdir()
        self.state=self.root/'state';self.state.write_text('1.0.0');self.log=self.root/'writes'
        self.adapters=self.root/'scripts';self.adapters.mkdir();(self.adapters/'scoop.ps1').write_text('# pinned fixture provider\n')
        (self.root/'resources').mkdir();(self.root/'resources/scoop.lock.json').write_text('{}')
        self.script('uname','#!/bin/sh\necho MINGW64_NT\n')
        self.script('client','#!/bin/sh\necho 0.9.1\n')
        self.script('cygpath','''#!/usr/bin/env python3
import sys
p=sys.argv[2]
if sys.argv[1]=='-w': print(p if len(p)>1 and p[1]==':' else 'C:'+p)
else: print(p[2:] if len(p)>1 and p[1]==':' else p)
''')
        self.script('native-jq',f'''#!/usr/bin/env python3
import subprocess,sys
p=subprocess.run([{shutil.which('jq')!r}]+[a for a in sys.argv[1:] if a!='--binary'],input=sys.stdin.buffer.read(),capture_output=True)
sys.stdout.buffer.write(p.stdout);sys.stderr.buffer.write(p.stderr);sys.exit(p.returncode)
''')
        self.script('powershell.exe','''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
a=sys.argv[1:]
if '-Command' in a:print('ntfs');sys.exit(0)
r=json.load(sys.stdin)
if any(x.endswith('native-windows.ps1') for x in a):
 print(json.dumps({'manager':'scoop','candidateVersion':'2.0.0','installedVersion':Path(os.environ['SIM_STATE']).read_text(),'comparison':'candidate-newer','providerRoot':os.environ['SIM_ROOT'],'nativeId':'main/sample-tool','source':{'id':'scoop:main','freshness':'cache-unverified','fetchedAt':None}}));sys.exit(0)
with open(os.environ['SIM_LOG'],'a') as log:log.write(json.dumps(r)+'\\n')
if os.environ.get('SIM_FAIL'):print('private-output-sentinel');sys.exit(7)
Path(os.environ['SIM_STATE']).write_text('' if r['action']=='remove' else '2.0.0')
print(json.dumps({'schemaVersion':1,'id':'scoop:main/sample-tool','installedVersion':'2.0.0','installed':True,'nativeReceipt':{'private':'private-output-sentinel'}}))
''')
        self.env={**os.environ,'PATH':str(self.bin)+os.pathsep+os.environ['PATH'],
            'ZSETUP_TASK_WINDOWS_ADAPTER_DIR':str(self.adapters),'KAI_KSCLI_BIN':str(self.bin/'client'),'KAI_ZSETUP_BIN':str(self.bin/'client'),
            'ZSETUP_TASK_JQ':str(self.bin/'native-jq'),
            'SIM_ROOT':str(self.root),'SIM_STATE':str(self.state),'SIM_LOG':str(self.log)}
        self.request={'software':'sample-tool','targetId':'local','method':'native-package','provider':'scoop','intent':'update',
            'storage':{'reserveBytes':65536,'paths':[{'role':'system-package','path':str(self.root),'bytes':65536}]}}

    def script(self,name,body):
        p=self.bin/name;p.write_text(body);p.chmod(0o755)

    def call(self,operation):
        p=self.root/'request.json';p.write_text(json.dumps(self.request))
        r=subprocess.run(['bash',str(ROOT/'software/task.sh'),operation,str(p)],env=self.env,capture_output=True,text=True,timeout=15)
        self.assertTrue(r.stdout,r.stderr)
        return r,json.loads(r.stdout)

    def plan(self):
        r,b=self.call('plan');self.assertEqual(r.returncode,0,r.stdout+r.stderr);self.request['plan']=b['details'];return b['details']

    def test_windows_update_uses_the_bound_existing_provider(self):
        self.plan();r,b=self.call('apply')
        self.assertNotIn('private-output-sentinel',r.stdout+r.stderr)
        self.assertEqual(self.state.read_text(),'2.0.0')
        self.assertEqual(json.loads(self.log.read_text().splitlines()[0])['subject'],'main/sample-tool')
        self.assertEqual(b['details']['installedVersion'],'2.0.0')

    def test_changed_provider_code_is_rejected_before_execution(self):
        self.plan();(self.adapters/'scoop.ps1').write_text('# changed provider\n');r,b=self.call('apply')
        self.assertEqual(r.returncode,21,r.stdout+r.stderr)
        self.assertFalse(self.log.exists())

    def test_changed_registered_version_invalidates_reviewed_plan(self):
        self.plan();self.state.write_text('1.1.0');r,b=self.call('apply')
        self.assertEqual(r.returncode,21,r.stdout+r.stderr)
        self.assertFalse(self.log.exists())

    def test_native_failure_preserves_code_without_returning_raw_diagnostics(self):
        self.plan();self.env['SIM_FAIL']='1';r,b=self.call('apply')
        self.assertEqual(r.returncode,22,r.stdout+r.stderr)
        self.assertEqual(b['nativeExitCode'],7)
        self.assertNotIn('private-output-sentinel',r.stdout+r.stderr)


if __name__=='__main__':unittest.main()
