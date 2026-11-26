"""System service and sudo preparation budgets without host mutations."""
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SystemdBudget(unittest.TestCase):
    def policy(self, arch='x86_64', platform='linux', version='', app='ddnsto', bridge=False):
        script = '''set -eu
. "$REPO/lib/install-storage.sh"
. "$REPO/lib/install-bounds.sh"
. "$REPO/sources/ddnsto/product-pins.sh"
if [ -f "$REPO/sources/ddnsto/linux-storage.sh" ]; then . "$REPO/sources/ddnsto/linux-storage.sh"; fi
installer_policy "$APP"
if [ "$BRIDGE" = 1 ]; then
 installer_space_budget "$INSTALLER_MAX_DOWNLOAD" "$INSTALLER_MAX_EXPANDED" "$INSTALLER_MAX_EXPANDED" "$INSTALLER_MAX_DOWNLOAD"
fi
printf '%s %s %s\n' "$INSTALLER_MAX_DOWNLOAD" "$INSTALLER_MAX_EXPANDED" "$INSTALLER_REQUIRED_BYTES"
'''
        return subprocess.run(['sh', '-c', script], capture_output=True, text=True,
            env=os.environ | dict(REPO=str(ROOT), arch=arch, business_platform=platform,
                                  DDNSTO_VERSION=version, APP=app, BRIDGE=str(int(bridge))))

    def test_root_budget_uses_archive_and_two_installed_copies(self):
        r = self.policy()
        self.assertEqual(r.returncode, 0, r.stderr)
        download, expanded, required = map(int, r.stdout.split())
        self.assertEqual(download, 16757733)
        self.assertGreater(expanded, 4547748)  # Wrapper, config and metadata headroom.
        subtotal = download + 2 * expanded
        self.assertEqual(required, subtotal + (subtotal + 9) // 10 + 8388608)
        self.assertLess(required, 40 * 1048576)

    def test_arm_budget_uses_its_actual_binary(self):
        r = self.policy(arch='aarch64')
        self.assertEqual(r.returncode, 0, r.stderr)
        download, expanded, required = map(int, r.stdout.split())
        self.assertEqual(download, 16757733)
        self.assertGreater(expanded, 11075768)
        self.assertLess(required, 55 * 1048576)

    def test_sudo_counts_cross_uid_archive_copy(self):
        r = self.policy(bridge=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        download, expanded, required = map(int, r.stdout.split())
        subtotal = 2 * (download + expanded)
        self.assertEqual(required, subtotal + (subtotal + 9) // 10 + 8388608)
        self.assertLess(required, 60 * 1048576)

    def test_unreviewed_historical_version_keeps_existing_ceiling(self):
        self.assertEqual(self.policy(version='4.2.7').stdout.split()[2], '192937984')

    def test_other_platforms_and_apps_keep_their_policy(self):
        self.assertEqual(self.policy(platform='openwrt').stdout.split()[2], '192937984')
        self.assertEqual(self.policy(app='linkease').stdout.split()[0], '134217728')

    def test_unsupported_arch_is_not_guessed(self):
        r = self.policy(arch='mips')
        self.assertNotEqual(r.returncode, 0)


if __name__ == '__main__':
    unittest.main()
