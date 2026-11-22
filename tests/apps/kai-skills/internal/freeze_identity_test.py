"""Release-bound installer accepts only the exact reviewed freeze identity."""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[4]
SPEC = importlib.util.spec_from_file_location("kai_skills_build", ROOT / "apps/kai-skills/source/build.py")
build = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(build)


def canonical(value):
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode()


class FreezeIdentityTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="zsetup kai freeze ")
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.release = self.work / "zsetup"
        self.release.mkdir()
        self.commit = "a" * 40
        self.release_manifest = self.release / "release-manifest.json"
        self.release_manifest.write_text(json.dumps({
            "schemaVersion": 3, "distribution": "kai-skills-zsetup",
            "minimumZsetupVersion": "0.6.0", "archiveFormat": "tar.gz",
            "version": "1.2.5", "sourceCommit": self.commit, "artifacts": [],
        }))
        digest = "sha256:" + build.sha(self.release_manifest)
        freeze = {
            "schemaVersion": 1, "version": "1.2.5", "sourcePolicy": "clean-committed",
            "sources": {
                "kai-skills": {"commit": self.commit, "state": "committed"},
                "reasonix-kai": {"commit": "b" * 40, "state": "committed"},
            },
            "protocols": {"capabilityCatalog": 1, "kaiplusSnapshot": 2, "zsetupRelease": 3},
            "identities": {"zsetupManifestSHA256": digest},
            "files": {"zsetup/release-manifest.json": {
                "sha256": digest, "size": self.release_manifest.stat().st_size,
            }},
        }
        freeze["releaseId"] = "sha256:" + hashlib.sha256(canonical(freeze)).hexdigest()
        self.freeze = self.work / "freeze-manifest.json"
        self.freeze.write_bytes(canonical(freeze))

    def test_exact_freeze_is_accepted(self):
        self.assertTrue(build.verify_freeze(self.freeze, self.release).startswith("sha256:"))
        output = self.work / "installer.sh"
        result = subprocess.run([
            sys.executable, str(ROOT / "apps/kai-skills/source/build.py"), "--release", str(self.release),
            "--freeze-manifest", str(self.freeze), "--output", str(output),
        ], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(output.is_file())
        missing = subprocess.run([
            sys.executable, str(ROOT / "apps/kai-skills/source/build.py"), "--release", str(self.release),
            "--output", str(self.work / "unreviewed.sh"),
        ], text=True, capture_output=True)
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("--freeze-manifest is required", missing.stderr)

    def test_tampered_release_and_noncommitted_policy_are_rejected(self):
        changed = self.work / "changed"
        shutil.copytree(self.release, changed)
        (changed / "release-manifest.json").write_bytes(self.release_manifest.read_bytes() + b"\n")
        with self.assertRaisesRegex(SystemExit, "does not match"):
            build.verify_freeze(self.freeze, changed)
        data = json.loads(self.freeze.read_text())
        data.pop("releaseId")
        data["sourcePolicy"] = "explicit-test-fixture"
        data["releaseId"] = "sha256:" + hashlib.sha256(canonical(data)).hexdigest()
        fixture = self.work / "fixture-freeze.json"
        fixture.write_bytes(canonical(data))
        with self.assertRaisesRegex(SystemExit, "not from clean"):
            build.verify_freeze(fixture, self.release)
        self.assertTrue(build.verify_freeze(fixture, self.release, allow_fixture=True))


if __name__ == "__main__":
    unittest.main()
