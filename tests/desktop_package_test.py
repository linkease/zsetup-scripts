#!/usr/bin/env python3
"""Candidate isolation/immutability only; does not replace canonical core checks."""
from pathlib import Path
import runpy
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
MODULE = runpy.run_path(str(ROOT / 'scripts/package-release.py'))


class DesktopPackage(unittest.TestCase):
    def test_opt_in_isolation_and_immutability(self):
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / 'binary'
            copy = MODULE['copy_desktop_candidates']
            copy(binary, False)
            self.assertFalse(binary.exists())
            copy(binary, True)
            for name in ('install.ps1', 'install-macos.sh'):
                path = binary / 'ddnsto/desktop-candidate-0.1.7' / name
                self.assertEqual(path.read_bytes(), (ROOT / 'ddnsto' / name).read_bytes())
                self.assertFalse((binary / 'ddnsto' / name).exists())
            copy(binary, True)
            path.write_text('different immutable bytes')
            with self.assertRaises(ValueError):
                copy(binary, True)
            self.assertEqual(path.read_text(), 'different immutable bytes')


if __name__ == '__main__':
    unittest.main()
