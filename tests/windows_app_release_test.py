"""Windows app plans are platform-scoped, deterministic, and reversible."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
ZROOT = Path(sys.argv.pop(1)).resolve()
NATIVE = Path(sys.argv.pop(1)).resolve()
PACKAGER = ROOT / "scripts/package-windows-app-release.py"
TRANSACTION = ROOT / "scripts/install-windows-app-release.sh"
BASES = [
    "https://dl.istoreos.com/binary",
    "https://fw.d4ctech.com/binary",
    "https://fw20.koolcenter.com/binary",
]
FALLBACK = "https://fw.koolcenter.com/binary"


class WindowsAppRelease(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="windows-app-release-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.core = self.root / "core/zsetup/0.4.0"
        self.core.mkdir(parents=True)
        self.core_exe = self.core / "zsetup-windows-i686.exe"
        self.core_exe.write_bytes(b"MZ" + b"canonical Windows core fixture" * 8)
        self.stable = self.root / "stable-windows"
        self.stable.write_text("0.4.0\n", encoding="ascii")
        self.config = {
            "schema_version": 1,
            "config_version": "zsetup-windows-0.4.0",
            "source_groups": [{
                "id": "release", "primary_bases": BASES,
                "fallback_base": FALLBACK,
            }],
            "stable_zsetup": {
                "version": "0.4.0", "source_group": "release",
                "artifacts": [{
                    "arch": "i686", "path": "zsetup/0.4.0/zsetup-windows-i686.exe",
                    "sha256": hashlib.sha256(self.core_exe.read_bytes()).hexdigest(),
                    "size": self.core_exe.stat().st_size,
                }],
            },
            "installers": [{
                "application": "existing", "os": "windows", "package_manager": "*", "arch": "x86_64",
                "source_group": "release", "path": "existing/1.0.0/existing-install.ps1",
                "sha256": "11" * 32, "size": 10, "background": False, "min_version": "0.4.0",
            }],
        }
        self.live = self.root / "config-windows.json"
        self.output = self.root / "review"
        self.marker = self.root / "network-attempt"
        tools = self.root / "tools"
        tools.mkdir()
        for name in ("ssh", "scp", "curl", "wget"):
            tool = tools / name
            tool.write_text(f"#!/bin/sh\ntouch '{self.marker}'\nexit 91\n")
            tool.chmod(0o755)
        self.environment = os.environ | {"PATH": str(tools) + ":" + os.environ["PATH"]}

    def run_plan(self, success=True, output=None, extra=()):
        self.live.write_text(json.dumps(self.config), encoding="utf-8")
        target = output or self.output
        result = subprocess.run([
            sys.executable, "-B", str(PACKAGER), "--application", "scoop",
            "--live-config", str(self.live), "--stable-windows", str(self.stable),
            "--core-release", str(self.core), "--zsetup-root", str(ZROOT),
            "--native-cli", str(NATIVE), "--output", str(target), *extra,
        ], env=self.environment, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        self.assertFalse(self.marker.exists(), "local candidate preparation attempted network access")
        return target

    def test_only_scoop_entry_and_windows_config_are_proposed(self):
        review = self.run_plan()
        manifest = json.loads((review / "windows-app-release-manifest.json").read_text())
        self.assertEqual(manifest["application"], "scoop")
        self.assertEqual(manifest["platform"], "windows")
        self.assertFalse(manifest["public_release_authorized"])
        self.assertEqual(manifest["unchanged"], [
            "zsetup/stable-windows", "Windows core artifacts", "non-Windows configurations",
            "other Windows application files and installer records", "source groups",
        ])
        proposed = json.loads((review / "pointers/zsetup/config-windows.json").read_text())
        self.assertEqual(proposed["stable_zsetup"], self.config["stable_zsetup"])
        self.assertEqual(proposed["source_groups"], self.config["source_groups"])
        self.assertEqual(proposed["installers"][0], self.config["installers"][0])
        scoop = [item for item in proposed["installers"] if item["application"] == "scoop"]
        self.assertEqual(len(scoop), 1)
        self.assertEqual(scoop[0]["os"], "windows")
        self.assertEqual(scoop[0]["arch"], "x86_64")
        self.assertEqual(scoop[0]["min_version"], "0.4.0")
        self.assertTrue(scoop[0]["path"].endswith("/scoop-install.ps1"))
        entry = review / "immutable" / scoop[0]["path"]
        self.assertEqual(scoop[0]["size"], entry.stat().st_size)
        self.assertEqual(scoop[0]["sha256"], hashlib.sha256(entry.read_bytes()).hexdigest())
        destinations = {item["destination"] for item in manifest["files"]}
        self.assertEqual(destinations, {
            "scoop/0.1.0/scoop-install.ps1", "scoop/scoop-install.ps1",
            "zsetup/config-windows.json",
        })
        self.assertFalse((review / "pointers/zsetup/stable-windows").exists())
        subprocess.run(["sha256sum", "-c", "PACKAGE-SHA256SUMS"], cwd=review, check=True, capture_output=True)

    def test_same_inputs_produce_identical_candidate_bytes(self):
        first = self.run_plan(output=self.root / "first")
        second = self.run_plan(output=self.root / "second")
        first_files = {str(path.relative_to(first)): path.read_bytes() for path in first.rglob("*") if path.is_file()}
        second_files = {str(path.relative_to(second)): path.read_bytes() for path in second.rglob("*") if path.is_file()}
        self.assertEqual(first_files, second_files)

    def test_generator_check_rejects_manual_power_shell_edit(self):
        output = self.root / "generated"
        subprocess.run([sys.executable, "-B", str(ROOT / "scoop/build.py"), "--output-dir", str(output)], check=True)
        entry = output / "scoop-install.ps1"
        entry.write_text(entry.read_text() + "# manual edit\n", encoding="utf-8")
        result = subprocess.run([
            sys.executable, "-B", str(ROOT / "scoop/build.py"), "--output-dir", str(output), "--check",
        ], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)

    def test_generated_entry_declares_utf8_for_redirected_json(self):
        entry = (ROOT / "scoop/scoop-install.ps1").read_text(encoding="utf-8")
        self.assertIn("[Console]::OutputEncoding = $script:ScoopUtf8NoBom", entry)
        self.assertIn("$OutputEncoding = $script:ScoopUtf8NoBom", entry)

    def test_wrong_minimum_extension_source_or_core_identity_is_refused(self):
        registration = json.loads((ROOT / "release/windows-applications.json").read_text())
        cases = {}
        bad = json.loads(json.dumps(registration)); bad["applications"]["scoop"]["minimum_runtime"] = "0.5.0"
        cases["minimum"] = bad
        bad = json.loads(json.dumps(registration)); bad["applications"]["scoop"]["public_entries"] = ["scoop/scoop-install.sh"]
        cases["extension"] = bad
        bad = json.loads(json.dumps(registration)); bad["source_group"]["primary_bases"] = ["https://example.invalid/binary"]
        cases["sources"] = bad
        for name, value in cases.items():
            with self.subTest(name=name):
                path = self.root / f"{name}.json"
                path.write_text(json.dumps(value))
                self.run_plan(False, output=self.root / f"bad-{name}", extra=("--registration", str(path)))
        self.config["stable_zsetup"]["artifacts"][0]["sha256"] = "22" * 32
        self.run_plan(False, output=self.root / "bad-core")

    def server(self):
        server = self.root / "server/binary"
        (server / "zsetup").mkdir(parents=True)
        (server / "existing").mkdir()
        (server / "zsetup/config-windows.json").write_bytes(self.live.read_bytes())
        (server / "zsetup/stable-windows").write_bytes(self.stable.read_bytes())
        (server / "zsetup/zsetup-windows-i686.exe").write_bytes(self.core_exe.read_bytes())
        (server / "existing/existing-install.ps1").write_text("do not change\n")
        self.original = {str(path.relative_to(server)): path.read_bytes() for path in server.rglob("*") if path.is_file()}
        return server

    def transaction(self, mode, server, success=True):
        result = subprocess.run([
            "sh", str(TRANSACTION), mode, str(self.output), str(server),
        ], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)

    def test_stage_activate_and_rollback_are_windows_scoped(self):
        self.run_plan()
        server = self.server()
        self.transaction("stage", server)
        for name, data in self.original.items():
            self.assertEqual((server / name).read_bytes(), data, name)
        self.transaction("activate", server)
        self.assertEqual((server / "zsetup/stable-windows").read_bytes(), self.original["zsetup/stable-windows"])
        self.assertEqual((server / "zsetup/zsetup-windows-i686.exe").read_bytes(), self.original["zsetup/zsetup-windows-i686.exe"])
        self.assertEqual((server / "existing/existing-install.ps1").read_bytes(), self.original["existing/existing-install.ps1"])
        self.assertTrue((server / "scoop/scoop-install.ps1").is_file())
        self.transaction("rollback", server)
        for name, data in self.original.items():
            self.assertEqual((server / name).read_bytes(), data, name)
        self.assertFalse((server / "scoop/scoop-install.ps1").exists())
        self.assertTrue((server / "scoop/0.1.0/scoop-install.ps1").is_file())

    def test_tamper_conflict_and_drift_do_not_partially_activate(self):
        self.run_plan()
        server = self.server()
        entry = self.output / "pointers/scoop/scoop-install.ps1"
        entry.write_text("tampered")
        self.transaction("stage", server, False)
        self.assertFalse((server / "scoop").exists())
        shutil.rmtree(self.output)
        self.run_plan()
        self.transaction("stage", server)
        (server / "zsetup/config-windows.json").write_text("publisher drift")
        self.transaction("activate", server, False)
        self.assertFalse((server / "scoop/scoop-install.ps1").exists())
        self.assertEqual((server / "zsetup/config-windows.json").read_text(), "publisher drift")

    def test_existing_output_is_never_overwritten(self):
        self.run_plan()
        before = (self.output / "windows-app-release-manifest.json").read_bytes()
        self.run_plan(False)
        self.assertEqual((self.output / "windows-app-release-manifest.json").read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
