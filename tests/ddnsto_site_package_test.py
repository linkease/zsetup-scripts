"""Offline install-domain release layout; no product or network downloads."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SitePackageTest(unittest.TestCase):
    def test_independent_site_contains_aliases_guide_and_verified_payloads(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'site'
            args = [sys.executable, '-B', str(ROOT / 'scripts/package-ddnsto-site.py'),
                    '--output', str(output)]
            reviewed = [('shell', ROOT / 'apps/ddnsto/0.2.5/installer.sh'),
                        ('powershell', ROOT / 'sources/ddnsto/install.ps1')]
            for label, path in reviewed:
                args += ['--reviewed-' + label + '-sha256',
                         hashlib.sha256(path.read_bytes()).hexdigest()]
            result = subprocess.run(args, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            current = output / 'ddnsto-install/current'
            # A public static document root must remain readable after rsync -a
            # even when the HTTP service has a different uid than the builder.
            for directory in [output, current, current / 'immutable']:
                self.assertEqual(directory.stat().st_mode & 0o777, 0o755)
            for alias, entry in [('install.sh', 'recommended-entry.sh'), ('install.ps1', 'recommended-entry.ps1')]:
                self.assertEqual((output / alias).read_bytes(), (current / entry).read_bytes())
                self.assertIn('https://run.ddnsto.com/ddnsto-install/current',
                              (output / alias).read_text(encoding='utf-8-sig'))
            guide = output / 'ddnsto-install/agent/install.md'
            self.assertEqual(guide.stat().st_mode & 0o777, 0o644)
            self.assertEqual(guide.read_bytes(), (ROOT / 'sources/ddnsto/agent/install.md').read_bytes())
            self.assertNotIn('installer.invalid', guide.read_text())
            review = json.loads((current / 'review.json').read_text())
            self.assertFalse(review['published'])
            for record in review['installers'].values():
                body = (current / record['path']).read_bytes()
                self.assertEqual(hashlib.sha256(body).hexdigest(), record['sha256'])
            repeat = subprocess.run(args, capture_output=True, text=True)
            self.assertNotEqual(repeat.returncode, 0)
            self.assertEqual(guide.read_bytes(), (ROOT / 'sources/ddnsto/agent/install.md').read_bytes())


if __name__ == '__main__':
    unittest.main()
