"""Managed DDNSTO actions accept the verified current zsetup above their floor."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class ManagedNativeFloor(unittest.TestCase):
    def invoke(self, version):
        with tempfile.TemporaryDirectory(prefix="ddnsto-native-floor-") as name:
            binary = Path(name) / "zsetup"
            binary.write_text(f"#!/bin/sh\nprintf 'zsetup {version}\\n'\n")
            binary.chmod(0o700)
            script = f'''
. "{ROOT / "apps/ddnsto/source/managed-service.sh"}"
ddnsto_error() {{ printf '%s\\n' "$*" >&2; }}
ZSETUP_BIN="$1"
ddnsto_managed_native
'''
            return subprocess.run(
                ["sh", "-eu", "-c", script, "test", str(binary)],
                env=dict(os.environ), capture_output=True, text=True,
            )

    def test_minimum_and_newer_versions_are_accepted(self):
        for version in ("0.5.0", "0.6.5", "1.0.0"):
            with self.subTest(version=version):
                result = self.invoke(version)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_older_or_invalid_versions_are_rejected(self):
        for version in ("0.4.9", "0.5", "0.5.0.1", "1x.0.0", "invalid"):
            with self.subTest(version=version):
                result = self.invoke(version)
                self.assertEqual(result.returncode, 2, result.stderr)


if __name__ == "__main__":
    unittest.main()
