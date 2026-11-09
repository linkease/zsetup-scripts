"""Real native + isolated filesystem, fake systemd; disposable container ONLY."""
import json
import os
from pathlib import Path
import subprocess
import unittest

import ddnsto_managed_lifecycle_test as fixture

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(fixture.ENABLED, 'requires explicitly marked disposable container')
class AutoLinux(unittest.TestCase):
    setUp = fixture.ManagedLifecycle.setUp
    state = fixture.ManagedLifecycle.state
    assert_clean = fixture.ManagedLifecycle.assert_clean

    def invoke(self, token='old'):
        Path('/run/systemd/system').mkdir(parents=True, exist_ok=True)
        sources = ['lib/install-storage.sh', 'lib/install-bounds.sh', 'lib/install-transaction.sh',
                   'lib/install-service.sh', 'ddnsto/product-pins.sh', 'ddnsto/business.sh',
                   'ddnsto/managed-service.sh', 'ddnsto/auto-install.sh', 'ddnsto/auto-linux.sh']
        script = 'set -eu\n' + ''.join(f'. "{ROOT / p}"\n' for p in sources)
        script += '''
ZSETUP_BIN=$DDNSTO_TEST_NATIVE; detected_platform=linux; ACTION=ensure
DDNSTO_ENSURE_ACTIVE=1; ENSURE_TOKEN=$1; TOKEN=$1; arch=x86_64
status() { :; }
ddnsto_service_health() { ddnsto_ensure_linux_running; }
# A same/newer version must not invoke any product installer.
ddnsto_install() { printf 'UNEXPECTED_INSTALL'; return 99; }
ddnsto_ensure_linux
'''
        return subprocess.run(['sh', '-c', script, 'test', token], text=True, capture_output=True,
                              timeout=45, env=os.environ | {'PATH': f'{fixture.FIXTURE}/bin:/usr/bin:/bin'})

    def test_existing_same_account_enables_and_starts_preserving_identity(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('UNEXPECTED_INSTALL', result.stdout)
        self.assertEqual(fixture.CONFIG.read_bytes(), self.original)
        state = json.loads((fixture.FIXTURE / 'state.json').read_text())
        self.assertEqual((state['active'], state['enabled']), ('active', 'enabled'))
        self.assert_clean()

    def test_other_account_fails_before_service_mutation(self):
        result = self.invoke('different-account')
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn('E_ACCOUNT', result.stderr)
        self.assertEqual((fixture.FIXTURE / 'calls').read_text(), '')
        self.assertEqual(fixture.CONFIG.read_bytes(), self.original)

    def test_unsafe_unknown_configuration_is_not_replaced(self):
        fixture.CONFIG.write_text('{}')
        result = self.invoke()
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(fixture.CONFIG.read_text(), '{}')
        self.assertEqual((fixture.FIXTURE / 'calls').read_text(), '')

    def test_newer_version_is_kept(self):
        prefix = fixture.PREFIX
        (prefix / 'versions/4.2.8').rename(prefix / 'versions/4.2.9')
        for path in [prefix / 'versions/4.2.9/bin/.service-run', fixture.UNIT]:
            path.write_text(path.read_text().replace('4.2.8', '4.2.9'))
        (prefix / 'current').unlink()
        (prefix / 'current').symlink_to('versions/4.2.9')
        wrapper = prefix / 'versions/4.2.9/bin/.service-run'
        self.state(properties={'ExecStart': '{ path=/bin/sh ; argv[]=/bin/sh ' + str(wrapper) + ' ; ignore_errors=no ; pid=0 ; }'})
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(os.readlink(prefix / 'current'), 'versions/4.2.9')
        self.assertNotIn('UNEXPECTED_INSTALL', result.stdout)


if __name__ == '__main__':
    unittest.main()
