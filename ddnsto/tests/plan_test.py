#!/usr/bin/env python3
"""Public Shell plan must never bootstrap, prompt, or touch managed files."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class PlanTest(unittest.TestCase):
    def run_plan(self, args=(), system='Linux', arch='x86_64', extra_env=None):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tool = root / 'uname'
            tool.write_text('#!/bin/sh\ncase "$1" in -s) echo "$TEST_SYSTEM";; -m) echo "$TEST_ARCH";; esac\n')
            tool.chmod(0o755)
            for name in ('curl', 'wget', 'launchctl', 'sudo', 'systemctl'):
                stub = root / name
                stub.write_text('#!/bin/sh\necho MUTATION >&2\nexit 99\n')
                stub.chmod(0o755)
            env = os.environ | dict(PATH=str(root) + ':/usr/bin:/bin', TEST_SYSTEM=system,
                TEST_ARCH=arch, ZSETUP_ROOT=str(root / 'cache'), ZSETUP_BIN='',
                DDNSTO_INSTALL_DIR=str(root / 'install'), DDNSTO_CONFIG_DIR=str(root / 'config'),
                DDNSTO_LAUNCH_AGENTS_DIR=str(root / 'agents'))
            env.update(extra_env or {})
            r = subprocess.run(['sh', str(ROOT / 'ddnsto/install.sh'), '--plan', *args], env=env,
                               capture_output=True, text=True, timeout=10)
            for name in ('cache', 'install', 'config', 'agents'):
                self.assertFalse((root / name).exists(), name)
            self.assertNotIn('MUTATION', r.stderr)
            return r

    def test_linux_plan_without_token_or_download(self):
        r = self.run_plan(('--platform', 'linux', '--method', 'native'))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('platform=linux', r.stdout)
        self.assertIn('client_version=4.2.3', r.stdout)
        self.assertIn('installation_performed=false', r.stdout)

    def test_mac_plan_uses_shared_public_entry(self):
        r = self.run_plan(('--platform', 'macos', '--method', 'native'), system='Darwin', arch='arm64')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('platform=macos', r.stdout)
        self.assertIn('client_version=4.2.1', r.stdout)

    def test_mac_target_mismatch(self):
        r = self.run_plan(('--platform', 'linux'), system='Darwin')
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn('platform mismatch', r.stderr)

    def test_linux_target_mismatch(self):
        r = self.run_plan(('--platform', 'macos'))
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn('platform mismatch', r.stderr)

    def test_plan_rejects_credentials_without_echo(self):
        r = self.run_plan(('--token', 'never-print-this'))
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertNotIn('never-print-this', r.stdout + r.stderr)

    def test_unknown_architecture_is_not_installable(self):
        r = self.run_plan(arch='riscv64')
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn('unsupported architecture', r.stderr)

    def test_unpinned_linux_version_is_not_presented_as_candidate(self):
        r = self.run_plan(extra_env={'DDNSTO_VERSION': '999'})
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn('no pinned artifact', r.stderr)

    def test_linux_lite_is_rejected_in_preview(self):
        r = self.run_plan(('--force-version', 'lite'))
        self.assertEqual(r.returncode, 2, r.stderr)

    def test_linux_preview_cannot_ignore_synology_download_options(self):
        for args in [('--output-dir', '/tmp/not-created'), ('--action', 'download')]:
            r = self.run_plan(args)
            self.assertEqual(r.returncode, 2, r.stderr)


if __name__ == '__main__':
    unittest.main()
