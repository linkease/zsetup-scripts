#!/usr/bin/env python3
"""Pinned product selection must work with no business metadata on the CDN."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HISTORY = json.loads((ROOT / 'docs/ddnsto-artifacts-2026-10-08.json').read_text())
EXPECTED = {x['source_path']: x['sha256'] for x in HISTORY['files']
            if not x['source_path'].endswith(('VERSION', 'VERSION_LITE'))}
HARNESS = r'''
. "$BUSINESS"
[ ! -f "$PINS" ] || . "$PINS"
status() { :; }
ddnsto_download() { printf 'UNEXPECTED_METADATA %s\n' "$1"; return 91; }
ddnsto_verified_download() { printf 'PRODUCT %s %s\n' "$1" "$3"; }
opkg() { printf 'MUTATION opkg %s\n' "$*"; }
apk() { printf 'MUTATION apk %s\n' "$*"; }
ddnsto() { :; }
FORCE_VERSION=$VARIANT
VERIFY_STATUS=0
TOKEN=
work_dir=$TEST_ROOT/work
transaction_dir=$TEST_ROOT/transaction
package_manager=$PM
arch=$ARCH
ZSETUP_BIN=/not-an-installed-native
ddnsto_openwrt
'''


class PinnedProducts(unittest.TestCase):
    def test_all_openwrt_targets_use_existing_paths_and_pinned_digests(self):
        for pm, ext in [('opkg', 'ipk'), ('apk', 'apk')]:
            for variant, version in [('standard', '4.2.6'), ('lite', '4.2.2')]:
                for arch, member in [('x86_64', 'x86_64'), ('aarch64', 'aarch64'), ('armv7', 'arm'), ('mipsel', 'mipsel')]:
                    with self.subTest(pm=pm, variant=variant, arch=arch), tempfile.TemporaryDirectory() as tmp:
                        env = os.environ | {'BUSINESS': str(ROOT / 'ddnsto/business.sh'),
                            'PINS': str(ROOT / 'ddnsto/product-pins.sh'), 'TEST_ROOT': tmp,
                            'DDNSTO_CONFIG_PATH': tmp + '/config', 'PM': pm, 'ARCH': arch, 'VARIANT': variant}
                        result = subprocess.run(['sh', '-eu', '-c', HARNESS], env=env, capture_output=True, text=True)
                        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                        folder = variant + ('-apk' if pm == 'apk' else '')
                        paths = [f'openwrt/{folder}/{version}/ddnsto_{member}.{ext}',
                                 f'openwrt/luci-app-ddnsto.{ext}', f'openwrt/luci-i18n-ddnsto-zh-cn.{ext}']
                        actual = [line.split()[1:] for line in result.stdout.splitlines() if line.startswith('PRODUCT ')]
                        self.assertEqual(actual, [[path, EXPECTED[path]] for path in paths])
                        self.assertNotIn('UNEXPECTED_METADATA', result.stdout)

    def test_unknown_product_is_rejected_without_digest(self):
        source = ROOT / 'ddnsto/product-pins.sh'
        self.assertTrue(source.is_file(), 'missing embedded product pins')
        result = subprocess.run(['sh', '-c', '. "$1"; ddnsto_pinned_sha "linux-binary/unknown.tar.gz"', 'sh', str(source)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 11, result.stderr)
        self.assertEqual(result.stdout, '')

    def test_linux_archive_digest_is_pinned(self):
        source = ROOT / 'ddnsto/product-pins.sh'
        self.assertTrue(source.is_file(), 'missing embedded product pins')
        path = 'linux-binary/ddnsto-standard-4.2.3.tar.gz'
        result = subprocess.run(['sh', '-c', '. "$1"; ddnsto_pinned_sha "$2"', 'sh', str(source), path], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), EXPECTED[path])


if __name__ == '__main__':
    unittest.main()
