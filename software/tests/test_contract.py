import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
ENTRY = ROOT / 'software/task.sh'


class SoftwareContract(unittest.TestCase):
    def call(self, operation, request, target='test-target'):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            request_path = root / 'request.json'
            request_path.write_text(json.dumps(request))
            before = sorted(p.name for p in root.iterdir())
            result = subprocess.run(['bash', str(ENTRY), operation, str(request_path)],
                                    env={**os.environ, 'ZSETUP_TASK_TARGET_ID': target},
                                    text=True, capture_output=True)
            self.assertEqual(before, sorted(p.name for p in root.iterdir()))
            return result, json.loads(result.stdout)

    def test_existing_bash_is_observed_not_installed(self):
        result, body = self.call('query', {'software': 'bash', 'targetId': 'test-target'})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(body['protocol'], 'software-task/v1')
        self.assertEqual(body['status'], 'success')
        self.assertEqual(body['targetId'], 'test-target')
        self.assertTrue(body['details']['installed'])
        self.assertEqual(body['effects'], [])

    def test_unknown_software_hands_off_without_guessing(self):
        result, body = self.call('plan', {'software': 'unknown-software-sim', 'targetId': 'test-target'})
        self.assertEqual(result.returncode, 20)
        self.assertEqual(body['status'], 'needs-ai')
        self.assertEqual(body['reason'], 'no-installation-rule')
        self.assertEqual(body['nativeExitCode'], 0)
        self.assertEqual(body['effects'], [])

    def test_malformed_request_is_not_an_installation_failure(self):
        result, body = self.call('plan', {'software': 'bash; touch unwanted', 'targetId': 'test-target'})
        self.assertEqual(result.returncode, 2)
        self.assertEqual(body['reason'], 'invalid-request')

    def test_target_context_mismatch_is_blocked(self):
        result, body = self.call('query', {'software': 'bash', 'targetId': 'another-target'})
        self.assertEqual(result.returncode, 21)
        self.assertEqual(body['reason'], 'target-mismatch')

    def test_unknown_action_never_reaches_program(self):
        result, body = self.call('start-service', {'software': 'bash', 'targetId': 'test-target'})
        self.assertEqual(result.returncode, 2)
        self.assertEqual(body['reason'], 'unknown-operation')

    def test_symlink_request_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            original = Path(temporary) / 'original'
            original.write_text('{"software":"bash","targetId":"local"}')
            alias = Path(temporary) / 'alias'
            alias.symlink_to(original)
            result = subprocess.run(['bash', str(ENTRY), 'query', str(alias)], text=True, capture_output=True)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(json.loads(result.stdout)['reason'], 'invalid-request-file')


if __name__ == '__main__':
    unittest.main()
