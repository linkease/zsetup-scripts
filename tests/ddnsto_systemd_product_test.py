"""System service product choice without service or package manager mutations."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SystemProduct(unittest.TestCase):
    def plan(self, available=100*1048576, old='', variant='standard', force='', env='production', mode='root'):
        with tempfile.TemporaryDirectory() as directory:
            prefix = Path(directory)
            if old:
                (prefix / '.managed').write_text('ddnsto\n')
            code = '''set -eu
. "$REPO/lib/install-storage.sh"
. "$REPO/lib/install-bounds.sh"
. "$REPO/sources/ddnsto/product-pins.sh"
. "$REPO/sources/ddnsto/linux-storage.sh"
if [ -f "$REPO/sources/ddnsto/linux-product.sh" ]; then . "$REPO/sources/ddnsto/linux-product.sh"; fi
probe() { echo "$AVAILABLE"; }
ZSETUP_BIN=probe
ddnsto_managed_owned() { SERVICE_OLD="versions/$OLD"; }
ddnsto_linux_current_variant() { echo "$OLD_VARIANT"; }
ddnsto_error() { echo "$*" >&2; }
ddnsto_linux_product_select "$MODE"
printf '%s %s %s\\n' "$LINUX_VARIANT" "$INSTALLER_REQUIRED_BYTES" "$INSTALLER_RESERVE"
'''
            return subprocess.run(['sh', '-c', code], capture_output=True, text=True,
                env=os.environ | dict(REPO=str(ROOT), AVAILABLE=str(available), OLD=old, OLD_VARIANT=variant,
                    FORCE_VERSION=force, BUSINESS_ENV=env, MODE=mode, arch='x86_64', HOME=directory,
                    INSTALLER_PREFIX=directory, business_platform='linux'))

    def test_fresh_small_space_uses_zig(self):
        r = self.plan(available=5*1048576)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.split()[0], 'zig')
        self.assertLess(int(r.stdout.split()[1]), 5*1048576)
        self.assertEqual(r.stdout.split()[2], '1048576')

    def test_normal_space_prefers_standard(self):
        r = self.plan()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.split()[0], 'standard')

    def test_sudo_budget_includes_extra_copy(self):
        root = self.plan(available=6*1048576)
        bridge = self.plan(available=6*1048576, mode='bridge')
        self.assertEqual(bridge.returncode, 0, bridge.stderr)
        self.assertEqual(bridge.stdout.split()[0], 'zig')
        self.assertGreater(int(bridge.stdout.split()[1]), int(root.stdout.split()[1]))

    def test_existing_standard_is_not_downgraded(self):
        r = self.plan(available=5*1048576, old='4.2.8')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('E_SPACE', r.stderr)

    def test_installed_zig_stays_zig(self):
        r = self.plan(old='4.2.1', variant='zig')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.split()[0], 'zig')

    def test_forced_standard_and_test_environment_do_not_fallback(self):
        for kwargs in ({'force': 'standard'}, {'env': 'test'}):
            r = self.plan(available=5*1048576, **kwargs)
            self.assertNotEqual(r.returncode, 0)
            self.assertIn('E_SPACE', r.stderr)

    def test_too_small_is_rejected(self):
        r = self.plan(available=1024)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('E_SPACE', r.stderr)

    def test_explicit_lite_selects_zig_and_cannot_switch_existing_standard(self):
        r = self.plan(force='lite')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.split()[0], 'zig')
        self.assertNotEqual(self.plan(old='4.2.8', force='lite').returncode, 0)


if __name__ == '__main__':
    unittest.main()
