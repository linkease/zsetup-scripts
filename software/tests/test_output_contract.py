import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class OutputContract(unittest.TestCase):
    def test_oversize_unicode_result_is_explicit_and_bounded(self):
        with tempfile.TemporaryDirectory(prefix='output 中文 ') as tmp:
            payload = Path(tmp) / 'details.json'
            payload.write_text(json.dumps({'data': '汉' * 30000}, ensure_ascii=False))
            result = subprocess.run(['bash', '-c',
                '. "$1"; task_result success observed 0 "$(cat "$2")"',
                'contract', str(ROOT / 'software/protocol.sh'), str(payload)], capture_output=True)
            self.assertLessEqual(len(result.stdout), 65536)
            self.assertEqual(result.returncode, 20, result.stderr)
            self.assertEqual(json.loads(result.stdout)['reason'], 'result-too-large')

    def test_known_version_query_never_returns_arbitrary_program_output(self):
        for code in [0, 7]:
            with self.subTest(exitCode=code), tempfile.TemporaryDirectory() as tmp:
                base = Path(tmp)
                git = base / 'git'
                git.write_text(f'#!/bin/sh\necho "git version 2.3.4 private-sentinel-value"\nexit {code}\n')
                git.chmod(0o755)
                request = base / 'request.json'
                request.write_text('{"software":"git","targetId":"local"}')
                result = subprocess.run(['bash', str(ROOT / 'software/task.sh'), 'query', str(request)],
                    env={**os.environ, 'PATH': str(base) + os.pathsep + os.environ['PATH']}, capture_output=True)
                self.assertNotIn(b'private-sentinel-value', result.stdout + result.stderr)
                body = json.loads(result.stdout)
                if code == 0:
                    self.assertEqual(body['details']['version'], '2.3.4')
                else:
                    self.assertEqual(body['nativeExitCode'], 7)

    def test_query_does_not_load_unrelated_installation_modules(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            shutil.copytree(ROOT / 'software', base / 'software')
            for name in ['container', 'artifact', 'release', 'backup', 'storage']:
                (base / f'software/{name}.sh').unlink()
            request = base / 'request.json'
            request.write_text('{"software":"bash","targetId":"local"}')
            result = subprocess.run(['bash', str(base / 'software/task.sh'), 'query', str(request)], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, b'')
            self.assertTrue(json.loads(result.stdout)['details']['installed'])


if __name__ == '__main__':
    unittest.main()
