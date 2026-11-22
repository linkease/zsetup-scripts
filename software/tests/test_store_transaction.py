import json
from pathlib import Path
import subprocess
import unittest

import test_inspect as inspect_fixture

ROOT = inspect_fixture.ROOT


class StoreTransaction(unittest.TestCase):
    script = inspect_fixture.InspectTests.script
    installed_meta = inspect_fixture.InspectTests.installed_meta

    def setUp(self):
        inspect_fixture.InspectTests.setUp(self)
        self.installed_meta('1.0.0')
        self.state=self.root/'registered-version';self.state.write_text('1.0.0-r1')
        self.env.update(TEST_STATE=str(self.state),TEST_META=str(self.meta/'sample-agent.json'))
        opkg=self.bin/'opkg'
        opkg.write_text(opkg.read_text().replace("os.environ['TEST_INSTALLED']", "open(os.environ['TEST_STATE']).read()"))
        self.script('is-opkg', '''#!/usr/bin/env python3
import os,json,sys
with open(os.environ['TEST_LOG'],'a') as f: f.write('store-write '+' '.join(sys.argv[1:])+'\\n')
if os.environ.get('TEST_STORE_FAIL'): sys.exit(7)
meta={'name':'sample-agent','version':'2.0.0','release':1,'depends':['sample-agent','luci-app-sample-agent']}
with open(os.environ['TEST_META'],'w') as f:json.dump(meta,f)
with open(os.environ['TEST_STATE'],'w') as f:f.write('2.0.0-r1')
''')
        self.request={'software':'sample-agent','targetId':'local','method':'istore','intent':'update',
            'storage':{'reserveBytes':65536,'paths':[{'role':'system-package','path':str(self.root),'bytes':65536}]}}

    def call(self, operation):
        path=self.root/'request.json';path.write_text(json.dumps(self.request))
        r=subprocess.run(['bash',str(ROOT/'software/task.sh'),operation,str(path)],env=self.env,capture_output=True,text=True,timeout=15)
        return r,json.loads(r.stdout)

    def plan(self):
        r,b=self.call('plan');self.assertEqual(r.returncode,0,r.stderr+r.stdout)
        self.request['plan']=b['details'];return b['details']

    def test_plan_declares_native_hooks_without_installing(self):
        planned=self.plan()
        self.assertEqual(planned['method'],'istore')
        self.assertIn('native-package-hooks',planned['effects'])
        self.assertNotIn('store-write',self.log.read_text())
        self.assertEqual(self.state.read_text(),'1.0.0-r1')

    def test_changed_catalog_is_blocked_before_native_update(self):
        self.plan();data=json.loads(self.catalog.read_text());data['result']['apps'][0]['version']='3.0.0';self.catalog.write_text(json.dumps(data))
        r,b=self.call('apply')
        self.assertEqual(r.returncode,21,r.stderr+r.stdout)
        self.assertNotIn('store-write',self.log.read_text())
        self.assertEqual(self.state.read_text(),'1.0.0-r1')

    def test_apply_verifies_store_record_and_package_registration(self):
        self.plan();r,b=self.call('apply')
        self.assertEqual(r.returncode,0,r.stderr+r.stdout)
        self.assertEqual(b['reason'],'updated')
        self.assertEqual(b['details']['installedVersion'],'2.0.0')
        self.assertEqual(b['details']['functionalValidation'],'not-run')
        self.assertEqual(self.state.read_text(),'2.0.0-r1')

    def test_provider_failure_keeps_original_code_and_reports_attempt(self):
        self.plan();self.env['TEST_STORE_FAIL']='1';r,b=self.call('apply')
        self.assertEqual(r.returncode,22,r.stderr+r.stdout)
        self.assertEqual(b['nativeExitCode'],7)
        self.assertIn('native-package-operation-attempt',b['effects'])


if __name__=='__main__':unittest.main()
