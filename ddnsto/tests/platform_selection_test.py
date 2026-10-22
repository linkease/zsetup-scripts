#!/usr/bin/env python3
"""Target selection only: never download packages or modify host services."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class PlatformSelectionTest(unittest.TestCase):
    def run_selection(self, system='linux', manager='unknown', device='linux', args=(), appliance=''):
        script = '''
set -eu
. "$BUSINESS"
ddnsto_appliance_platform() { printf '%s' "$APPLIANCE"; }
ddnsto_parse_args "$@"
os=$SYSTEM package_manager=$MANAGER device=$DEVICE
ddnsto_select_platform
printf 'SELECTED %s\n' "$business_platform"
'''
        env = os.environ | dict(BUSINESS=str(ROOT / 'ddnsto/business.sh'), SYSTEM=system,
                                MANAGER=manager, DEVICE=device, APPLIANCE=appliance)
        return subprocess.run(['sh', '-c', script, 'test', *args], env=env,
                              text=True, capture_output=True)

    def test_auto_preserves_existing_supported_routes(self):
        for system, manager, expected in [('ubuntu', 'apt', 'linux'), ('linux', 'unknown', 'linux'),
                                           ('openwrt', 'opkg', 'openwrt'), ('openwrt', 'apk', 'openwrt')]:
            with self.subTest(system=system, manager=manager):
                r = self.run_selection(system, manager)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(r.stdout.strip(), 'SELECTED ' + expected)

    def test_explicit_native_target(self):
        r = self.run_selection('ubuntu', 'apt', args=('--platform', 'linux', '--method', 'native'))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), 'SELECTED linux')

    def test_target_mismatch_never_falls_back(self):
        r = self.run_selection(args=('--platform', 'openwrt'))
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn('platform mismatch', r.stderr)

    def test_appliance_markers_override_generic_linux(self):
        for appliance in ('synology', 'qnap', 'unraid'):
            with self.subTest(appliance=appliance):
                r = self.run_selection(appliance=appliance)
                self.assertEqual(r.returncode, 2, r.stderr)
                self.assertIn(appliance, r.stderr)
                self.assertIn('not available', r.stderr)
                self.assertNotIn('SELECTED', r.stdout)

    def test_context_device_blocks_generic_linux(self):
        r = self.run_selection(device='synology')
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn('synology', r.stderr)

    def test_context_os_identifies_dsm(self):
        r = self.run_selection(system='dsm')
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn('synology', r.stderr)

    def test_explicit_linux_cannot_override_appliance(self):
        r = self.run_selection(appliance='synology', args=('--platform', 'linux'))
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn('platform mismatch', r.stderr)

    def test_docker_does_not_silently_install_native(self):
        r = self.run_selection(args=('--method', 'docker'))
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn('Docker installer is not available', r.stderr)

    def test_invalid_and_missing_selectors(self):
        for args in [('--platform',), ('--method',), ('--platform', 'typo'), ('--method', 'typo')]:
            with self.subTest(args=args):
                r = self.run_selection(args=args)
                self.assertEqual(r.returncode, 2, r.stderr)

    def test_unknown_os_does_not_become_linux(self):
        r = self.run_selection(system='unknown')
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn('unsupported platform', r.stderr)

    def test_appliance_files_are_read_not_executed(self):
        for marker, expected in [('etc/synoinfo.conf', 'synology'),
                                 ('etc/config/uLinux.conf', 'qnap'), ('etc/unraid-version', 'unraid')]:
            with self.subTest(marker=marker), tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / marker
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('exit 99\n')
                r = subprocess.run(['sh', '-eu', '-c', '. "$1"; ddnsto_appliance_platform "$2"',
                                    'test', str(ROOT / 'ddnsto/business.sh'), tmp], capture_output=True, text=True)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(r.stdout.strip(), expected)

    def test_generated_entry_rejects_mismatch_before_token_or_transaction(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = os.environ | dict(ZSETUP_INSTALLER_MODE='1', ZSETUP_BIN='/bin/false',
                ZSETUP_SOURCE_BASES='https://example.invalid', ZSETUP_OS='linux',
                ZSETUP_PACKAGE_MANAGER='unknown', ZSETUP_ARCH='x86_64', ZSETUP_WORK_DIR=tmp + '/work')
            r = subprocess.run(['sh', str(ROOT / 'ddnsto/install.sh'), '--platform', 'openwrt'],
                               env=env, capture_output=True, text=True, timeout=5)
            self.assertEqual(r.returncode, 2, r.stderr)
            self.assertIn('platform mismatch', r.stderr)
            self.assertFalse((Path(tmp) / 'work').exists())
            self.assertNotIn('token', r.stderr.lower())


if __name__ == '__main__':
    unittest.main()
