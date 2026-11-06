"""Adapter dispatch is exercised without network, host services or Docker."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ExtraPlatforms(unittest.TestCase):
    def run_adapter(self, body, *args):
        source = ROOT / 'ddnsto/extra-platforms.sh'
        self.assertTrue(source.is_file(), 'missing safe platform adapter')
        return subprocess.run(['sh', '-eu', '-c', '. "$1"; shift; ' + body, 'adapter', str(source), *args], capture_output=True, text=True)

    def test_synology_plan_never_bootstraps(self):
        result = self.run_adapter('PLAN_ONLY=1; ddnsto_bootstrap_zsetup() { echo BAD; return 99; }; ddnsto_synology_download() { echo PLAN; }; ddnsto_synology_entry')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'PLAN\n')

    def test_synology_uses_bounded_pinned_native_download(self):
        with tempfile.TemporaryDirectory() as tmp:
            native = Path(tmp) / 'native'
            native.write_text('#!/bin/sh\nprintf "<%s>" "$@"\n')
            native.chmod(0o755)
            result = self.run_adapter('''PLAN_ONLY=0; ZSETUP_INSTALLER_MODE=1; ZSETUP_BIN=$1
ZSETUP_SOURCE_BASES=https://fixture.invalid/binary; ZSETUP_SOURCE_FALLBACK=
ddnsto_synology_download() { ddnsto_download synology/4.2.8-7/file.spk "$2" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; }
ddnsto_synology_entry ignored "$2"
''', str(native), str(Path(tmp) / 'output'))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('<--max-bytes><33554432>', result.stdout)
            self.assertIn('<--min-free-bytes><8388608>', result.stdout)
            self.assertIn('<--sha256>', result.stdout)
            self.assertIn('https://fixture.invalid/binary/ddnsto/synology/4.2.8-7/file.spk', result.stdout)

    def test_synology_download_failure_is_returned(self):
        result = self.run_adapter('''PLAN_ONLY=0; ZSETUP_INSTALLER_MODE=0
ddnsto_bootstrap_zsetup() { return 11; }
ddnsto_synology_download() { echo UNEXPECTED; }
ddnsto_synology_entry
''')
        self.assertEqual(result.returncode, 11)
        self.assertNotIn('UNEXPECTED', result.stdout)

    def test_docker_mutation_requires_root_before_lock(self):
        result = self.run_adapter('id() { echo 1000; }; ddnsto_docker_lifecycle() { echo UNEXPECTED; }; ddnsto_docker_locked')
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertNotIn('UNEXPECTED', result.stdout)


if __name__ == '__main__':
    unittest.main()
