"""Old-running Linux ensure -> real native transaction -> final service state.

Disposable container ONLY (same explicit guard as managed lifecycle tests).
Archive/download and systemctl are fixtures; zsetup, extraction, version switch,
configuration protection, rollback and the ensure controller are real.
"""
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import unittest

import ddnsto_managed_lifecycle_test as f

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(f.ENABLED, 'requires explicitly marked disposable container')
class LinuxRunningUpgrade(unittest.TestCase):
    state = f.ManagedLifecycle.state
    assert_clean = f.ManagedLifecycle.assert_clean

    @classmethod
    def setUpClass(cls):
        digest = hashlib.sha256(Path(f.NATIVE).read_bytes()).hexdigest()
        if digest != '9563b8442a75957792bb82a2d98a736142fc52be57dd2dc42005490096897617':
            raise RuntimeError('requires reviewed 0.5.0 core')

    def setUp(self):
        f.ManagedLifecycle.setUp(self)
        (f.PREFIX / 'versions/4.2.8').rename(f.PREFIX / 'versions/4.2.7')
        for p in (f.PREFIX / 'versions/4.2.7/bin/.service-run', f.UNIT):
            p.write_text(p.read_text().replace('4.2.8', '4.2.7'))
        (f.PREFIX / 'current').unlink()
        (f.PREFIX / 'current').symlink_to('versions/4.2.7')
        self.state(active='active', enabled='enabled')
        manager = f.FIXTURE / 'bin/systemctl'
        manager.write_text(manager.read_text().replace(
            "wrapper = '/opt/linkease/ddnsto/versions/4.2.8/bin/.service-run'",
            "wrapper = str(Path('/opt/linkease/ddnsto/current/bin/.service-run').resolve())"))
        Path('/run/systemd/system').mkdir(parents=True, exist_ok=True)
        self.archive = f.FIXTURE / 'candidate.tar.gz'
        body = b'#!/bin/sh\n[ "$1" != -v ] || echo 4.2.8\nexit 0\n'
        with tarfile.open(self.archive, 'w:gz') as tar:
            member = tarfile.TarInfo('ddnsto-standard-4.2.8/ddnsto.x86_64')
            member.size = len(body)
            tar.addfile(member, io.BytesIO(body))
        self.digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()

    def invoke(self, download_fail=False):
        sources = ['lib/install-storage.sh', 'lib/install-bounds.sh', 'lib/install-transaction.sh',
                   'lib/install-service.sh', 'sources/ddnsto/product-pins.sh',
                   'sources/ddnsto/managed-cli.sh', 'sources/ddnsto/business.sh',
                   'sources/ddnsto/managed-service.sh', 'sources/ddnsto/auto-install.sh',
                   'sources/ddnsto/auto-linux.sh']
        script = 'set -eu\n' + ''.join(f'. "{ROOT / p}"\n' for p in sources) + r'''
ZSETUP_BIN=$ZSETUP_TEST_NATIVE
arch=x86_64; detected_platform=linux; ACTION=ensure
DDNSTO_ENSURE_ACTIVE=1; ENSURE_TOKEN=old; TOKEN=old
status() { :; }
ddnsto_linux_metadata() { version_num=4.2.8; archive_name=fixture.tar.gz; digest=$FIXTURE_DIGEST; }
ddnsto_download() { [ "$FAIL_DOWNLOAD" = 0 ] || return 11; cp "$FIXTURE_ARCHIVE" "$2"; }
# This inert product has no HTTP daemon. The real ensure stability check still
# runs against the simulated system manager, rather than claiming cloud health.
ddnsto_service_health() { ddnsto_ensure_linux_running; }
ddnsto_ensure_linux
'''
        return subprocess.run(['sh', '-c', script], capture_output=True, text=True, timeout=60,
            env=os.environ | {'PATH': f'{f.FIXTURE}/bin:/usr/bin:/bin',
                'ZSETUP_OS': 'linux', 'ZSETUP_ARCH': 'x86_64', 'ZSETUP_PACKAGE_MANAGER': 'apt',
                'ZSETUP_SOURCE_BASES': 'https://fixture.invalid', 'FIXTURE_ARCHIVE': str(self.archive),
                'FIXTURE_DIGEST': self.digest, 'FAIL_DOWNLOAD': str(int(download_fail))})

    def assert_running_version(self, version):
        self.assertEqual(os.readlink(f.PREFIX / 'current'), 'versions/' + version)
        self.assertEqual(f.CONFIG.read_bytes(), self.original)
        state = json.loads((f.FIXTURE / 'state.json').read_text())
        self.assertEqual((state['active'], state['enabled']), ('active', 'enabled'))
        self.assert_clean()

    def test_running_old_version_ensure_updates_and_preserves_identity(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_running_version('4.2.8')
        self.assertEqual(os.readlink(f.PREFIX / 'previous'), 'versions/4.2.7')
        calls = (f.FIXTURE / 'calls').read_text().splitlines()
        self.assertLess(calls.index('stop'), calls.index('start'))
        self.assertIn('4.2.8', (f.UNIT).read_text())

    def test_download_failure_keeps_old_version_running_without_stop(self):
        result = self.invoke(download_fail=True)
        self.assertEqual(result.returncode, 11, result.stderr)
        self.assert_running_version('4.2.7')
        self.assertNotIn('stop', (f.FIXTURE / 'calls').read_text().splitlines())

    def test_new_start_failure_restores_old_version_and_running_state(self):
        self.state(fail='start')
        result = self.invoke()
        self.assertEqual(result.returncode, 9, result.stderr)
        self.assertIn('start', (f.FIXTURE / 'calls').read_text().splitlines())
        self.assert_running_version('4.2.7')
        self.assertIn('4.2.7', f.UNIT.read_text())
        self.assertFalse((f.PREFIX / 'versions/4.2.8').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
