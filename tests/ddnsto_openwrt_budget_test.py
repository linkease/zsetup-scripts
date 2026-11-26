"""Exercise the real OpenWrt planner without installing packages or services."""
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BudgetTests(unittest.TestCase):
    def plan(self, available=200 * 1048576, memory=2048, force='', arch='aarch64', manager='apk', tmp_memory='false', tmp_available=200 * 1048576, work=''):
        script = 'set -eu\n' + ''.join(f'. "{ROOT / p}"\n' for p in (
            'lib/install-storage.sh', 'sources/ddnsto/product-pins.sh',
            'sources/ddnsto/openwrt-adapter.sh')) + '''
probe() {
    case "$2:$4" in
        /:available_bytes) echo "$AVAILABLE" ;;
        /tmp:memory_backed) echo "$TMP_MEMORY" ;;
        /tmp:available_bytes) echo "$TMP_AVAILABLE" ;;
        *) return 99 ;;
    esac
}
ZSETUP_BIN=probe
status() { printf '%s\\n' "$*" >&2; }
ddnsto_error() { status "$@"; }
ddnsto_openwrt_plan
printf '%s %s %s %s\\n' "$SELECTED_VERSION" "$OW_DOWNLOAD_BYTES" "$OW_EXPANDED_BYTES" "$OW_REQUIRED_BYTES"
'''
        return subprocess.run(['sh', '-c', script], text=True, capture_output=True,
            env=os.environ | dict(AVAILABLE=str(available), DDNSTO_MEM_MB=str(memory),
                                  FORCE_VERSION=force, arch=arch, package_manager=manager,
                                  TMP_MEMORY=tmp_memory, TMP_AVAILABLE=str(tmp_available),
                                  installer_work_dir=work, ZSETUP_WORK_DIR=''))

    def test_tmpfs_separates_persistent_budget(self):
        result = self.plan(memory=256, tmp_memory='true', available=25 * 1048576)
        self.assertEqual(result.returncode, 0, result.stderr)
        _, _, expanded, budget = result.stdout.split()
        subtotal = int(expanded) + 4194304
        self.assertEqual(int(budget), subtotal + (subtotal + 9) // 10 + 8388608)
        self.assertIn('临时空间预算', result.stderr)

    def test_tmpfs_shortage_reports_tmp_before_installation(self):
        result = self.plan(tmp_memory='true', tmp_available=1)
        self.assertEqual(result.returncode, 12, result.stderr)
        self.assertIn('路径 /tmp', result.stderr)

    def test_low_tmp_space_also_selects_smaller_lite(self):
        lite_combined = int(self.plan(force='lite').stdout.split()[3])
        result = self.plan(tmp_memory='true', tmp_available=lite_combined)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.startswith('lite '), result.stdout)

    def test_explicit_work_directory_preserves_combined_budget(self):
        result = self.plan(tmp_memory='true', work='/custom/work')
        original = self.plan()
        self.assertEqual(result.stdout, original.stdout)

    def test_unknown_tmp_backing_keeps_persistent_plan(self):
        self.assertEqual(self.plan(tmp_memory='unknown').stdout, self.plan().stdout)

    def test_aarch64_apk_budget_comes_from_all_three_packages(self):
        result = self.plan()
        self.assertEqual(result.returncode, 0, result.stderr)
        variant, download, expanded, budget = result.stdout.split()
        self.assertEqual(variant, 'standard')
        self.assertEqual(int(download), 4434096 + 74883 + 1290)
        self.assertEqual(int(expanded), 11149312 + 344064 + 57344)
        subtotal = int(download) * 2 + int(expanded) + 4194304
        self.assertEqual(int(budget), subtotal + (subtotal + 9) // 10 + 8388608)
        self.assertLess(int(budget), 40 * 1048576)

    def test_low_space_selects_lite_even_on_high_memory_router(self):
        standard = self.plan()
        lite = self.plan(force='lite')
        self.assertEqual(standard.returncode, 0, standard.stderr)
        self.assertEqual(lite.returncode, 0, lite.stderr)
        threshold = int(lite.stdout.split()[3])
        self.assertLess(threshold, int(standard.stdout.split()[3]))
        result = self.plan(available=threshold)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.startswith('lite '), result.stdout)
        self.assertIn('空间', result.stderr)
        result = self.plan(available=threshold - 1)
        self.assertEqual(result.returncode, 12, result.stderr)
        self.assertIn('E_SPACE', result.stderr)

    def test_explicit_standard_is_not_silently_replaced(self):
        result = self.plan(available=1, force='standard')
        self.assertEqual(result.returncode, 12, result.stderr)
        self.assertIn('E_SPACE', result.stderr)

    def test_existing_memory_preference_is_preserved(self):
        result = self.plan(memory=256)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.startswith('lite '))

    def test_larger_lite_exception_is_not_used_as_space_fallback(self):
        standard = self.plan(arch='mipsel', force='standard')
        lite = self.plan(arch='mipsel', force='lite')
        self.assertEqual(standard.returncode, 0, standard.stderr)
        self.assertEqual(lite.returncode, 0, lite.stderr)
        self.assertGreater(int(lite.stdout.split()[3]), int(standard.stdout.split()[3]))
        result = self.plan(arch='mipsel', available=int(standard.stdout.split()[3]) - 1)
        self.assertEqual(result.returncode, 12, result.stderr)
        self.assertNotIn('正在检查 lite', result.stderr)

    def test_all_package_architectures_and_managers_have_budgets(self):
        for arch in ('x86_64', 'aarch64', 'armv7', 'mipsel'):
            for manager in ('apk', 'opkg'):
                for force in ('lite', 'standard'):
                    with self.subTest(arch=arch, manager=manager, force=force):
                        result = self.plan(arch=arch, manager=manager, force=force)
                        self.assertEqual(result.returncode, 0, result.stderr)

    def test_unknown_space_and_unsupported_arch_fail_closed(self):
        self.assertEqual(self.plan(available='unknown').returncode, 12)
        self.assertNotEqual(self.plan(arch='mips').returncode, 0)


if __name__ == '__main__':
    unittest.main()
