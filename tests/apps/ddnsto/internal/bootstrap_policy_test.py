#!/usr/bin/env python3
"""DDNSTO delegates zsetup selection to the shared latest-stable bootstrap."""

import json
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[4]
APP = ROOT / "apps/ddnsto"
SOURCE = ROOT / "sources/ddnsto"
VERSION = json.loads((APP / 'app.json').read_text())['version']


class SharedBootstrapContract(unittest.TestCase):
    def test_ddnsto_has_no_private_bootstrap_policy_or_exact_core_pin(self):
        self.assertFalse((APP / "source/bootstrap-policy.sh").exists())
        paths = [
            SOURCE / "templates/install-macos.sh.in",
            SOURCE / "templates/install.ps1.in",
            APP / f"versions/{VERSION}/install.sh",
        ]
        pattern = re.compile(r"zsetup(?:/|\s+)(?:0\.3\.0|0\.4\.0|0\.5\.0)")
        for path in paths:
            with self.subTest(path=path):
                self.assertIsNone(pattern.search(path.read_text()), path)

    def test_all_direct_entries_use_platform_stable_channels(self):
        shell = (APP / f"versions/{VERSION}/install.sh").read_text()
        windows = (APP / f"versions/{VERSION}/install.ps1").read_text(encoding="utf-8-sig")
        self.assertIn("bootstrap_zsetup_path", shell)
        self.assertNotIn("ddnsto_bootstrap_zsetup", shell)
        self.assertIn("ZSETUP_STABLE_PATH=zsetup/stable-macos", shell)
        self.assertIn("ZSETUP_STABLE_PATH=zsetup/stable", shell)
        self.assertIn("Get-ZsetupBootstrap", windows)
        self.assertIn("zsetup/stable-windows", windows)

    def test_declarative_policy_is_floor_plus_latest_channel(self):
        rules = json.loads((SOURCE / "install-rules.json").read_text())
        self.assertEqual(rules["zsetup_policy"]["selection"], "latest-platform-stable")
        self.assertFalse(rules["zsetup_policy"]["exact_version_pins"])
        self.assertEqual(rules["zsetup_policy"]["minimum_version"], "0.5.0")


if __name__ == "__main__":
    unittest.main()
