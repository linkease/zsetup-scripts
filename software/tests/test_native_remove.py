import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ENTRY = Path(__file__).resolve().parents[1] / 'task.sh'


class NativeRemoval(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.state = self.root / 'state'
        self.state.write_text('1.2.3')
        self.log = self.root / 'calls'
        cache = self.bin / 'apt-cache'
        cache.write_text('#!/bin/sh\nv=$(cat "$SIM_PM_STATE");if [ -z "$v" ];then v="(none)";fi;printf "Installed: %s\\nCandidate: 1.2.3\\n" "$v"\n')
        cache.chmod(0o755)
        manager = self.bin / 'apt-get'
        manager.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$SIM_PM_LOG"\nfor a in "$@";do if [ "$a" = remove ];then : > "$SIM_PM_STATE";exit 0;fi;done\nexit 7\n')
        manager.chmod(0o755)
        self.env = {**os.environ, 'PATH': str(self.bin) + os.pathsep + os.environ['PATH'],
                    'SIM_PM_STATE': str(self.state), 'SIM_PM_LOG': str(self.log),
                    'ZSETUP_TASK_TARGET_ID': 'native-remove'}
        self.req = {'software': 'sim-native-app', 'targetId': 'native-remove',
                    'method': 'native-package', 'intent': 'remove',
                    'storage': {'reserveBytes': 65536, 'paths': [
                        {'role': 'system-package', 'path': str(self.root), 'bytes': 65536}]}}

    def call(self, operation):
        file = self.root / 'request.json'
        file.write_text(json.dumps(self.req))
        result = subprocess.run(['bash', str(ENTRY), operation, str(file)],
                                env=self.env, text=True, capture_output=True)
        return result, json.loads(result.stdout)

    def test_native_remove_never_calls_install_or_purge(self):
        result, planned = self.call('plan')
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.req['plan'] = planned['details']
        result, body = self.call('remove')
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(body['reason'], 'removed')
        args = self.log.read_text().splitlines()
        self.assertIn('remove', args)
        self.assertNotIn('install', args)
        self.assertNotIn('purge', args)
        self.assertEqual(self.state.read_text(), '')

    def test_auto_remove_resolves_package_owner_instead_of_reusing_program(self):
        self.req.update(software='bash', method='auto')
        result, planned = self.call('plan')
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(planned['details']['method'], 'native-package')
        self.assertEqual(planned['details']['version'], '1.2.3')
        self.assertFalse(self.log.exists())

    def test_existing_program_is_not_a_removal_owner(self):
        self.req.update(software='bash', method='existing')
        result, body = self.call('plan')
        self.assertEqual(result.returncode, 21, result.stderr + result.stdout)
        self.assertEqual(body['reason'], 'program-removal-owner-required')
        self.assertFalse(self.log.exists())

    def test_explicit_already_absent_package_does_not_install_candidate(self):
        self.state.write_text('')
        result, planned = self.call('plan')
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.req['plan'] = planned['details']
        result, body = self.call('remove')
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(body['reason'], 'native-package-already-absent')
        self.assertFalse(self.log.exists())

    def test_install_reuses_registered_version_without_implicit_upgrade_or_write(self):
        cache=self.bin/'apt-cache'
        cache.write_text(cache.read_text().replace('Candidate: 1.2.3','Candidate: 9.0.0'))
        self.req['intent']='install'
        self.req.pop('storage')
        result,planned=self.call('plan')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(planned['details']['version'],'1.2.3')
        self.assertTrue(planned['details']['packageAlreadyInstalled'])
        self.assertIsNone(planned['details']['storagePlan'])
        self.req['plan']=planned['details']
        result,body=self.call('apply')
        self.assertEqual(result.returncode,20,result.stdout+result.stderr)
        self.assertEqual(body['reason'],'installed-functional-check-required')
        self.assertFalse(self.log.exists())
        self.assertEqual(self.state.read_text(),'1.2.3')

    def test_native_query_reports_package_registration_and_candidate(self):
        self.req['intent']='install'
        result,body=self.call('query')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertTrue(body['details']['installed'])
        self.assertEqual(body['details']['installedVersion'],'1.2.3')
        self.assertEqual(body['details']['candidateVersion'],'1.2.3')
        self.assertEqual(body['details']['functionalValidation'],'not-run')
        self.assertFalse(self.log.exists())


if __name__ == '__main__':
    unittest.main()
