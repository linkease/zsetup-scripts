import pathlib, subprocess, sys, tempfile, unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]
class BuilderBootstrapTests(unittest.TestCase):
    def test_channel_uses_repository_owned_bootstraps_after_apps_migration(self):
        with tempfile.TemporaryDirectory(prefix="kai channel ") as temporary:
            root = pathlib.Path(temporary)
            subprocess.run([sys.executable, "-B", str(ROOT / "apps/kai-skills/source/build.py"), "--channel-only", "--channel-entrypoint", str(root / "install.sh"), "--windows-channel-entrypoint", str(root / "setup.ps1")], check=True, capture_output=True)
            self.assertIn("zsetup", (root / "install.sh").read_text())
            self.assertIn("zsetup", (root / "setup.ps1").read_text())
if __name__ == "__main__": unittest.main()
