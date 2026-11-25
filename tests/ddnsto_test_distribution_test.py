"""Candidate distribution uses the standard entry and verified native index."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import build


class Distribution(unittest.TestCase):
    def test_complete_pipe_detaches_child_stdin(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            uname = root / 'uname'
            uname.write_text('#!/bin/sh\nif IFS= read -r data; then touch "$PROBE.consumed"; fi\ntouch "$PROBE"\nexit 42\n')
            uname.chmod(0o755)
            result = subprocess.run(['sh', '-s', '--', '--action', 'status'],
                input=(ROOT / 'apps/ddnsto/install.sh').read_text(), text=True,
                capture_output=True, env=os.environ | {'PATH': str(root) + ':' + os.environ['PATH'],
                    'PROBE': str(root / 'started')}, timeout=5)
            self.assertNotEqual(result.returncode, 0)  # Isolated unsupported uname.
            self.assertTrue((root / 'started').exists())
            self.assertFalse((root / 'started.consumed').exists())

    def test_truncated_pipe_does_not_start_bootstrap(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            uname = root / 'uname'
            uname.write_text('#!/bin/sh\ntouch "$PROBE"\nexit 42\n')
            uname.chmod(0o755)
            entry = (ROOT / 'apps/ddnsto/install.sh').read_text()
            # Truncate in the main body, before the complete entry is parsed.
            prefix = entry.split('\nconfig_dir=')[0]
            result = subprocess.run(['sh', '-s', '--'], input=prefix, text=True,
                capture_output=True, env=os.environ | {'PATH': str(root) + ':' + os.environ['PATH'],
                    'PROBE': str(root / 'started')}, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((root / 'started').exists(), 'partial entry executed')

    def test_test_distribution_preserves_payload_and_core_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'candidate'
            result = subprocess.run([sys.executable, '-B', str(ROOT / 'scripts/package-ddnsto-test.py'),
                '--output', str(output), '--base-url', 'https://fixture.invalid/candidate'],
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            entry = (output / 'ddnsto/install.sh').read_text()
            self.assertLess(len(entry.encode()), 131072)
            self.assertIn('https://fixture.invalid/candidate/zsetup/config.json', entry)
            self.assertIn('ddnsto_entry_main "$@" </dev/null', entry)
            config = json.loads((output / 'zsetup/config.json').read_text())
            original = json.loads((ROOT / 'apps/zsetup/config.json').read_text())
            self.assertEqual(config['stable_zsetup'], original['stable_zsetup'])
            for group in original['source_groups']:
                self.assertIn(group, config['source_groups'])
            index = json.loads((output / 'zsetup/ddnsto-index.json').read_text())
            for record in index['entries']:
                self.assertEqual(len(record['urls']), 1)
                self.assertNotIn(record.get('fallback_url'), record['urls'])
                self.assertTrue(record['urls'][0].startswith('https://fixture.invalid/candidate/ddnsto/versions/'))
                relative = record['urls'][0].split('/candidate/')[1]
                payload = (output / relative).read_bytes()
                self.assertEqual(payload, (ROOT / 'apps' / relative).read_bytes())
                self.assertEqual(record['sha256'], hashlib.sha256(payload).hexdigest())
            again = subprocess.run([sys.executable, str(ROOT / 'scripts/package-ddnsto-test.py'),
                '--output', str(output), '--base-url', 'https://fixture.invalid/candidate'], capture_output=True)
            self.assertNotEqual(again.returncode, 0)


if __name__ == '__main__':
    unittest.main()
