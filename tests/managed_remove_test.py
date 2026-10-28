"""The owner CLI removes verified client programs, preserving user material."""
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
NATIVE = sys.argv.pop(1)


class RemovalTests(unittest.TestCase):
    def setUp(self):
        (ROOT / 'dist').mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix='remove 中文 ', dir=ROOT / 'dist')
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.prefix = self.home / '.local/lib/linkease/linkspace'
        self.command = self.home / '.local/bin/linkspace'
        self.command.parent.mkdir(parents=True)
        self.payload = b'#!/bin/sh\nexit 0\n'
        for version in ('1.0.0', '1.0.1'):
            binary = self.prefix / 'versions' / version / 'bin/linkspace'
            binary.parent.mkdir(parents=True)
            binary.write_bytes(self.payload)
            binary.chmod(0o700)
            binary.with_suffix('.verified').write_text(hashlib.sha256(self.payload).hexdigest() + ':' + str(len(self.payload)) + '\n')
        (self.prefix / '.managed').write_text('linkspace\n')
        self.prefix.chmod(0o700)
        (self.prefix / 'current').symlink_to('versions/1.0.1/bin/linkspace')
        (self.prefix / 'previous').symlink_to('versions/1.0.0/bin/linkspace')
        self.command.symlink_to(self.prefix / 'current')
        self.keep = [self.home / 'project.txt', self.prefix / 'config.json', self.prefix / '.staging/download-cache']
        self.keep[-1].parent.mkdir(mode=0o700)
        for path in self.keep:
            path.write_text('keep')

    def call(self):
        return subprocess.run(['sh', str(ROOT / 'scripts/remove-managed.sh'), 'linkspace'],
                              env={**os.environ, 'HOME': str(self.home), 'ZSETUP_BIN': NATIVE},
                              capture_output=True, text=True, timeout=10)

    def test_remove_all_verified_versions_preserves_config_project_and_cache(self):
        result = self.call()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.command.is_symlink())
        self.assertFalse((self.prefix / 'versions').exists())
        self.assertFalse((self.prefix / '.managed').exists())
        self.assertFalse((self.prefix / 'current').is_symlink())
        self.assertFalse((self.prefix / 'previous').is_symlink())
        for path in self.keep:
            self.assertEqual(path.read_text(), 'keep')
        self.assertEqual(self.call().returncode, 0)

    def test_modified_program_is_preserved_even_with_same_size(self):
        binary = self.prefix / 'versions/1.0.1/bin/linkspace'
        binary.write_bytes(b'X' * len(self.payload))
        result = self.call()
        self.assertEqual(result.returncode, 11, result.stderr)
        self.assertEqual(binary.read_bytes(), b'X' * len(self.payload))
        self.assertTrue(self.command.is_symlink())
        self.assertTrue((self.prefix / 'versions/1.0.0/bin/linkspace').exists())
        self.assertFalse((self.prefix / '.staging/.install-lock').exists())

    def test_unknown_hidden_file_prevents_partial_removal(self):
        extra = self.prefix / 'versions/1.0.0/bin/.user-data'
        extra.write_text('keep')
        self.assertEqual(self.call().returncode, 11)
        self.assertEqual(extra.read_text(), 'keep')
        self.assertTrue((self.prefix / 'versions/1.0.1/bin/linkspace').exists())

    def test_foreign_command_and_held_install_lock_are_preserved(self):
        self.command.unlink(); self.command.symlink_to('/other/program')
        self.assertEqual(self.call().returncode, 11)
        self.assertEqual(os.readlink(self.command), '/other/program')
        self.command.unlink(); self.command.symlink_to(self.prefix / 'current')
        lock = self.prefix / '.staging/.install-lock'; lock.mkdir()
        (lock / 'owner').write_text('another-installer')
        self.assertEqual(self.call().returncode, 2)
        self.assertEqual((lock / 'owner').read_text(), 'another-installer')
        self.assertTrue(self.command.is_symlink())

    def test_symlink_version_cannot_escape_the_installation(self):
        outside = self.home / 'outside'; outside.mkdir(); (outside / 'keep').write_text('keep')
        (self.prefix / 'versions/1.0.2').symlink_to(outside, target_is_directory=True)
        self.assertEqual(self.call().returncode, 11)
        self.assertEqual((outside / 'keep').read_text(), 'keep')
        self.assertTrue(self.command.is_symlink())


if __name__ == '__main__':
    unittest.main()
