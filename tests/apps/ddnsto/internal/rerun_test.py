#!/usr/bin/env python3
"""Current default entry is noninteractive, token-bound and version-pinned."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[4]
ENTRY = ROOT / 'apps/ddnsto/0.2.4/installer.sh'


class RerunTest(unittest.TestCase):
    def invoke(self, args=(), *, input_text=None, extra_env=None):
        with tempfile.TemporaryDirectory(prefix='ddnsto-entry-policy-') as tmp:
            root = Path(tmp)
            tools = root / 'tools'; tools.mkdir()
            for name in ('curl', 'wget'):
                tool = tools / name
                tool.write_text('#!/bin/sh\necho UNEXPECTED_DOWNLOAD >&2\nexit 99\n')
                tool.chmod(0o755)
            env = os.environ | {
                'PATH': str(tools) + ':/usr/bin:/bin',
                'ZSETUP_INSTALLER_MODE': '1', 'ZSETUP_BIN': '/bin/false',
                'ZSETUP_OS': 'linux', 'ZSETUP_PACKAGE_MANAGER': 'unknown',
                'ZSETUP_ARCH': 'x86_64', 'TMPDIR': tmp,
            } | (extra_env or {})
            result = subprocess.run(['sh', str(ENTRY), *args], env=env,
                                    input=input_text, capture_output=True,
                                    text=True, timeout=5)
            self.assertNotIn('UNEXPECTED_DOWNLOAD', result.stderr)
            self.assertFalse((root / 'work').exists())
            return result

    def test_help_describes_current_noninteractive_ensure(self):
        result = self.invoke(('--help',))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('--action ensure', result.stdout)
        self.assertIn('--token TOKEN', result.stdout)

    def test_default_requires_token_before_download(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn('E_TOKEN', result.stderr)

    def test_stdin_does_not_enable_the_removed_menu(self):
        result = self.invoke(input_text='1\nfixture-token\n')
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn('E_TOKEN', result.stderr)
        self.assertNotIn('Choose', result.stdout + result.stderr)

    def test_docker_is_rejected_before_download(self):
        result = self.invoke(('--method', 'docker', '--token', 'fixture-token'))
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn('E_METHOD', result.stderr)

    def test_manual_version_options_are_rejected(self):
        for args in (('--force-version', 'lite'), ('--verify-status',)):
            with self.subTest(args=args):
                result = self.invoke((*args, '--token', 'fixture-token'))
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn('OpenWrt options are not supported on Linux', result.stderr)

    def test_default_rejects_nonreviewed_client_identity(self):
        result = self.invoke(('--token', 'fixture-token'),
                             extra_env={'DDNSTO_VERSION': '4.2.7'})
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn('E_VERSION', result.stderr)

    def test_update_cannot_accept_credentials(self):
        result = self.invoke(('--action', 'update', '--token', 'secret-value'))
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertNotIn('secret-value', result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
