"""Parse the actual entry with POSIX shells, without installing any service.

DDNSTO_TEST_LEGACY_SHELL is a maintainer-only interpreter command, e.g. a
network-disabled Bash 4.2 container. It is never read by the installer.
"""
import os
from pathlib import Path
import shlex
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ShellCompatibility(unittest.TestCase):
    def check_parser(self, command):
        for relative in ('lib/bootstrap.sh', 'apps/ddnsto/0.2.5/installer.sh'):
            with self.subTest(source=relative):
                result = subprocess.run(command + ['-n'], input=(ROOT / relative).read_text(),
                                        text=True, capture_output=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_host_sh_parser(self):
        self.check_parser(['sh'])

    def test_bash_posix_parser(self):
        self.check_parser(['bash', '--posix'])

    def legacy_shell(self):
        command = os.environ.get('DDNSTO_TEST_LEGACY_SHELL')
        if not command:
            self.skipTest('DDNSTO_TEST_LEGACY_SHELL required for actual legacy parser')
        return shlex.split(command)

    def test_legacy_parser(self):
        self.check_parser(self.legacy_shell())

    def test_legacy_entry_help(self):
        result = subprocess.run(self.legacy_shell() + ['-s', '--', '--help'],
                                input=(ROOT / 'apps/ddnsto/0.2.5/installer.sh').read_text(),
                                text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Usage: ddnsto-install.sh', result.stdout)


if __name__ == '__main__':
    unittest.main()
