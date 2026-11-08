import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ENTRY = Path(__file__).resolve().parents[1] / 'task.sh'


class StoragePlan(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.disk = self.root / 'data'
        self.disk.mkdir()
        self.request = {'software': 'jq', 'targetId': 'storage-test', 'storage': {
            'reserveBytes': 1048576, 'paths': [
                {'role': 'download', 'path': str(self.disk), 'bytes': 1048576},
                {'role': 'installed', 'path': str(self.disk), 'bytes': 2097152}]}}

    def call(self, operation):
        p = self.root / 'request.json'
        p.write_text(json.dumps(self.request))
        r = subprocess.run(['bash', str(ENTRY), operation, str(p)],
                           env={**os.environ, 'ZSETUP_TASK_TARGET_ID': 'storage-test'}, text=True, capture_output=True)
        return r, json.loads(r.stdout)

    def test_same_filesystem_budget_is_aggregated_and_plan_is_read_only(self):
        r, result = self.call('storage-plan')
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertEqual(result['effects'], [])
        plan = result['details']
        self.assertEqual(len(plan['volumes']), 1)
        self.assertEqual(plan['volumes'][0]['requiredBytes'], 4194304)
        self.assertEqual(list(self.disk.iterdir()), [])
        self.request['storagePlan'] = plan
        r, result = self.call('storage-check')
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)

    def test_insufficient_space_blocks_before_any_write(self):
        self.request['storage']['paths'][0]['bytes'] = 10**15
        r, result = self.call('storage-plan')
        self.assertEqual(r.returncode, 21)
        self.assertEqual(result['reason'], 'insufficient-space')
        self.assertEqual(list(self.disk.iterdir()), [])

    def test_replaced_directory_invalidates_old_plan(self):
        r, result = self.call('storage-plan')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.request['storagePlan'] = result['details']
        self.disk.rename(self.root / 'old-data')
        self.disk.mkdir()
        r, result = self.call('storage-check')
        self.assertEqual(r.returncode, 21)
        self.assertEqual(result['reason'], 'storage-identity-changed')

    def test_symlink_target_is_not_followed(self):
        alias = self.root / 'alias'
        alias.symlink_to(self.disk, target_is_directory=True)
        self.request['storage']['paths'][0]['path'] = str(alias)
        r, result = self.call('storage-plan')
        self.assertEqual(r.returncode, 21)
        self.assertEqual(result['reason'], 'unsafe-storage-path')

    def test_reduced_budget_cannot_reuse_old_plan(self):
        r, result = self.call('storage-plan')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.request['storagePlan'] = result['details']
        self.request['storage']['reserveBytes'] = 0
        r, result = self.call('storage-check')
        self.assertEqual(r.returncode, 21)
        self.assertEqual(result['reason'], 'storage-plan-changed')


if __name__ == '__main__':
    unittest.main()
