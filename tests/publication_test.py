#!/usr/bin/env python3
"""Publication audit fails closed when DDNSTO entries or metadata are absent."""
import importlib.util
import hashlib
import json
from pathlib import Path
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/check-publication.py'


class Publication(unittest.TestCase):
    def test_direct_mode_checks_powershell_but_does_not_require_index(self):
        spec = importlib.util.spec_from_file_location('publication', SCRIPT)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        requested = []
        def fetch(path):
            requested.append(path)
            if path.endswith('install.ps1'):
                return (mod.ROOT / 'ddnsto/install.ps1').read_bytes()
            if path.endswith('install.sh'):
                return (mod.ROOT / 'ddnsto/install.sh').read_bytes()
            return b'{}'
        result = mod.audit('https://fixture.invalid/binary', fetch=fetch, mode='direct')
        self.assertNotIn('zsetup/config.json', requested)
        self.assertIn('ddnsto/install.ps1', requested)
        self.assertIn('ddnsto/0.1.7/install.ps1', requested)
        self.assertTrue(all(c['ok'] for c in result['checks'] if c['path'].endswith(('.sh', '.ps1'))))
        self.assertFalse(result['publication_inputs_ready'], 'products still need checksum metadata')

    def test_complete_metadata_and_stale_config(self):
        spec = importlib.util.spec_from_file_location('publication', SCRIPT)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        installer = (mod.ROOT / 'ddnsto/install.sh').read_bytes()
        digest = hashlib.sha256(installer).hexdigest()
        catalog = json.loads((mod.ROOT / 'catalog.json').read_text())
        records = [dict(r, sha256=digest, size=len(installer)) for r in catalog['installers'] if r['application'] == 'ddnsto']
        def fetch(path):
            if path.endswith('install.sh'):
                return installer
            if path == 'zsetup/config.json':
                return json.dumps({'installers': records}).encode()
            if path.endswith(('VERSION', 'VERSION_LITE')):
                return b'4.2.3\n'
            ext = 'apk' if '-apk/' in path else 'ipk'
            names = ['ddnsto-standard-4.2.3.tar.gz'] if 'linux-binary' in path else [f'ddnsto_{a}.{ext}' for a in ('x86_64', 'aarch64', 'arm', 'mipsel')] + [f'luci-app-ddnsto.{ext}', f'luci-i18n-ddnsto-zh-cn.{ext}']
            return ''.join(f'{digest}  {name}\n' for name in names).encode()
        result = mod.audit('https://fixture.invalid/binary', fetch=fetch)
        self.assertTrue(result['publication_inputs_ready'], result)
        self.assertEqual(result['device_canary'], 'not_checked')
        records[0]['sha256'] = '0' * 64
        self.assertFalse(mod.audit('https://fixture.invalid/binary', fetch=fetch)['publication_inputs_ready'])

    def test_missing_installer_is_not_ready(self):
        self.assertTrue(SCRIPT.is_file(), 'missing publication checker')
        spec = importlib.util.spec_from_file_location('publication', SCRIPT)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        result = mod.audit('https://fixture.invalid/binary', fetch=lambda path: b'{}')
        self.assertFalse(result['publication_inputs_ready'])
        self.assertTrue(any(not item['ok'] for item in result['checks']))

    def test_checksum_rejects_duplicates_and_bad_digest(self):
        self.assertTrue(SCRIPT.is_file(), 'missing publication checker')
        spec = importlib.util.spec_from_file_location('publication', SCRIPT)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        digest = hashlib.sha256(b'fixture').hexdigest()
        self.assertEqual(mod.parse_sums(f'{digest}  client\n'.encode())['client'], digest)
        for data in (b'bad  client\n', f'{digest}  client\n{digest}  client\n'.encode()):
            with self.assertRaises(ValueError):
                mod.parse_sums(data)


if __name__ == '__main__':
    unittest.main()
