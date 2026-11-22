import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[4] / 'apps/ddnsto/source'
SCRIPT = r'''
set -eu
. "$SOURCE/business.sh"
[ ! -f "$SOURCE/method-selection.sh" ] || . "$SOURCE/method-selection.sh"
ddnsto_docker_discover() { [ "$AVAILABLE" = 1 ]; }
ddnsto_choose_method() { printf '%s' "$CHOICE"; }
ddnsto_method_interactive() { return 0; }
REQUESTED_METHOD=auto ACTION=install detected_platform=linux
ddnsto_offer_install_method
printf 'METHOD=%s\n' "$REQUESTED_METHOD"
'''


class MethodSelection(unittest.TestCase):
    def test_native_write_rechecks_docker_conflict_inside_transaction(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'docker').mkdir()
            script = r'''
set -eu
. "$SOURCE/business.sh"
. "$SOURCE/managed-cli.sh"
ddnsto_detect_platform() { detected_platform=linux; }
ddnsto_validate_platform_options() { :; }
ddnsto_business_environment_preflight() { :; }
ddnsto_linux() { echo UNEXPECTED_NATIVE; }
ddnsto_install --action install --token fixture-token
'''
            r = subprocess.run(['sh', '-c', script], text=True, capture_output=True,
                env=dict(os.environ, SOURCE=str(ROOT), DDNSTO_DOCKER_STATE_DIR=str(root / 'docker'),
                    ZSETUP_BIN='/bin/false', ZSETUP_OS='linux', ZSETUP_PACKAGE_MANAGER='unknown',
                    ZSETUP_ARCH='x86_64', ZSETUP_SOURCE_BASES='https://fixture.invalid'))
            self.assertEqual(r.returncode, 2, r.stderr)
            self.assertNotIn('UNEXPECTED_NATIVE', r.stdout)

    def invoke(self, choice='native', available='1', existing=False, retained=False):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            if existing: (root / 'native').touch()
            if retained: (root / 'docker').mkdir()
            return subprocess.run(['sh', '-c', SCRIPT], text=True, capture_output=True,
                env=dict(os.environ, SOURCE=str(ROOT), CHOICE=choice, AVAILABLE=available,
                    DDNSTO_BIN_PATH=str(root / 'native'), DDNSTO_LINUX_CONFIG_DIR=str(root / 'config'),
                    DDNSTO_DOCKER_STATE_DIR=str(root / 'docker')))

    def test_explicit_interactive_choice_selects_docker(self):
        r = self.invoke('docker')
        self.assertEqual((r.returncode, r.stdout), (0, 'METHOD=docker\n'), r.stderr)

    def test_default_or_unavailable_keeps_native(self):
        for choice, available in [('native', '1'), ('docker', '0')]:
            r = self.invoke(choice, available)
            self.assertEqual((r.returncode, r.stdout), (0, 'METHOD=auto\n'), r.stderr)

    def test_native_existing_is_not_migrated(self):
        r = self.invoke('docker', existing=True)
        self.assertEqual((r.returncode, r.stdout), (0, 'METHOD=auto\n'), r.stderr)

    def test_retained_docker_requires_explicit_method(self):
        r = self.invoke(retained=True)
        self.assertEqual(r.returncode, 2, r.stderr)


if __name__ == '__main__': unittest.main()
