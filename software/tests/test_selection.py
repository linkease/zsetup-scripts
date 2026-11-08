import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ENTRY = Path(__file__).resolve().parents[1] / 'task.sh'


class Selection(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.request = {'software': 'bash', 'targetId': 'selection-test'}

    def call(self, op, extra=None):
        p = self.root / 'request.json'
        p.write_text(json.dumps(self.request))
        r = subprocess.run(['bash', str(ENTRY), op, str(p)], text=True, capture_output=True,
                           env={**os.environ, 'ZSETUP_TASK_TARGET_ID': 'selection-test', **(extra or {})})
        return r, json.loads(r.stdout)

    def test_version_requirement_is_not_ignored(self):
        self.request['version'] = '99999.0.0'
        r, body = self.call('plan')
        self.assertEqual(r.returncode, 20)
        self.assertEqual(body['status'], 'needs-ai')
        self.assertNotEqual(body['reason'], 'reusable')

    def test_existing_program_plan_is_bound_and_repeatable(self):
        r, body = self.call('plan')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(body['details']['method'], 'existing')
        self.request['plan'] = body['details']
        r, body = self.call('apply')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(body['reason'], 'reused')
        self.assertEqual(body['details']['functionalValidation'], 'passed')
        r, body = self.call('apply')
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_apply_requires_reviewed_plan(self):
        r, body = self.call('apply')
        self.assertEqual(r.returncode, 21)
        self.assertEqual(body['reason'], 'missing-plan')

    def test_changed_request_cannot_apply_previous_plan(self):
        r, body = self.call('plan')
        self.request['plan'] = body['details']
        self.request['version'] = '99999.0.0'
        r, body = self.call('apply')
        self.assertEqual(r.returncode, 21)
        self.assertEqual(body['reason'], 'plan-changed')

    def test_owner_recipe_offers_exact_artifact_without_writing(self):
        self.request.update({'software': 'jq', 'method': 'owner', 'version': '1.8.2', 'prefixBase': str(self.root)})
        r, body = self.call('plan')
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertEqual(body['details']['method'], 'owner')
        self.assertEqual(body['details']['version'], '1.8.2')
        self.assertRegex(body['details']['artifact']['sha256'], '^[a-f0-9]{64}$')
        self.assertFalse((self.root / 'jq').exists())

    def test_provider_error_is_not_no_candidate(self):
        fake = self.root / 'bin'
        fake.mkdir()
        executable = fake / 'apt-cache'
        executable.write_text('#!/bin/sh\nprintf "index inaccessible\\n" >&2\nexit 7\n')
        executable.chmod(0o755)
        self.request.update({'software': 'jq', 'version': '1.8.2', 'method': 'native-package'})
        r, body = self.call('plan', {'PATH': str(fake)+os.pathsep+os.environ['PATH']})
        self.assertEqual(r.returncode, 22)
        self.assertEqual(body['reason'], 'provider-query-failed')
        self.assertEqual(body['nativeExitCode'], 7)

    def test_features_are_checked_for_the_selected_software(self):
        self.request['features'] = ['jq-regex']
        r, body = self.call('plan')
        self.assertEqual(r.returncode, 20)
        self.assertEqual(body['reason'], 'unknown-functional-requirement')

    def test_native_search_returns_bounded_source_qualified_candidates(self):
        fake = self.root / 'bin'
        fake.mkdir()
        executable = fake / 'apt-cache'
        executable.write_text('#!/bin/sh\nprintf "bash - GNU shell\\nbash-doc - shell documentation\\n"\n')
        executable.chmod(0o755)
        r, body = self.call('search', {'PATH': str(fake)+os.pathsep+os.environ['PATH']})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(body['details']['candidates'][0]['id'], 'apt:bash')
        self.assertLessEqual(len(body['details']['candidates']), 20)

    def test_owner_failure_retains_native_code_without_source_fallback(self):
        self.request.update({'software': 'jq', 'method': 'owner', 'version': '1.8.2', 'prefixBase': str(self.root)})
        r, body = self.call('plan')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.request['plan'] = body['details']
        core = self.root / 'zsetup'
        core.write_text('#!/bin/sh\nprintf "integrity failure\\n" >&2\nexit 11\n')
        core.chmod(0o755)
        r, body = self.call('apply', {'ZSETUP_BIN': str(core)})
        self.assertEqual(r.returncode, 22)
        self.assertEqual(body['nativeExitCode'], 11)
        self.assertEqual(body['reason'], 'owner-install-failed')


if __name__ == '__main__':
    unittest.main()
