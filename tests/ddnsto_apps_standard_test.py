#!/usr/bin/env python3
"""DDNSTO exposes one standard application interface in the literal apps tree."""

import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "apps/ddnsto"


class AppsStandardTest(unittest.TestCase):
    def test_ddnsto_root_is_the_complete_standard_interface(self):
        self.assertEqual(
            {path.name for path in APP.iterdir()},
            {"app.json", "install.sh", "install.ps1", "install.md", "versions"},
        )
        self.assertFalse((ROOT / "apps/_sites").exists())
        for name in ("i", "i.ps1", "ddnsto-install.sh", "ddnsto-install", "current", "agent"):
            self.assertFalse((APP / name).exists(), name)

    def test_three_public_entries_have_one_application_owner(self):
        guide = (APP / "install.md").read_text(encoding="utf-8")
        self.assertIn("https://run.ddnsto.com/install.sh", guide)
        self.assertIn("https://run.ddnsto.com/install.ps1", guide)
        self.assertIn("https://run.ddnsto.com/install.md", guide)
        self.assertNotIn("/ddnsto-install/", guide)
        self.assertNotIn("install.ddnsto.com", guide)

    def test_public_checker_rejects_accidental_source_upload(self):
        with tempfile.TemporaryDirectory() as directory:
            apps = Path(directory) / "apps"
            (apps / "ddnsto/source").mkdir(parents=True)
            (apps / "ddnsto/source/template.in").write_text("not for publication")
            result = subprocess.run(
                [sys.executable, "-B", str(ROOT / "scripts/check-public-tree.py"), str(apps)],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)

    def test_build_checks_entries_and_requires_maintained_guide(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("apps", "scripts", "lib", "templates", "sources"):
                shutil.copytree(
                    ROOT / name,
                    root / name,
                    ignore=shutil.ignore_patterns("__pycache__"),
                )
            command = [sys.executable, "-B", str(root / "scripts/build.py")]

            def run(*flags):
                return subprocess.run(command + list(flags), capture_output=True, text=True)

            self.assertEqual(run("--check").returncode, 0)
            entry = root / "apps/ddnsto/install.ps1"
            entry.unlink()
            self.assertNotEqual(run("--check").returncode, 0)
            self.assertEqual(run().returncode, 0)
            self.assertEqual(run("--check").returncode, 0)
            guide = root / "apps/ddnsto/install.md"
            guide.unlink()
            self.assertNotEqual(run("--check").returncode, 0)
            self.assertNotEqual(run().returncode, 0)
            self.assertFalse(guide.exists(), "build must not synthesize application guidance")

    def test_publication_treats_guide_as_mutable_and_versions_as_immutable(self):
        spec = importlib.util.spec_from_file_location(
            "publish_apps", ROOT / "scripts/publish-apps.py"
        )
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertTrue(module.is_immutable("ddnsto/versions/0.3.0/install.sh"))
        self.assertTrue(module.is_immutable("ddnsto/versions/0.3.0/install.ps1"))
        for relative in ("ddnsto/install.sh", "ddnsto/install.ps1", "ddnsto/install.md"):
            self.assertFalse(module.is_immutable(relative))

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            apps = root / "apps"
            shutil.copytree(ROOT / "apps", apps)
            live = root / "live"
            live.mkdir()
            environment = dict(os.environ, ZSETUP_PUBLISH_ALLOW_UNVERSIONED="1")

            def publish(action):
                result = subprocess.run(
                    ["sh", str(ROOT / "scripts/publish.sh"), action, str(apps), str(live)],
                    env=environment,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)

            publish("stage")
            immutable = live / "ddnsto/versions/0.3.0/install.sh"
            self.assertEqual(immutable.read_bytes(), (APP / "versions/0.3.0/install.sh").read_bytes())
            self.assertFalse((live / "ddnsto/install.md").exists())
            publish("activate")
            self.assertEqual((live / "ddnsto/install.md").read_bytes(), (APP / "install.md").read_bytes())
            publish("verify")
            publish("rollback")
            self.assertTrue(immutable.is_file())
            self.assertFalse((live / "ddnsto/install.md").exists())


if __name__ == "__main__":
    unittest.main()
