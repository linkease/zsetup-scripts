"""Storage policy tests; no real packages, services, sudo or host paths."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class StoragePolicy(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="install-storage-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.native = self.root / "zsetup"
        self.native.write_text('''#!/bin/sh
[ "$1" = storage ] || exit 2
case "$4" in
 memory_backed) if [ "$2" = "${FACT_REJECT_PATH:-}" ]; then echo true; else printf '%s\\n' "${FACT_MEMORY:-false}"; fi ;;
 available_bytes) printf '%s\\n' "${FACT_BYTES:-100000000}" ;;
 available_inodes) printf '%s\\n' "${FACT_INODES:-10000}" ;;
 read_only) printf '%s\\n' "${FACT_READONLY:-false}" ;;
 noexec) printf '%s\\n' "${FACT_NOEXEC:-false}" ;;
 writable) printf '%s\\n' "${FACT_WRITABLE:-true}" ;;
 *) exit 2 ;;
esac
''')
        self.native.chmod(0o755)

    def call(self, code, *args, **env):
        return subprocess.run(
            ["sh", "-eu", "-c", '. "$1"; shift; ' + code, "test", str(ROOT / "lib/install-storage.sh"), *map(str, args)],
            env={**os.environ, "ZSETUP_BIN": str(self.native), "HOME": str(self.root / "home"), **env},
            capture_output=True, text=True,
        )

    def test_accept_disk_but_refuse_memory_unknown_low_space_and_restrictions(self):
        self.assertEqual(self.call('installer_storage_check "$1" 1000 1 1', self.root).returncode, 0)
        for fact in [dict(FACT_MEMORY="true"), dict(FACT_MEMORY="unknown"), dict(FACT_BYTES="999"), dict(FACT_READONLY="true"), dict(FACT_NOEXEC="true"), dict(FACT_WRITABLE="false"), dict(FACT_INODES="0")]:
            with self.subTest(fact=fact):
                result = self.call('installer_storage_check "$1" 1000 1 1', self.root, **fact)
                self.assertEqual(result.returncode, 12, result)
                self.assertFalse(any(self.root.glob(".transaction*")))

    def test_budget_is_peak_extra_bytes_plus_margin_and_rejects_unknown(self):
        result = self.call('installer_space_budget 1000 2000 2000 500; printf "%s\\n" "$INSTALLER_REQUIRED_BYTES"')
        self.assertEqual(result.returncode, 0, result)
        self.assertGreater(int(result.stdout), 5500)
        for bad in ["unknown", "-1", "1;touch bad", "999999999999999999999"]:
            result = self.call('installer_space_budget "$1" 0 0 0', bad)
            self.assertEqual(result.returncode, 2, result)

    def test_user_layout_and_explicit_prefix_preserve_literal_paths(self):
        result = self.call('installer_layout ddnsto user; printf "%s\\n%s\\n" "$INSTALLER_PREFIX" "$INSTALLER_COMMAND"')
        self.assertEqual(result.returncode, 0, result)
        self.assertEqual(result.stdout.splitlines(), [str(self.root / "home/.local/lib/linkease/ddnsto"), str(self.root / "home/.local/bin/ddnsto")])
        path = self.root / "中文 space $literal"
        result = self.call('installer_prefix=$1; installer_layout ddnsto user; printf "%s" "$INSTALLER_PREFIX"', path)
        self.assertEqual(result.stdout, str(path))
        self.assertFalse(path.exists())

    def test_bad_prefix_and_scope_are_rejected_without_mutation(self):
        for prefix in ["/", "relative", "/opt/../usr/bin", "/opt/./a", "/opt//a"]:
            result = self.call('installer_prefix=$1; installer_layout ddnsto user', prefix)
            self.assertEqual(result.returncode, 2, result)
        result = self.call('installer_scope=invalid; installer_layout ddnsto user')
        self.assertEqual(result.returncode, 2, result)

    def test_unattended_selection_fails_without_prompt_or_mutation(self):
        result = self.call('installer_storage_select "$1" 1000 1 1', self.root, FACT_MEMORY="true")
        self.assertEqual(result.returncode, 12, result)
        self.assertNotIn("Enter", result.stderr)

    def test_separate_staging_filesystem_is_checked_and_plan_creates_nothing(self):
        chosen = self.root / "chosen"
        work = self.root / "work"
        code = 'installer_prefix=$1; installer_work_dir=$2; installer_preflight ddnsto user 1000 1'
        result = self.call(code, chosen, work, FACT_REJECT_PATH=str(work))
        self.assertEqual(result.returncode, 12, result)
        self.assertFalse(chosen.exists())
        self.assertFalse(work.exists())
        result = self.call(code, chosen, work)
        self.assertEqual(result.returncode, 0, result)
        self.assertIn("Install plan:", result.stderr)
        self.assertFalse(chosen.exists())

    def test_interactive_selection_can_choose_literal_persistent_path(self):
        import pty
        master, slave = pty.openpty()
        chosen = self.root / "中文 new target"
        try:
            process = subprocess.Popen(
                ["sh", "-eu", "-c", '. "$1"; installer_storage_select "$2" 1000 1 1; printf "%s" "$INSTALLER_STORAGE_PATH"', "test", str(ROOT / "lib/install-storage.sh"), str(self.root)],
                stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                env={**os.environ, "ZSETUP_BIN": str(self.native), "FACT_REJECT_PATH": str(self.root)},
            )
            os.write(master, (str(chosen) + "\n").encode())
            out, err = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 0, err)
            self.assertEqual(out.decode(), str(chosen))
            self.assertFalse(chosen.exists())
        finally:
            os.close(master)
            os.close(slave)


if __name__ == "__main__":
    unittest.main()
