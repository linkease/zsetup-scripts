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
            self.assertIn('copy_desktop_candidates', MODULE)
            copy = MODULE['copy_desktop_candidates']
            copy(binary, False)
            self.assertFalse(binary.exists())
            copy(binary, True)
            for name in ('install.ps1', 'install-macos.sh'):
                path = binary / 'ddnsto/desktop-candidate-0.2.4' / name
                source = (ROOT / 'apps/ddnsto/source/install.ps1' if name == 'install.ps1'
                          else ROOT / 'apps/ddnsto/0.2.4/installer.sh')
                self.assertEqual(path.read_bytes(), source.read_bytes())
                self.assertFalse((binary / 'ddnsto' / name).exists())
            copy(binary, True)
            path.write_text('different immutable bytes')
            with self.assertRaises(ValueError):
                copy(binary, True)
            self.assertEqual(path.read_text(), 'different immutable bytes')


if __name__ == '__main__':
    unittest.main()
