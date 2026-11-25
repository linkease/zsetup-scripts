"""Regressions observed through the public entry on appliance firmware."""
import json
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BootstrapRegression(unittest.TestCase):
    def macos_fixture(self, architecture='arm64', layout='macos/', corrupt=False, missing=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifact = 'zsetup-macos-' + ('aarch64' if architecture == 'arm64' else 'x86_64')
            release = root / 'site/zsetup' / layout / '0.6.5'
            release.mkdir(parents=True)
            (root / 'site/zsetup/stable-macos').write_text('0.6.5\n')
            binary = b'#!/bin/sh\nprintf "zsetup 0.6.5\\n"\n'
            (release / artifact).write_bytes(binary + (b'# corrupted\n' if corrupt else b''))
            (release / 'SHA256SUMS').write_text(hashlib.sha256(binary).hexdigest() +
                '  ' + ('zsetup-windows-i686.exe' if missing else artifact) + '\n')
            p = self.shell(f'''
                WORK_ROOT='{root}/work'; BOOTSTRAP_BASES=https://example.invalid;
                uname() {{ case "$1" in -s) echo Darwin;; -m) echo {architecture};; esac; }};
                bootstrap_fetch_from_base() {{
                    printf '%s\\n' "$3" >> '{root}/requests';
                    cp '{root}/site/'"$3" "$4" 2>/dev/null;
                }};
                confirm_insecure_http() {{ echo HTTP_FORBIDDEN >&2; return 91; }};
                bootstrap_zsetup;
                "$ACTIVE_ZSETUP" --version
            ''')
            return p, (root / 'requests').read_text()

    def test_macos_platform_directory_both_architectures(self):
        for architecture in ('arm64', 'x86_64'):
            with self.subTest(architecture=architecture):
                p, requests = self.macos_fixture(architecture)
                self.assertEqual(p.returncode, 0, p.stderr)
                self.assertIn('zsetup 0.6.5', p.stdout)
                self.assertIn('zsetup/macos/0.6.5/SHA256SUMS', requests)
                self.assertNotIn('HTTP_FORBIDDEN', p.stderr)

    def test_macos_flat_directory_still_works(self):
        p, requests = self.macos_fixture(layout='')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn('zsetup/0.6.5/zsetup-macos-aarch64', requests)

    def test_macos_platform_directory_rejects_corruption(self):
        p, _ = self.macos_fixture(corrupt=True)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('checksum mismatch', p.stderr)
        self.assertNotIn('HTTP_FORBIDDEN', p.stderr)

    def test_macos_platform_directory_requires_matching_digest(self):
        p, requests = self.macos_fixture(missing=True)
        self.assertEqual(p.returncode, 11, p.stderr)
        self.assertNotIn('zsetup/macos/0.6.5/zsetup-macos-aarch64', requests)
        self.assertNotIn('HTTP_FORBIDDEN', p.stderr)

    def shell(self, body):
        return subprocess.run(['sh', '-c', '. "$1"; ' + body, 'probe',
                               str(ROOT / 'lib/bootstrap.sh')], capture_output=True, text=True)

    def test_download_detection_without_command_builtin(self):
        with tempfile.TemporaryDirectory() as directory:
            p = self.shell('command() { return 127; }; curl() { return 0; }; '
                           f'bootstrap_fetch_from_base https https://example.invalid test "{directory}/download"')
        self.assertEqual(p.returncode, 0, p.stderr)

    def test_hash_detection_without_command_builtin(self):
        p = self.shell('command() { return 127; }; sha256sum() { :; }; have_hash_tool')
        self.assertEqual(p.returncode, 0, p.stderr)

    def test_published_sums_missing_platform_are_not_accepted(self):
        with tempfile.TemporaryDirectory() as directory:
            sums = Path(directory) / 'sums'
            sums.write_text('a' * 64 + '  zsetup-windows-i686.exe\n')
            p = self.shell('BOOTSTRAP_BASES=https://example.invalid; '
                'ZSETUP_STABLE_PATH=zsetup/stable-macos; ZSETUP_ARTIFACT=zsetup-macos-aarch64; '
                'bootstrap_fetch_from_base() { :; }; '
                'read_stable_version() { RESCUE_VERSION=0.6.5; }; '
                f'fetch_bootstrap_metadata https /dev/null "{sums}"')
            self.assertEqual(p.returncode, 11, 'incomplete release is not a network/HTTP fallback failure')

    def test_catalog_fits_published_native_limit(self):
        config = json.loads((ROOT / 'apps/zsetup/config.json').read_text())
        self.assertLessEqual(len(config['installers']), 128)

    def test_synology_preflight_selects_private_executable_cache_before_bootstrap(self):
        entry = (ROOT / 'apps/ddnsto/install.sh').read_text()
        self.assertIn('ddnsto_entry_storage', entry)
        self.assertLess(entry.index('ddnsto_entry_storage\n'), entry.index('\nbootstrap_zsetup\n'))

    def test_synology_storage_rejects_unsafe_parent(self):
        source = ROOT / 'sources/ddnsto/entry-preflight.sh'
        self.assertTrue(source.is_file(), 'preflight is missing')
        p = subprocess.run(['sh', '-c', '. "$1"; '
            'ddnsto_bootstrap_safe_ancestors() { return 1; }; '
            'ddnsto_entry_private_storage /tmp/unsafe', 'probe', str(source)],
            capture_output=True, text=True)
        self.assertEqual(p.returncode, 12, p.stderr)

    def test_ddnsto_native_abi_does_not_replace_runtime_floor(self):
        config = json.loads((ROOT / 'apps/zsetup/config.json').read_text())
        record = next(r for r in config['installers'] if r['application'] == 'ddnsto')
        self.assertEqual(record['min_version'], '0.5.0')
        index_path = ROOT / 'apps/zsetup/ddnsto-index.json'
        self.assertTrue(index_path.exists(), 'published-native compatibility index missing')
        index = json.loads(index_path.read_text())
        self.assertTrue(all(r['min_version'] == '0.1.0' for r in index['entries']))
        payload = (ROOT / 'apps/ddnsto/versions/0.3.1/install.sh').read_text()
        self.assertIn('ddnsto_require_native_version', payload)
        guard = payload.split('# DDNSTO native floor end', 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            native = Path(directory) / 'zsetup'
            for version, expected in [('0.4.9', 2), ('0.5.0', 0), ('0.6.4', 0)]:
                native.write_text(f'#!/bin/sh\nprintf "zsetup {version}\\n"\n')
                native.chmod(0o700)
                p = subprocess.run(['sh', '-c', guard], env=dict(os.environ,
                    ZSETUP_INSTALLER_MODE='1', ZSETUP_BIN=str(native)), capture_output=True)
                self.assertEqual(p.returncode, expected, version)

    def test_windows_payload_has_explicit_argument_bridge(self):
        payload = (ROOT / 'apps/ddnsto/versions/0.3.1/install.ps1').read_text(encoding='utf-8-sig')
        self.assertIn('[Parameter(ValueFromRemainingArguments=$true)]', payload)
        self.assertIn('@DDNSTOParameters', payload)

    def test_standard_entry_uses_native_index_with_product_sources(self):
        entry = (ROOT / 'apps/ddnsto/install.sh').read_text()
        self.assertTrue('install --index "$index_file"' in entry)
        self.assertTrue('export ZSETUP_SOURCE_BASES ZSETUP_SOURCE_FALLBACK' in entry)

    def test_additional_ca_keeps_system_trust(self):
        source = (ROOT / 'lib/bootstrap.ps1').read_text()
        self.assertTrue('if (errors == SslPolicyErrors.None) return true;' in source)

    def test_windows_parent_decodes_utf8_native_output(self):
        entry = (ROOT / 'apps/ddnsto/install.ps1').read_text(encoding='utf-8-sig')
        self.assertTrue('[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)' in entry)

    def test_unrecognized_nas_reaches_business_fingerprint_checks(self):
        entry = (ROOT / 'apps/ddnsto/install.sh').read_text()
        self.assertTrue('ddnsto_entry_appliance "$@"' in entry)
        self.assertTrue('--sha256 "$entry_digest" --size "$entry_size"' in entry)

    @unittest.skipUnless(os.environ.get('DDNSTO_TEST_NATIVE'), 'set published native binary')
    def test_generated_catalog_is_accepted_by_real_native(self):
        p = subprocess.run([os.environ['DDNSTO_TEST_NATIVE'], 'install', '--list'],
            env=dict(os.environ, ZSETUP_CONFIG=str(ROOT / 'apps/zsetup/config.json')),
            capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn('ddnsto', p.stdout.splitlines())


if __name__ == '__main__':
    unittest.main()
