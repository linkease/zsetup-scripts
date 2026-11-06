"""Script-only integration: canonical entries, safe file execution and isolation."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class EntryIntegration(unittest.TestCase):
    def test_generator_preserves_other_apps_and_embeds_desktop_and_pins(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / 'scripts'
            shutil.copytree(ROOT, repo, ignore=shutil.ignore_patterns('.git', 'dist', '__pycache__'))
            catalog = json.loads((repo / 'catalog.json').read_text())
            paths = {r['script'] for r in catalog['installers'] if r['application'] != 'ddnsto'}
            before = {p: (repo / p).read_bytes() for p in paths}
            result = subprocess.run([sys.executable, '-B', str(repo / 'scripts/build-entrypoints.py')], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            entry = (repo / 'ddnsto/ddnsto-install.sh').read_text()
            self.assertIn('Darwin', entry)
            self.assertIn('ddnsto_bootstrap_zsetup', entry)
            self.assertIn('ddnsto_pinned_sha', entry)
            self.assertIn('installer_service_prepare', entry)
            self.assertFalse((repo / 'ddnsto/install.sh').exists(), 'only one canonical source entry')
            for path, data in before.items():
                self.assertEqual((repo / path).read_bytes(), data, path)
            check = subprocess.run([sys.executable, '-B', str(repo / 'scripts/build-entrypoints.py'), '--check'], capture_output=True, text=True)
            self.assertEqual(check.returncode, 0, check.stderr)

    def test_canary_executes_verified_file_not_shell_argument(self):
        script = (ROOT / 'ddnsto/tests/github_linux_canary.sh').read_text()
        self.assertNotIn('sh -c "$entry"', script)
        self.assertIn('sh /tmp/github-entry.sh', script)


if __name__ == '__main__':
    unittest.main()
