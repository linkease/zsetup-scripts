"""Default OpenWrt identity/version decisions against real UCI fixture files."""
import os
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'ddnsto/tests'))
import openwrt_lifecycle_test as fixtures


class AutoOpenWrt(unittest.TestCase):
    setUp = fixtures.OpenWrtLifecycleTests.setUp

    def invoke(self, token='old-secret', pending='', body='ddnsto_ensure_ow_account'):
        script = 'set -eu\n' + ''.join(f'. "{ROOT / p}"\n' for p in (
            'ddnsto/business.sh', 'ddnsto/auto-install.sh',
            'ddnsto/openwrt-lifecycle.sh', 'ddnsto/openwrt-adapter.sh'))
        path = ROOT / 'ddnsto/auto-openwrt.sh'
        if path.exists(): script += f'. "{path}"\n'
        script += '''
ddnsto_openwrt_paths
ddnsto_openwrt_protected() { [ -f "$config" ]; }
package_manager=opkg
ENSURE_TOKEN=$1
''' + body
        return subprocess.run(['sh', '-c', script, 'test', token], text=True, capture_output=True,
            env=os.environ | {'FIXTURE': str(self.root), 'PATH': str(self.tools) + ':' + os.environ['PATH'],
                'DDNSTO_CONFIG_PATH': str(self.config), 'DDNSTO_OPENWRT_BIN_PATH': str(self.binary),
                'DDNSTO_SERVICE_PATH': str(self.service), 'PENDING': pending}, timeout=10)

    def test_account_comparison_preserves_all_config(self):
        before = self.config.read_bytes()
        for token, expected in [('old-secret', 0), ('other-secret', 2), ('', 2)]:
            result = self.invoke(token)
            self.assertEqual(result.returncode, expected, result.stderr)
            self.assertEqual(self.config.read_bytes(), before)
            self.assertNotIn('old-secret', result.stdout + result.stderr)
            self.assertNotIn('other-secret', result.stdout + result.stderr)

    def test_pending_changes_or_multiple_sections_are_not_rebound(self):
        result = self.invoke(pending='ddnsto.@ddnsto[0].token=changed')
        self.assertEqual(result.returncode, 2, result.stderr)
        self.config.write_text(self.config.read_text() + '\nconfig ddnsto\n')
        result = self.invoke()
        self.assertEqual(result.returncode, 2)
        self.assertIn('E_CONFIG', result.stderr)

    def test_version_from_package_metadata_not_untrusted_executable(self):
        result = self.invoke(body='ddnsto_ensure_ow_version')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), '4.2.6')

    def test_running_requires_same_procd_pid(self):
        result = self.invoke(body='''
ensure_pid_fixture=123
ddnsto_ensure_ow_pid() { printf '%s' "$ensure_pid_fixture"; }
sleep() { ensure_pid_fixture=456; }
ddnsto_ensure_ow_running
''')
        self.assertEqual(result.returncode, 13, result.stderr)

    def test_package_revision_must_be_known_not_prerelease(self):
        for version, expected in [('4.2.8-1', 0), ('4.2.8-r2', 0), ('4.2.8', 0),
                                  ('4.2.9~r1', 2), ('4.2.9--1', 2), ('4.2.9-r', 2)]:
            result = self.invoke(body="opkg() { printf '%s\\n' 'ddnsto - " + version + "'; }; ddnsto_ensure_ow_version")
            self.assertEqual(result.returncode, expected, result.stderr)

    def test_official_architecture_suffix_matches_device(self):
        for arch, suffix in [('x86_64', '8664'), ('aarch64', 'aa64'),
                             ('armv7', 'aa32'), ('mipsel', '1b0c')]:
            for version, expected in [(f'4.2.8~{suffix}-r1', 0),
                                      (f'4.2.8~{suffix}-1', 0),
                                      ('4.2.8~rc1-r1', 2), ('4.2.8~ffff-r1', 2),
                                      (f'4.2.8~{suffix}', 2),
                                      (f'4.2.8~{suffix}-r', 2)]:
                with self.subTest(arch=arch, version=version):
                    result = self.invoke(body="arch=" + arch + "; opkg() { printf '%s\\n' 'ddnsto - " + version + "'; }; ddnsto_ensure_ow_version")
                    self.assertEqual(result.returncode, expected, result.stderr)
                    if expected == 0:
                        self.assertEqual(result.stdout.strip(), '4.2.8')
        result = self.invoke(body="arch=x86_64; opkg() { printf '%s\\n' 'ddnsto - 4.2.8~aa64-r1'; }; ddnsto_ensure_ow_version")
        self.assertEqual(result.returncode, 2)


if __name__ == '__main__':
    unittest.main()
