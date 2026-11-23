"""Business inspection uses bounded facts; fixtures never install packages."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class InspectTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='inspect 中文 ')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / 'bin'; self.bin.mkdir()
        self.system = self.root / 'system'; (self.system / 'etc').mkdir(parents=True)
        (self.system / 'etc/openwrt_release').write_text("DISTRIB_ID='iStoreOS'\n")
        (self.system / 'etc/opkg.conf').write_text('lists_dir ext /var/opkg-lists\nsrc/gz fixture https://fixture.invalid/feed\n')
        self.feed=self.system/'var/opkg-lists/fixture';self.feed.parent.mkdir(parents=True)
        self.feed.write_text('Package: sample-agent\nVersion: 2.0.0-r1\nArchitecture: all\n\nPackage: luci-app-sample-agent\nVersion: 2.0.0-r1\nArchitecture: all\n')
        db=self.system / 'usr/lib/opkg'; db.mkdir(parents=True); (db/'status').write_text('')
        self.meta = self.system / 'tmp/run/istore-meta/meta'; self.meta.mkdir(parents=True)
        self.log = self.root / 'calls'
        self.catalog = self.root / 'catalog.json'
        self.catalog.write_text(json.dumps({'result': {'apps': [
            {'name': 'sample-agent', 'version': '2.0.0', 'release': 1,
             'depends': ['sample-agent', 'luci-app-sample-agent'], 'arch': ['all']} ]}}))
        self.env = {**os.environ, 'PATH': str(self.bin) + ':' + os.environ['PATH'],
            'ZSETUP_TASK_SYSTEM_ROOT': str(self.system), 'TEST_CATALOG': str(self.catalog),
            'TEST_LOG': str(self.log), 'TEST_INSTALLED': '2.0.0-r1', 'TEST_CANDIDATE': '2.0.0-r1'}
        self.script('uname', '#!/bin/sh\necho Linux\n')
        self.script('is-opkg', '#!/bin/sh\necho unexpected-store-mutation >> "$TEST_LOG"\nexit 37\n')
        self.script('zsetup', '''#!/bin/sh
if [ "$1" = --version ]; then echo 'zsetup 0.5.1'; exit; fi
[ "$1" = download ] || exit 37
shift
while [ "$#" -gt 0 ]; do
 if [ "$1" = -o ]; then cp "$TEST_CATALOG" "$2"; exit; fi
 shift
done
exit 37
''')
        self.env['KAI_ZSETUP_BIN'] = str(self.bin / 'zsetup')
        self.script('opkg', '''#!/usr/bin/env python3
import os,sys,subprocess
a=sys.argv[1:]
with open(os.environ['TEST_LOG'],'a') as log: log.write(' '.join(a)+'\\n')
if a[0]=='status':
 print('Package: '+a[1]+'\\nVersion: '+os.environ['TEST_INSTALLED']+'\\nStatus: install ok installed');sys.exit(0)
if a[0]=='print-architecture': print('arch all 1\\narch aarch64 10');sys.exit(0)
if a[0]=='list':
 v=os.environ.get('TEST_CANDIDATE','')
 if v: print(a[1]+' - '+v+' - sample')
 sys.exit(0)
if a[0]=='compare-versions':
 sys.exit(subprocess.run(['dpkg','--compare-versions',a[1],{'<':'lt','>':'gt','=':'eq'}[a[2]],a[3]]).returncode)
sys.exit(37)
''')

    def script(self, name, body):
        p = self.bin / name; p.write_text(body); p.chmod(0o755)

    def call(self, operation='inspect', **env):
        if 'TEST_CANDIDATE' in env and not env['TEST_CANDIDATE']:self.feed.write_text('')
        request = self.root / 'request.json'
        request.write_text('{"software":"sample-agent","targetId":"local","method":"native-package"}')
        r = subprocess.run(['bash', str(ROOT / 'software/task.sh'), operation, str(request)],
            env={**self.env, **env}, capture_output=True, text=True, timeout=15)
        self.assertTrue(r.stdout, r.stderr)
        return r, json.loads(r.stdout)

    def installed_meta(self, version='2.0.0', release=1):
        (self.meta / 'sample-agent.json').write_text(json.dumps({
            'name': 'sample-agent', 'version': version, 'release': release,
            'depends': ['sample-agent', 'luci-app-sample-agent']}))

    def test_store_same_version_is_no_update_with_live_source(self):
        self.installed_meta()
        r, body = self.call()
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertEqual(body['details']['decision'], 'no-update')
        self.assertEqual(body['details']['source']['id'], 'istore-store-api')
        self.assertEqual(body['details']['source']['freshness'], 'live')
        self.assertNotIn('update', self.log.read_text())

    def test_store_newer_version_is_update_available(self):
        self.installed_meta('1.9.0')
        r, body = self.call()
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertEqual(body['details']['decision'], 'update-available')
        self.assertEqual(body['details']['installedVersion'], '1.9.0')

    def test_missing_store_ownership_is_not_implicitly_adopted(self):
        r, body = self.call()
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertEqual(body['status'], 'success')
        self.assertEqual(body['details']['decision'], 'unconfirmed')
        self.assertEqual(body['details']['missingEvidence'], ['store-ownership'])
        self.assertEqual(body['reason'], 'inspected')
        self.assertEqual(body['details']['packages'][0]['installedVersion'], '2.0.0-r1')
        self.assertNotIn('unexpected-store-mutation', self.log.read_text())

    def test_read_query_resolves_unique_business_name_case_and_keeps_ownership_unknown(self):
        request = self.root / 'case-query.json'
        request.write_text(json.dumps({'software': 'SAMPLE-AGENT', 'targetId': 'local'}))
        result = subprocess.run(['bash', str(ROOT / 'software/task.sh'), 'inspect', str(request)], env=self.env, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        body = json.loads(result.stdout)
        self.assertEqual(body['details']['canonicalSoftwareId'], 'sample-agent')
        self.assertEqual(body['details']['packages'][0]['installedVersion'], '2.0.0-r1')
        self.assertEqual(body['details']['decision'], 'unconfirmed')
        self.assertNotIn('unexpected-store-mutation', self.log.read_text())
        self.installed_meta()
        result = subprocess.run(['bash', str(ROOT / 'software/task.sh'), 'inspect', str(request)], env=self.env, capture_output=True, text=True, timeout=15)
        self.assertEqual(json.loads(result.stdout)['details']['decision'], 'no-update')

    def test_case_ambiguous_catalog_is_not_selected_arbitrarily(self):
        data = json.loads(self.catalog.read_text())
        data['result']['apps'].append({**data['result']['apps'][0], 'name': 'SAMPLE-AGENT'})
        self.catalog.write_text(json.dumps(data))
        result, body = self.call()
        self.assertEqual(result.returncode, 20, result.stderr + result.stdout)
        self.assertEqual(body['reason'], 'ambiguous-software-identity')
        self.assertEqual(body['effects'], [])

    def test_catalog_failure_is_not_no_update(self):
        self.script('zsetup', '#!/bin/sh\nif [ "$1" = --version ]; then echo "zsetup 0.5.1"; exit; fi\nexit 7\n')
        r, body = self.call()
        self.assertEqual(r.returncode, 22, r.stderr + r.stdout)
        self.assertEqual(body['reason'], 'store-catalog-unavailable')
        self.assertEqual(body['nativeExitCode'], 7)

    def test_native_network_categories_are_bounded_and_do_not_expose_download_details(self):
        for code, category in [(13, 'dns'), (14, 'tls'), (15, 'timeout')]:
            with self.subTest(code=code):
                self.script('zsetup', '#!/bin/sh\nif [ "$1" = --version ]; then echo "zsetup 0.5.1"; exit; fi\necho "private-device-and-url-sentinel" >&2\nexit '+str(code)+'\n')
                r, body = self.call()
                self.assertEqual(r.returncode, 22, r.stderr+r.stdout)
                self.assertEqual(body['nativeExitCode'], code)
                self.assertEqual(body['details']['failureCategory'], category)
                self.assertNotIn('private-device-and-url-sentinel', r.stdout+r.stderr)
                self.assertNotIn('decision', body['details'])

    def test_native_query_never_uses_installed_info_as_candidate(self):
        r, body = self.call('query', TEST_CANDIDATE='')
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertEqual(body['details']['candidateVersion'], '')
        self.assertEqual(body['details']['installedVersion'], '2.0.0-r1')
        self.assertNotIn('info ', self.log.read_text())

    def test_installed_only_list_row_is_not_an_available_feed_candidate(self):
        self.feed.write_text('')
        r,body=self.call('query')
        self.assertEqual(r.returncode,0,r.stderr+r.stdout)
        self.assertEqual(body['details']['candidateVersion'],'')
        self.assertEqual(body['details']['installedVersion'],'2.0.0-r1')

    def test_same_version_different_source_bytes_require_a_decision(self):
        self.installed_meta()
        self.feed.write_text('Package: sample-agent\nVersion: 2.0.0-r1\nArchitecture: all\nSHA256sum: '+'a'*64+'\n')
        (self.system/'etc/opkg.conf').write_text((self.system/'etc/opkg.conf').read_text()+'src/gz other https://other.invalid/feed\n')
        (self.feed.parent/'other').write_text('Package: sample-agent\nVersion: 2.0.0-r1\nArchitecture: all\nSHA256sum: '+'b'*64+'\n')
        r,body=self.call()
        self.assertEqual(r.returncode,20,r.stderr+r.stdout)
        self.assertEqual(body['reason'],'native-source-conflict')
        self.assertNotIn('unexpected-store-mutation',self.log.read_text())


if __name__ == '__main__':
    unittest.main()
