"""Replay router storage facts through real package preflight and flow reporting.

No package execution, host-path writes or native runtime modifications.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class OpenWrtStorage(unittest.TestCase):
    def invoke(self, available="173434470", memory="false", inodes="10000", protected="true"):
        with tempfile.TemporaryDirectory(prefix="ddnsto-storage-") as temp:
            root = Path(temp)
            script = 'set -eu\n' + ''.join(f'. "{ROOT / p}"\n' for p in (
                'lib/install-storage.sh', 'lib/install-bounds.sh', 'lib/install-package.sh',
                'sources/ddnsto/auto-install.sh', 'sources/ddnsto/openwrt-adapter.sh'))
            script += '''
probe() {
    [ "$1" = storage ] || return 99
    case "$4" in
        memory_backed) printf '%s\\n' "$FACT_MEMORY" ;;
        read_only|noexec) printf 'false\\n' ;;
        writable) printf 'true\\n' ;;
        available_bytes) printf '%s\\n' "$FACT_BYTES" ;;
        available_inodes) printf '%s\\n' "$FACT_INODES" ;;
        system_protected) printf '%s\\n' "$FACT_PROTECTED" ;;
        *) return 99 ;;
    esac
}
ZSETUP_BIN=probe; package_manager=apk
installer_prefix="$TMPDIR/prefix"
installer_require_root() { :; }
# Stop at the real transaction boundary: no global locks or package operations.
installer_transaction_begin() { printf 'reached-transaction\\n' > "$TMPDIR/reached"; return 77; }
ddnsto_ensure_preflight() { :; }
ddnsto_ensure_execute() {
    ddnsto_flow_note installing
    if command -v ddnsto_openwrt_prepare >/dev/null 2>&1; then
        ddnsto_openwrt_prepare
    else
        installer_package_prepare ddnsto
    fi
}
TOKEN=must-not-appear
ddnsto_ensure_entry
'''
            result = subprocess.run(['sh', '-c', script], text=True, capture_output=True, timeout=10,
                env=os.environ | dict(TMPDIR=temp, FACT_BYTES=available, FACT_MEMORY=memory,
                                      FACT_INODES=inodes, FACT_PROTECTED=protected))
            logs = '\n'.join(p.read_text() for p in root.glob('ddnsto-result.*/events.log'))
            return result, (root / 'reached').exists(), (root / 'prefix').exists(), logs

    def test_router_with_165_mib_reaches_transaction(self):
        result, reached, _, _ = self.invoke()
        self.assertTrue(reached, result.stderr)
        self.assertEqual(result.returncode, 77)

    def test_low_space_reports_required_available_path_without_secrets(self):
        result, reached, prefix, log = self.invoke(available="16777216")
        self.assertEqual(result.returncode, 12)
        self.assertFalse(reached or prefix)
        self.assertIn('E_SPACE', result.stderr)
        self.assertIn('16777216', result.stderr)
        self.assertIn('156028109', result.stderr)
        self.assertIn('路径 /', result.stderr)
        self.assertIn('error=E_SPACE', log)
        self.assertNotIn('must-not-appear', result.stdout + result.stderr + log)
        self.assertNotIn('恢复已由平台执行器尝试', result.stderr)

    def test_unknown_backing_and_zero_inodes_still_fail_with_reason(self):
        for kwargs in (dict(memory='unknown'), dict(memory='true'), dict(inodes='0')):
            with self.subTest(kwargs=kwargs):
                result, reached, prefix, log = self.invoke(**kwargs)
                self.assertEqual(result.returncode, 12)
                self.assertFalse(reached or prefix)
                self.assertIn('E_STORAGE', result.stderr)
                self.assertIn('error=E_STORAGE', log)

    def test_unsafe_cache_has_actionable_reason(self):
        result, reached, _, log = self.invoke(protected='false')
        self.assertEqual(result.returncode, 12)
        self.assertFalse(reached)
        self.assertIn('E_STORAGE', result.stderr)
        self.assertIn('error=E_STORAGE', log)

    def test_shared_non_openwrt_policy_unchanged(self):
        script = f'. "{ROOT}/lib/install-storage.sh"; . "{ROOT}/lib/install-bounds.sh"; installer_policy ddnsto; echo "$INSTALLER_REQUIRED_BYTES"'
        result = subprocess.run(['sh', '-eu', '-c', script], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), '192937984')


if __name__ == '__main__':
    unittest.main()
