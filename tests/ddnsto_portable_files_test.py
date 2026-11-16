"""Read-only metadata probes; no package installation or service changes."""
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PortableFiles(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='ddnsto-files-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.tools = self.root / 'tools'
        self.tools.mkdir()
        for tool in ('ls', 'uname', 'id', 'mkdir', 'rmdir', 'sh'):
            (self.tools / tool).symlink_to(shutil.which(tool))
        self.file = self.root / 'file'
        self.file.write_text('fixture')

    def run_probe(self, body, path=None):
        script = f'. "{ROOT / "ddnsto/portable-files.sh"}"\n' + body
        return subprocess.run(['/bin/sh', '-eu', '-c', script, 'probe', str(path or self.file)],
                              env=os.environ | {'PATH': str(self.tools)},
                              text=True, capture_output=True)

    def test_metadata_without_stat_matches_system(self):
        for mode in (0o600, 0o755, 0o1777, 0o4755, 0o2640):
            self.file.chmod(mode)
            result = self.run_probe('ddnsto_file_fields "$1"')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), f'{os.getuid()} {mode:o} 1')

    def test_darwin_stat_preserves_special_permission_bits(self):
        # BSD stat's L subfield excludes sticky/setuid/setgid bits. Model its
        # observed native formatting, not a canned successful probe response.
        (self.tools / 'uname').unlink()
        (self.tools / 'uname').write_text('#!/bin/sh\necho Darwin\n')
        (self.tools / 'uname').chmod(0o700)
        stat_tool = self.tools / 'stat'
        stat_tool.write_text(f'#!{sys.executable}\n' + '''import os, sys
s = os.lstat(sys.argv[3])
mode = s.st_mode & 0o7777
fmt = sys.argv[2]
if fmt == '%u %Lp %l':
    mode &= 0o777
elif fmt != '%u %Mp%Lp %l':
    sys.exit(2)
print(f'{s.st_uid} {mode:o} {s.st_nlink}')
''')
        stat_tool.chmod(0o700)
        for mode in (0o1777, 0o777, 0o755, 0o4755, 0o2640):
            with self.subTest(mode=oct(mode)):
                self.file.chmod(mode)
                result = self.run_probe('ddnsto_file_fields "$1"')
                self.assertEqual(result.returncode, 0, result.stderr)
                fields = result.stdout.split()
                self.assertEqual(int(fields[1], 8), mode)

    def test_hardlink_count_and_directory(self):
        os.link(self.file, self.root / 'hardlink')
        self.assertTrue(self.run_probe('ddnsto_file_fields "$1"').stdout.strip().endswith(' 2'))
        result = self.run_probe('ddnsto_file_fields "$1"', self.root)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_symlink_and_ambiguous_names_refused(self):
        link = self.root / 'link'
        link.symlink_to(self.file)
        for path in (link, self.root / 'with space', self.root / 'with\nnewline'):
            if path != link:
                path.write_text('fixture')
            self.assertNotEqual(self.run_probe('ddnsto_file_fields "$1"', path).returncode, 0)

    def test_writable_bootstrap_parent_rejected_without_stat(self):
        parent = self.root / 'unsafe'
        parent.mkdir(mode=0o777)
        parent.chmod(0o777)
        body = f'. "{ROOT / "ddnsto/bootstrap-policy.sh"}"\nddnsto_bootstrap_safe_ancestors "$1"'
        self.assertNotEqual(self.run_probe(body, parent).returncode, 0)

    def test_protected_bootstrap_parent_passes_without_stat(self):
        body = f'. "{ROOT / "ddnsto/bootstrap-policy.sh"}"\nddnsto_bootstrap_safe_ancestors "$1"'
        result = self.run_probe(body, self.root)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_malformed_or_acl_listing_is_refused(self):
        (self.tools / 'ls').unlink()
        listing = self.tools / 'ls'
        for value in ('drwxrwxrwt+ 2 0 0 4096 Nov 16 12:00 /tmp',
                      'drwxrwxrwt 2 stranger 0 4096 Nov 16 12:00 /tmp',
                      'drwxrwxrwt 2 0 0 4096 Nov 16 12:00 /tmp\njunk'):
            listing.write_text('#!/bin/sh\nprintf "%s\\n" ' + shlex.quote(value) + '\n')
            listing.chmod(0o700)
            self.assertNotEqual(self.run_probe('ddnsto_file_fields "$1"').returncode, 0)


if __name__ == '__main__':
    unittest.main()
