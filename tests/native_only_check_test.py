"""The script test driver can use a published binary without native source."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class NativeOnlyCheck(unittest.TestCase):
    def test_missing_native_fails_before_test_execution(self):
        result = subprocess.run(['sh', str(ROOT / 'scripts/check.sh'), '--native-bin', '/missing/zsetup'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('executable native binary required', result.stderr)

    def test_old_native_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            native = Path(tmp) / 'zsetup'
            native.write_text('#!/bin/sh\nprintf "zsetup 0.4.0\\n"\n')
            native.chmod(0o755)
            result = subprocess.run(['sh', str(ROOT / 'scripts/check.sh'), '--native-bin', str(native)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn('zsetup >=0.5.0 required', result.stderr)

    def test_source_checks_are_explicitly_excluded_but_runtime_suites_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); native = root / 'zsetup'
            native.write_text('#!/bin/sh\nprintf "zsetup 0.5.0\\n"\n'); native.chmod(0o755)
            # Only replace suite execution; test the real shell driver's dispatch.
            runner = root / 'python3'; log = root / 'calls'
            runner.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$CALL_LOG"\n')
            runner.chmod(0o755)
            result = subprocess.run(['sh', str(ROOT / 'scripts/check.sh'), '--native-bin', str(native)],
                env=os.environ | {'PATH': str(root) + ':' + os.environ['PATH'], 'CALL_LOG': str(log)}, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = log.read_text()
            for suite in ('install_bounds_test.py', 'privilege_bridge_test.py', 'ddnsto_test.py', 'linkease_test.py'):
                self.assertIn(suite, calls)
            self.assertNotIn('app_release_test.py', calls)
            self.assertNotIn('/tests/package_test.py', calls)
            self.assertIn('aggregate packaging not checked', result.stdout)


if __name__ == '__main__':
    unittest.main()
