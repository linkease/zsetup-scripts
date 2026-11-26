"""Temporary storage checks; no host services or package managers are executed."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class TemporaryStorage(unittest.TestCase):
    def run_shell(self, body, **env):
        source = 'set -eu\n' + ''.join(f'. "{ROOT / p}"\n' for p in (
            'lib/install-storage.sh', 'lib/install-bounds.sh', 'lib/install-package.sh',
            'lib/install-transaction.sh', 'sources/ddnsto/portable-files.sh',
            'sources/ddnsto/openwrt-adapter.sh'))
        source += '''
probe() {
    case "$4" in
        memory_backed) echo true ;;
        read_only) echo false ;;
        noexec) echo "${NOEXEC:-false}" ;;
        writable|private_directory) echo true ;;
        available_bytes) echo 100000000 ;;
        available_inodes) echo "${INODES:-100}" ;;
        system_protected) echo false ;;
        *) return 99 ;;
    esac
}
ZSETUP_BIN=probe
'''
        return subprocess.run(['sh', '-c', source + body], capture_output=True,
                              text=True, env=os.environ | env)

    def test_persistent_storage_still_refuses_tmpfs(self):
        self.assertEqual(self.run_shell('installer_storage_check /tmp 1 1 1').returncode, 12)

    def test_explicit_temporary_check_accepts_tmpfs(self):
        r = self.run_shell('installer_storage_check /tmp 1 1 1 temporary')
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_temporary_check_keeps_noexec_and_inode_checks(self):
        for env in ({'NOEXEC': 'true'}, {'INODES': '0'}):
            r = self.run_shell('installer_storage_check /tmp 1 1 1 temporary', **env)
            self.assertEqual(r.returncode, 12, r.stderr)

    def test_temporary_cache_lives_in_private_work_root(self):
        with tempfile.TemporaryDirectory(prefix='ddnsto-tmp-test-') as name:
            r = self.run_shell('''
OW_TMP_MODE=1
INSTALLER_WORK_ROOT="$TEST_ROOT"
INSTALLER_PREFIX=/must-not-write-here
transaction_dir="$TEST_ROOT/transaction"
mkdir "$transaction_dir"
package_manager=apk; PACKAGE_APP=ddnsto
installer_service_version() { :; }
installer_package_cache_location() { ddnsto_openwrt_cache_location; }
installer_package_cache_protected() { ddnsto_openwrt_cache_protected "$@"; }
installer_package_cache 4.2.8-lite aarch64
printf '%s\n' "$PACKAGE_CACHE"
''', TEST_ROOT=name)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(r.stdout.strip(), name + '/.packages/apk-4.2.8-lite-aarch64')
            self.assertTrue((Path(r.stdout.strip()) / '.owned').is_file())

    def test_temporary_cache_rejects_symlink(self):
        with tempfile.TemporaryDirectory(prefix='ddnsto-tmp-test-') as name:
            (Path(name) / '.packages').symlink_to('/tmp')
            r = self.run_shell('''
OW_TMP_MODE=1; INSTALLER_WORK_ROOT="$TEST_ROOT"
ddnsto_openwrt_cache_location
''', TEST_ROOT=name)
            self.assertNotEqual(r.returncode, 0)


if __name__ == '__main__':
    unittest.main()
