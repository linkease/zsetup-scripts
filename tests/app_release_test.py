"""Single-app release plans preserve unrelated live records and never publish."""
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
ZROOT = Path(sys.argv.pop(1)).resolve()
NATIVE = Path(sys.argv.pop(1)).resolve()
ENTRY = ROOT / "scripts/package-app-release.py"
BASES = ["https://dl.istoreos.com/binary", "https://fw.d4ctech.com/binary", "https://fw20.koolcenter.com/binary"]


class AppRelease(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="fastnet-release-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.config = {
            "schema_version": 1, "config_version": "live-existing",
            "source_groups": [{"id": "koolcenter", "primary_bases": BASES,
                               "fallback_base": "https://fw.koolcenter.com/binary"}],
            "stable_zsetup": {"version": "0.5.0", "source_group": "koolcenter", "artifacts": [
                {"arch": "x86_64", "path": "zsetup/0.5.0/zsetup-linux-x86_64", "sha256": "00" * 32, "size": 1}]},
            "installers": [self.record("fastnet"), self.record("ddnsto")],
        }
        self.input = self.root / "live-config.json"
        self.output = self.root / "review"
        self.marker = self.root / "network-attempt"
        tools = self.root / "tools"; tools.mkdir()
        for name in ("ssh", "scp", "curl", "wget"):
            tool = tools / name
            tool.write_text("#!/bin/sh\ntouch '" + str(self.marker) + "'\nexit 91\n")
            tool.chmod(0o755)
        self.env = os.environ | {"PATH": str(tools) + ":" + os.environ["PATH"]}

    def record(self, app):
        return {"application": app, "os": "*", "package_manager": "*", "arch": "*",
                "source_group": "koolcenter", "path": app + "/old/install.sh", "sha256": "11" * 32,
                "size": 10, "background": False, "min_version": "0.5.0"}

    def run_plan(self, success=True, extra=()):
        self.input.write_text(json.dumps(self.config))
        result = subprocess.run([sys.executable, "-B", str(ENTRY), "--application", "fastnet",
                                 "--live-config", str(self.input), "--zsetup-root", str(ZROOT),
                                 "--native-cli", str(NATIVE), "--output", str(self.output), *extra],
                                env=self.env, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        self.assertFalse(self.marker.exists(), "local planning attempted network access")
        return result

    def test_only_fastnet_files_and_index_record_change(self):
        self.run_plan()
        plan = json.loads((self.output / "app-release-manifest.json").read_text())
        self.assertEqual(plan["application"], "fastnet")
        self.assertFalse(plan["public_release_authorized"])
        self.assertEqual(plan["blockers"], [])
        self.assertEqual(plan["live_config_sha256"], hashlib.sha256(self.input.read_bytes()).hexdigest())
        config = json.loads((self.output / "pointers/zsetup/config.json").read_text())
        self.assertEqual(config["stable_zsetup"], self.config["stable_zsetup"])
        self.assertEqual(config["source_groups"], self.config["source_groups"])
        self.assertEqual([r for r in config["installers"] if r["application"] != "fastnet"], self.config["installers"][1:])
        paths = {r["path"] for r in plan["files"]}
        self.assertEqual(paths, {"immutable/fastnet/0.1.8/fastnet-install.sh", "pointers/fastnet/fastnet-install.sh",
                                "pointers/fastnet/install.sh", "pointers/zsetup/config.json"})
        script = (ROOT / "fastnet/fastnet-install.sh").read_bytes()
        for record in config["installers"]:
            if record["application"] == "fastnet":
                self.assertEqual(record["min_version"], "0.5.0")
                self.assertEqual(record["size"], len(script))
                self.assertEqual(record["sha256"], hashlib.sha256(script).hexdigest())
                self.assertEqual((self.output / "immutable" / record["path"]).read_bytes(), script)
        self.assertEqual((self.output / "pointers/fastnet/install.sh").read_bytes(), script)
        subprocess.run(["sha256sum", "-c", "PACKAGE-SHA256SUMS"], cwd=self.output, check=True, capture_output=True)
        self.assertEqual(self.input.read_text(), json.dumps(self.config))

    def test_old_native_generates_explicit_blocked_plan(self):
        self.config["stable_zsetup"]["version"] = "0.4.0"
        self.config["installers"][0]["min_version"] = "0.4.0"
        self.config["installers"][1]["min_version"] = "0.4.0"
        self.run_plan()
        plan = json.loads((self.output / "app-release-manifest.json").read_text())
        self.assertEqual(plan["readiness"], "blocked")
        self.assertTrue(any("0.4.0" in item and "0.5.0" in item for item in plan["blockers"]))
        proposed = json.loads((self.output / "pointers/zsetup/config.json").read_text())
        self.assertEqual(proposed["stable_zsetup"], self.config["stable_zsetup"])
        self.assertEqual(proposed["installers"][0], self.config["installers"][1])

    def test_unrelated_live_app_is_not_added_or_removed(self):
        self.config["installers"] = [self.record("future-app")]
        self.run_plan()
        proposed = json.loads((self.output / "pointers/zsetup/config.json").read_text())
        self.assertEqual(proposed["installers"][0], self.config["installers"][0])
        self.assertEqual({r["application"] for r in proposed["installers"]}, {"fastnet", "future-app"})

    def test_other_application_is_disabled_in_first_rollout(self):
        self.run_plan(False, ("--application", "ddnsto"))
        self.assertFalse(self.output.exists())

    def test_source_group_conflict_is_refused(self):
        self.config["source_groups"][0]["primary_bases"] = ["https://example.invalid/binary"]
        self.run_plan(False)
        self.assertFalse(self.output.exists())

    def test_invalid_live_schema_is_refused_by_native_parser(self):
        self.config["unexpected"] = True
        self.run_plan(False)
        self.assertFalse(self.output.exists())

    def test_old_native_validator_cannot_validate_new_installer(self):
        fake = self.root / "old-native"
        fake.write_text("#!/bin/sh\necho 'zsetup 0.4.0'\n")
        fake.chmod(0o755)
        self.run_plan(False, ("--native-cli", str(fake)))
        self.assertFalse(self.output.exists())

    def test_existing_review_directory_is_never_overwritten(self):
        self.run_plan()
        before = (self.output / "app-release-manifest.json").read_bytes()
        self.run_plan(False)
        self.assertEqual((self.output / "app-release-manifest.json").read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
