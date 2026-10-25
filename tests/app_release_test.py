"""Single-app release plans preserve unrelated live records and never publish."""
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

    def run_plan(self, success=True, extra=(), app="fastnet"):
        self.input.write_text(json.dumps(self.config))
        result = subprocess.run([sys.executable, "-B", str(ENTRY), "--application", app,
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

    def server(self):
        root = self.root / "server binary"
        for name, data in (("zsetup/config.json", self.input.read_bytes()), ("zsetup/stable", b"0.5.0\n"),
                           ("fastnet/fastnet-install.sh", b"old direct entry\n"), ("fastnet/install.sh", b"old compatibility entry\n"),
                           ("ddnsto/openwrt/install_ddnsto.sh", b"do not touch DDNSTO\n"), ("fastnet/version.txt", b"business metadata\n"),
                           ("fastnet/FastNet-0.7.6.amd64", b"server owned binary\n"), ("zsetup/stable-windows", b"0.4.0\n")):
            path = root / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(data)
        (root / "fastnet/fastnet-install.sh").chmod(0o751)
        self.original = {str(p.relative_to(root)): (p.read_bytes(), p.stat().st_mode & 0o777) for p in root.rglob("*") if p.is_file()}
        return root

    def transaction(self, mode, server, success=True, env=None):
        result = subprocess.run(["sh", str(ROOT / "scripts/install-app-release.sh"), mode, str(self.output), str(server)],
                                capture_output=True, text=True, timeout=10, env=env)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def assert_original(self, server):
        for name, (data, mode) in self.original.items():
            path = server / name
            self.assertEqual(path.read_bytes(), data, name)
            self.assertEqual(path.stat().st_mode & 0o777, mode, name)
        self.assertFalse((server / "zsetup/.windows-release-lock").exists())

    def test_stage_activate_rollback_preserves_other_businesses_and_modes(self):
        self.run_plan(); server = self.server()
        self.transaction("stage", server); self.assert_original(server)
        self.transaction("activate", server)
        self.assertEqual((server / "fastnet/install.sh").read_bytes(), (ROOT / "fastnet/fastnet-install.sh").read_bytes())
        self.assertEqual((server / "fastnet/fastnet-install.sh").read_bytes(), (server / "fastnet/install.sh").read_bytes())
        self.assertEqual((server / "ddnsto/openwrt/install_ddnsto.sh").read_bytes(), self.original["ddnsto/openwrt/install_ddnsto.sh"][0])
        self.transaction("rollback", server); self.assert_original(server)
        self.assertTrue((server / "fastnet/0.1.8/fastnet-install.sh").is_file())

    def test_blocked_plan_cannot_stage_or_activate(self):
        self.config["stable_zsetup"]["version"] = "0.4.0"
        self.run_plan(); server = self.server()
        self.transaction("stage", server, False); self.assert_original(server)
        self.assertFalse((server / "fastnet/0.1.8").exists())
        self.transaction("activate", server, False); self.assert_original(server)

    def test_immutable_conflict_is_preserved(self):
        self.run_plan(); server = self.server()
        immutable = server / "fastnet/0.1.8/fastnet-install.sh"
        immutable.parent.mkdir(); immutable.write_text("existing different immutable bytes")
        self.transaction("stage", server, False); self.assert_original(server)
        self.assertEqual(immutable.read_text(), "existing different immutable bytes")

    def test_remote_config_and_entry_drift_prevent_activation(self):
        self.run_plan(); server = self.server()
        self.transaction("stage", server)
        alias = server / "fastnet/install.sh"; alias.write_text("new publisher changed alias")
        self.transaction("activate", server, False)
        self.assertEqual(alias.read_text(), "new publisher changed alias")
        self.assertEqual((server / "zsetup/config.json").read_bytes(), self.original["zsetup/config.json"][0])
        alias.write_bytes(self.original["fastnet/install.sh"][0])
        config = server / "zsetup/config.json"; config.write_text("new publisher changed config")
        self.transaction("activate", server, False)
        self.assertEqual(config.read_text(), "new publisher changed config")

    def test_partial_activation_failure_restores_all_pointers(self):
        self.run_plan(); server = self.server(); self.transaction("stage", server)
        tools = self.root / "failure tools"; tools.mkdir()
        mv = tools / "mv"
        import shlex
        marker = self.root / "failed-once"
        mv.write_text("#!/bin/sh\ncase \"$*\" in *zsetup/config.json) if [ ! -e " + shlex.quote(str(marker)) +
                      " ]; then touch " + shlex.quote(str(marker)) + "; exit 42; fi ;; esac\nexec /bin/mv \"$@\"\n")
        mv.chmod(0o755)
        self.transaction("activate", server, False, os.environ | {"PATH": str(tools) + ":" + os.environ["PATH"]})
        self.assertTrue(marker.exists()); self.assert_original(server)

    def test_symlink_target_and_out_of_order_rollback_are_refused(self):
        self.run_plan(); server = self.server()
        target = server / "fastnet/install.sh"; original = target.read_bytes()
        target.unlink(); target.symlink_to(server / "ddnsto/openwrt/install_ddnsto.sh")
        self.transaction("stage", server, False)
        self.assertEqual((server / "ddnsto/openwrt/install_ddnsto.sh").read_bytes(), self.original["ddnsto/openwrt/install_ddnsto.sh"][0])
        target.unlink(); target.write_bytes(original)
        self.transaction("stage", server); self.transaction("activate", server)
        (server / "zsetup/config.json").write_text("later release")
        self.transaction("rollback", server, False)
        self.assertEqual((server / "zsetup/config.json").read_text(), "later release")


    def test_linkspace_scoped_rollout_and_rollback(self):
        self.run_plan(app="linkspace")
        plan = json.loads((self.output / "app-release-manifest.json").read_text())
        self.assertEqual({f["destination"] for f in plan["files"]}, {
            "linkspace/0.1.0/linkspace-install.sh", "linkspace/linkspace-install.sh", "zsetup/config.json"})
        proposed = json.loads((self.output / "pointers/zsetup/config.json").read_text())
        self.assertEqual(proposed["stable_zsetup"], self.config["stable_zsetup"])
        self.assertEqual(proposed["source_groups"], self.config["source_groups"])
        self.assertEqual([r for r in proposed["installers"] if r["application"] != "linkspace"], self.config["installers"])
        records = [r for r in proposed["installers"] if r["application"] == "linkspace"]
        self.assertEqual({r["arch"] for r in records}, {"x86_64", "aarch64", "armv7"})
        self.assertTrue(all(r["os"] == "linux" and r["min_version"] == "0.5.0" for r in records))
        server = self.server()
        self.transaction("stage", server); self.assert_original(server)
        self.assertFalse((server / "linkspace/linkspace-install.sh").exists())
        self.transaction("activate", server)
        self.assertEqual((server / "linkspace/linkspace-install.sh").read_bytes(), (ROOT / "linkspace/linkspace-install.sh").read_bytes())
        self.transaction("rollback", server); self.assert_original(server)
        self.assertFalse((server / "linkspace/linkspace-install.sh").exists())
        self.assertTrue((server / "linkspace/0.1.0/linkspace-install.sh").is_file())

    def test_linkspace_conflict_and_drift_are_refused(self):
        self.run_plan(app="linkspace"); server = self.server()
        immutable = server / "linkspace/0.1.0/linkspace-install.sh"
        immutable.parent.mkdir(parents=True); immutable.write_text("conflict")
        self.transaction("stage", server, False); self.assert_original(server)
        self.assertEqual(immutable.read_text(), "conflict")
        immutable.write_bytes((ROOT / "linkspace/linkspace-install.sh").read_bytes())
        self.transaction("stage", server)
        (server / "zsetup/config.json").write_text("new publisher")
        self.transaction("activate", server, False)
        self.assertFalse((server / "linkspace/linkspace-install.sh").exists())


if __name__ == "__main__":
    unittest.main()
