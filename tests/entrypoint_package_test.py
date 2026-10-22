#!/usr/bin/env python3
"""Direct one-command delivery must not require native source/build tools."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class EntrypointPackage(unittest.TestCase):
    def test_stages_two_self_contained_entries_without_native_source(self):
        script = ROOT / 'scripts/package-entrypoints.py'
        self.assertTrue(script.is_file(), 'missing source-independent entrypoint packager')
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / 'candidate'
            command = [sys.executable, '-B', str(script), '--output', str(output)]
            result = subprocess.run(command, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            manifest = json.loads((output / 'entrypoints-manifest.json').read_text())
            self.assertEqual(manifest['readiness'], 'candidate-not-published')
            self.assertFalse(manifest['includes_native_or_products'])
            files = {r['path']: r for r in manifest['files']}
            for name in ('install.sh', 'install.ps1'):
                alias = 'binary/ddnsto/' + name
                immutable = 'binary/ddnsto/0.2.0/' + name
                self.assertTrue((output / immutable).is_file(), immutable)
                self.assertEqual((output / alias).read_bytes(), (ROOT / 'ddnsto' / name).read_bytes())
                self.assertEqual((output / immutable).read_bytes(), (output / alias).read_bytes())
                self.assertEqual(files[alias]['sha256'], hashlib.sha256((output / alias).read_bytes()).hexdigest())
            self.assertFalse((output / 'binary/zsetup').exists())
            rules = output / 'binary/ddnsto/0.2.0/install-rules.json'
            self.assertTrue(rules.is_file(), 'missing auditable candidate rules')
            self.assertEqual(rules.read_bytes(), (ROOT / 'ddnsto/install-rules.json').read_bytes())
            self.assertIn('binary/ddnsto/0.2.0/install-rules.json', files)
            before = (output / 'entrypoints-manifest.json').read_bytes()
            repeated = subprocess.run(command, text=True, capture_output=True)
            self.assertNotEqual(repeated.returncode, 0)
            self.assertEqual((output / 'entrypoints-manifest.json').read_bytes(), before)


if __name__ == '__main__':
    unittest.main()
