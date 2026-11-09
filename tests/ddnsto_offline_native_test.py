"""Offline native discovery: real hash/path validation, no download or services."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class OfflineNative(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.native = self.root / 'rescue/0.5.0/zsetup'
        self.native.parent.mkdir(parents=True)
        self.native.write_text('#!/bin/sh\nprintf "zsetup 0.5.0\\n"\n')
        self.native.chmod(0o700)
        self.digest = hashlib.sha256(self.native.read_bytes()).hexdigest()

    def run_native(self, explicit=''):
        script = ''.join(f'. "{ROOT / p}"\n' for p in (
            'lib/bootstrap.sh', 'ddnsto/bootstrap-policy.sh', 'ddnsto/managed-service.sh'))
        script += '''
ddnsto_error() { printf '%s\\n' "$*" >&2; }
# Replace only reviewed metadata, not validation or discovery behavior.
fetch_bootstrap_metadata() { RESCUE_VERSION=0.5.0; EXPECTED_SHA256=$TEST_DIGEST; }
bootstrap_fetch() { echo NETWORK >&2; return 99; }
ddnsto_managed_native || exit $?
printf '%s\\n' "$ZSETUP_BIN"
'''
        env = dict(os.environ, ZSETUP_ROOT=str(self.root), ZSETUP_BIN=explicit,
                   TEST_DIGEST=self.digest, PATH='/usr/bin:/bin')
        return subprocess.run(['sh', '-eu', '-c', script], env=env,
                              capture_output=True, text=True, timeout=5)

    def test_fresh_shell_finds_verified_cache_without_network(self):
        result = self.run_native()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(self.native))
        self.assertNotIn('NETWORK', result.stderr)

    def test_explicit_tampered_executable_never_runs(self):
        marker = self.root / 'executed'
        self.native.write_text(f'#!/bin/sh\ntouch "{marker}"\necho "zsetup 0.5.0"\n')
        result = self.run_native(str(self.native))
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertFalse(marker.exists())

    def test_symlink_or_writable_cache_is_rejected(self):
        self.native.chmod(0o777)
        self.assertEqual(self.run_native().returncode, 2)
        self.native.chmod(0o700)
        actual = self.root / 'actual'
        self.native.rename(actual)
        self.native.symlink_to(actual)
        self.assertEqual(self.run_native().returncode, 2)

    def test_missing_cache_has_no_download(self):
        self.native.unlink()
        result = self.run_native()
        self.assertEqual(result.returncode, 2)
        self.assertIn('offline', result.stderr)
        self.assertNotIn('NETWORK', result.stderr)


if __name__ == '__main__':
    unittest.main()
