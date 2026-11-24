#!/usr/bin/env python3
"""Shared POSIX bootstrap remains available in every DDNSTO shell path."""

from pathlib import Path
import json
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[4]


class SharedBootstrapEmbedding(unittest.TestCase):
    def test_shared_bootstrap_supports_curl_wget_and_platform_stable(self):
        bootstrap = (ROOT / "lib/bootstrap.sh").read_text()
        for token in ("type curl", "type wget", "zsetup/stable-macos", "zsetup/stable"):
            self.assertIn(token, bootstrap)

    def test_generated_ddnsto_installer_is_valid_posix_shell(self):
        version = json.loads((ROOT / 'apps/ddnsto/app.json').read_text())['version']
        installer = ROOT / f"apps/ddnsto/versions/{version}/install.sh"
        result = subprocess.run(["sh", "-n", str(installer)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        text = installer.read_text()
        self.assertIn((ROOT / "lib/bootstrap.sh").read_text().rstrip(), text)
        self.assertNotIn("ddnsto_bootstrap_zsetup", text)


if __name__ == "__main__":
    unittest.main()
