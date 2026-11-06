#!/usr/bin/env python3
"""Pinned product selection must work with no business metadata on the CDN."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from openwrt_lifecycle_test import FAKE

ROOT = Path(__file__).resolve().parents[2]
HISTORY = json.loads((ROOT / 'docs/ddnsto-artifacts-2026-11-03.json').read_text())
EXPECTED = {x['source_path']: x['sha256'] for x in HISTORY['files']
            if not x['source_path'].endswith(('VERSION', 'VERSION_LITE'))}
HARNESS = r'''
. "$BUSINESS"
. "$LIBRARY/install-bounds.sh"
. "$LIBRARY/install-package.sh"
[ ! -f "$PINS" ] || . "$PINS"
status() { :; }
id() { printf '0\n'; }
ddnsto_download() { printf 'UNEXPECTED_METADATA %s\n' "$1"; return 91; }
product_count=0
ddnsto_verified_download() {
    printf 'PRODUCT %s %s\n' "$1" "$3"
    product_count=$((product_count + 1))
    # End before package mutation; the native namespace suite tests installation.
    [ "$product_count" -lt 3 ] || return 77
}
installer_package_cache() { PACKAGE_CACHE=$TEST_ROOT/cache; }
FORCE_VERSION=$VARIANT
VERIFY_STATUS=0
TOKEN=
ACTION=install
work_dir=$TEST_ROOT/work
transaction_dir=$TEST_ROOT/transaction
package_manager=$PM
arch=$ARCH
ZSETUP_BIN=/not-an-installed-native
ddnsto_openwrt
'''


class PinnedProducts(unittest.TestCase):
    def test_windows_archive_and_executable_match_published_428(self):
        artifact = next(x for x in HISTORY['files'] if x['source_path'].startswith('windows/'))
        source = (ROOT / 'ddnsto/install.ps1').read_text()
        self.assertIn("$Version = '4.2.8'", source)
        self.assertIn('--sha256 ' + artifact['sha256'], source)
        self.assertIn(artifact['members']['ddnsto_cli.x86_64.exe'], source)

    def test_verification_failure_propagates_even_in_conditional_caller(self):
        with tempfile.TemporaryDirectory() as tmp:
            script = r'''
. "$1"
. "$4/install-bounds.sh"
. "$4/install-package.sh"
ddnsto_download() { return 11; }
transaction_dir=$2
if ddnsto_verified_download product "$2/package" "$3"; then exit 0; else exit "$?"; fi
'''
            r = subprocess.run(['sh', '-eu', '-c', script, 'test', str(ROOT / 'ddnsto/business.sh'), tmp, 'a' * 64, str(ROOT / 'lib')], text=True, capture_output=True)
            self.assertEqual(r.returncode, 11, r.stderr)
            self.assertFalse((Path(tmp) / 'package.verified').exists())

    def test_same_size_tampered_cache_is_reverified_by_zsetup(self):
        with tempfile.TemporaryDirectory() as tmp:
            artifact = Path(tmp) / 'package'
            artifact.write_bytes(b'evil')
            (Path(tmp) / 'package.verified').write_text('a' * 64 + ':4\n')
            script = r'''
. "$1"
. "$4/install-bounds.sh"
. "$4/install-package.sh"
status() { :; }
ddnsto_download() { printf 'verified-download\n'; printf good > "$2"; }
transaction_dir=$2
ddnsto_verified_download product "$2/package" "$3"
'''
            r = subprocess.run(['sh', '-eu', '-c', script, 'test', str(ROOT / 'ddnsto/business.sh'), tmp, 'a' * 64, str(ROOT / 'lib')], text=True, capture_output=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(artifact.read_bytes(), b'good')

    def test_all_openwrt_targets_use_existing_paths_and_pinned_digests(self):
        for pm, ext in [('opkg', 'ipk'), ('apk', 'apk')]:
            for variant, version in [('standard', '4.2.8'), ('lite', '4.2.8')]:
                for arch, member in [('x86_64', 'x86_64'), ('aarch64', 'aarch64'), ('armv7', 'arm'), ('mipsel', 'mipsel')]:
                    with self.subTest(pm=pm, variant=variant, arch=arch), tempfile.TemporaryDirectory() as tmp:
                        # The shared tool fixture models package ownership and
                        # guarded postinst startup without touching the host.
                        fixture = Path(tmp)
                        for directory in ('tools', 'etc/config', 'etc/init.d', 'usr/sbin'):
                            (fixture / directory).mkdir(parents=True)
                        (fixture / 'packages').write_text('[]')
                        for tool in ('opkg', 'apk', 'uci'):
                            executable = fixture / 'tools' / tool
                            executable.write_text(FAKE)
                            executable.chmod(0o755)
                        env = os.environ | {'BUSINESS': str(ROOT / 'ddnsto/business.sh'),
                            'LIFECYCLE': str(ROOT / 'ddnsto/openwrt-lifecycle.sh'),
                            'LIBRARY': str(ROOT / 'lib'),
                            'PINS': str(ROOT / 'ddnsto/product-pins.sh'), 'TEST_ROOT': tmp,
                            'FIXTURE': tmp, 'PATH': str(fixture / 'tools') + ':' + os.environ['PATH'],
                            'DDNSTO_CONFIG_PATH': tmp + '/etc/config/ddnsto',
                            'DDNSTO_OPENWRT_BIN_PATH': tmp + '/usr/sbin/ddnstod',
                            'DDNSTO_SERVICE_PATH': tmp + '/etc/init.d/ddnsto',
                            'PM': pm, 'ARCH': arch, 'VARIANT': variant}
                        result = subprocess.run(['sh', '-eu', '-c', HARNESS], env=env, capture_output=True, text=True)
                        self.assertEqual(result.returncode, 77, result.stdout + result.stderr)
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
        path = 'linux-binary/ddnsto-standard-4.2.8.tar.gz'
        result = subprocess.run(['sh', '-c', '. "$1"; ddnsto_pinned_sha "$2"', 'sh', str(source), path], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), EXPECTED[path])


if __name__ == '__main__':
    unittest.main()
