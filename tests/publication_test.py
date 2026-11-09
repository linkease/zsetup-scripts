"""Publication audit follows current pinned artifacts, never old pointers."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('publication', ROOT / 'scripts/check-publication.py')
publication = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publication)


class Publication(unittest.TestCase):
    def setUp(self):
        self.requested = []
        self.shell = (ROOT / 'ddnsto/ddnsto-install.sh').read_bytes()
        catalog = json.loads((ROOT / 'catalog.json').read_text())
        self.records = [dict(r, sha256=hashlib.sha256(self.shell).hexdigest(), size=len(self.shell))
                        for r in catalog['installers'] if r['application'] == 'ddnsto']
        history = json.loads((ROOT / 'docs/ddnsto-artifacts-2026-11-03.json').read_text())
        self.products = {'ddnsto/' + r['source_path']: (r['sha256'], r['size'])
                         for r in history['files'] if not r['source_path'].endswith(('VERSION', 'VERSION_LITE'))}

    def fetch(self, path):
        self.requested.append(path)
        if path == 'zsetup/config.json':
            return json.dumps({'installers': self.records}).encode()
        if path.endswith('install.ps1'):
            return (ROOT / 'ddnsto/install.ps1').read_bytes()
        if path.endswith('install.sh'):
            return self.shell
        raise AssertionError('unexpected metadata request: ' + path)

    def product(self, path):
        self.requested.append(path)
        return self.products[path]

    def audit(self, **kwargs):
        return publication.audit('https://fixture.invalid/binary', fetch=self.fetch,
                                 fetch_product=self.product, **kwargs)

    def test_default_does_not_claim_product_verification(self):
        result = self.audit(mode='direct')
        self.assertTrue(result['entrypoints_ready'], result)
        self.assertFalse(result['publication_inputs_ready'])
        self.assertEqual(result['product_bytes'], 'not_downloaded')
        self.assertNotIn('zsetup/config.json', self.requested)
        for directory in ('ddnsto', str(Path(self.records[0]['path']).parent)):
            for name in ('ddnsto-install.sh', 'install.sh', 'install.ps1'):
                self.assertIn(directory + '/' + name, self.requested)

    def test_current_products_without_checksum_sidecars(self):
        result = self.audit(verify_products=True)
        self.assertTrue(result['publication_inputs_ready'], result)
        self.assertEqual(result['device_canary'], 'not_checked')
        self.assertEqual(result['product_bytes'], 'verified')
        self.assertTrue(self.products.keys() <= set(self.requested))
        self.assertFalse(any('4.2.3' in p or p.endswith(('SHA256SUMS', 'VERSION', 'VERSION_LITE')) for p in self.requested))

    def test_stale_config_rejected(self):
        self.records[0]['sha256'] = '0' * 64
        self.assertFalse(self.audit(verify_products=True)['publication_inputs_ready'])

    def test_windows_is_checked_in_indexed_mode_too(self):
        original = self.fetch
        self.fetch = lambda p: b'stale' if p.endswith('.ps1') else original(p)
        self.assertFalse(self.audit(verify_products=True)['publication_inputs_ready'])

    def test_changed_product_digest_or_size_rejected(self):
        path = 'ddnsto/linux-binary/ddnsto-standard-4.2.8.tar.gz'
        digest, size = self.products[path]
        for value in [('0' * 64, size), (digest, size + 1)]:
            with self.subTest(value=value):
                self.products[path] = value
                result = self.audit(verify_products=True)
                self.assertFalse(result['publication_inputs_ready'])
                self.assertEqual(result['product_bytes'], 'failed')

    def test_missing_entry_is_structured_failure(self):
        self.fetch = lambda p: b'{}'
        self.assertFalse(self.audit()['publication_inputs_ready'])

    def test_manifest_must_match_current_installer_pins(self):
        original = Path.read_text
        digest = self.products['ddnsto/linux-binary/ddnsto-standard-4.2.8.tar.gz'][0]
        def changed(path, *args, **kwargs):
            data = original(path, *args, **kwargs)
            return data.replace(digest, '0' * 64) if path.name == 'product-pins.sh' else data
        with patch.object(Path, 'read_text', changed):
            result = self.audit(verify_products=True)
        self.assertFalse(result['publication_inputs_ready'])
        self.assertEqual(result['product_bytes'], 'failed')

    def test_product_reader_hashes_stream_and_rejects_http_redirect(self):
        response = io.BytesIO(b'payload')
        response.url = 'https://fixture.invalid/file'
        with patch.object(publication, 'urlopen', return_value=response):
            self.assertEqual(publication.remote_product('https://fixture.invalid/file'),
                             (hashlib.sha256(b'payload').hexdigest(), 7))
        response = io.BytesIO(b'payload')
        response.url = 'http://fixture.invalid/file'
        with patch.object(publication, 'urlopen', return_value=response):
            with self.assertRaises(ValueError):
                publication.remote_product('https://fixture.invalid/file')

    def test_checksum_rejects_duplicates_and_bad_digest(self):
        digest = hashlib.sha256(b'fixture').hexdigest()
        self.assertEqual(publication.parse_sums(f'{digest}  client\n'.encode())['client'], digest)
        for data in (b'bad  client\n', f'{digest}  client\n{digest}  client\n'.encode()):
            with self.assertRaises(ValueError):
                publication.parse_sums(data)


if __name__ == '__main__':
    unittest.main()
