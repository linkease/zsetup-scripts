"""Process product selection: real planner, isolated storage facts."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ProductPlan(unittest.TestCase):
    def plan(self, available='104857600', old='', business='production', arch='x86_64', force=''):
        with tempfile.TemporaryDirectory() as directory:
            script = '''set -eu
. "$REPO/lib/install-storage.sh"
. "$REPO/lib/install-bounds.sh"
. "$REPO/sources/ddnsto/managed-cli.sh"
. "$REPO/sources/ddnsto/auto-install.sh"
. "$REPO/sources/ddnsto/product-pins.sh"
if [ -f "$REPO/sources/ddnsto/process-product.sh" ]; then
 . "$REPO/sources/ddnsto/process-product.sh"
fi
probe() { echo "$AVAILABLE"; }
ZSETUP_BIN=probe
ddnsto_process_error() { printf '%s: %s\n' "$1" "$2" >&2; }
ddnsto_process_product_plan
printf '%s %s %s\n' "$PROCESS_VARIANT" "$PROCESS_VERSION" "$PROCESS_REQUIRED_BYTES"
'''
            return subprocess.run(['sh', '-c', script], capture_output=True, text=True,
                env=os.environ | dict(REPO=str(ROOT), AVAILABLE=available,
                    PROCESS_PREFIX=directory, PROCESS_OLD_VERSION=old,
                    BUSINESS_ENV=business, arch=arch, FORCE_VERSION=force))

    def test_explicit_lite_uses_zig_even_with_ample_space(self):
        r = self.plan(force='lite')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(r.stdout.startswith('zig 4.2.1 '), r.stdout)

    def test_normal_space_uses_standard(self):
        r = self.plan()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(r.stdout.startswith('standard 4.2.8 '), r.stdout)

    def test_small_fresh_install_uses_verified_raw_zig(self):
        r = self.plan(available=str(3 * 1048576))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(r.stdout.startswith('zig 4.2.1 '), r.stdout)
        self.assertLess(int(r.stdout.split()[2]), 3 * 1048576)

    def test_never_downgrades_existing_install_for_space(self):
        r = self.plan(available=str(3 * 1048576), old='4.2.8')
        self.assertEqual(r.returncode, 12, r.stderr)
        self.assertIn('E_SPACE', r.stderr)
        self.assertIn('降级', r.stderr)

    def test_unknown_space_is_explicit_failure(self):
        r = self.plan(available='unknown')
        self.assertEqual(r.returncode, 12, r.stderr)
        self.assertIn('E_STORAGE', r.stderr)

    def test_tiny_space_is_not_accepted(self):
        r = self.plan(available='1024')
        self.assertEqual(r.returncode, 12, r.stderr)
        self.assertIn('E_SPACE', r.stderr)

    def test_test_environment_does_not_use_unverified_zig_assignment(self):
        r = self.plan(available=str(3 * 1048576), business='test')
        self.assertEqual(r.returncode, 12, r.stderr)
        self.assertIn('测试环境', r.stderr)

    def test_raw_fetch_does_not_require_tar(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / 'fixture'
            binary.write_text('#!/bin/sh\necho 4.2.1\n')
            script = '''set -eu
. "$REPO/sources/ddnsto/process-install.sh"
PROCESS_VARIANT=zig; PROCESS_VERSION=4.2.1
PROCESS_PRODUCT_PATH=ddnsto-zig/ddnsto.x86_64
PROCESS_DIGEST=fixture-sha; PROCESS_DOWNLOAD_BYTES=752664
installer_download() {
 [ "$1" = ddnsto-zig/ddnsto.x86_64 ] && [ "$3" = fixture-sha ] && [ "$5" = 752664 ] || return 98
 cp "$FIXTURE" "$2"
}
installer_extract_member() { echo 'unexpected archive extraction' >&2; return 97; }
ddnsto_linux_environment_capability() { :; }
ddnsto_process_error() { echo "$*" >&2; }
ddnsto_process_fetch
'''
            result = subprocess.run(['sh', '-c', script], text=True, capture_output=True,
                env=os.environ | dict(REPO=str(ROOT), FIXTURE=str(binary), transaction_dir=directory, arch='x86_64'))
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
