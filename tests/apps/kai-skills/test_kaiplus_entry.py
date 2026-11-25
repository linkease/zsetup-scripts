import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]


class KaiPlusEntryTests(unittest.TestCase):
    def setUp(self):
        self.fake_tools = tempfile.TemporaryDirectory(prefix="no network ")
        self.addCleanup(self.fake_tools.cleanup)
        for tool in ("curl", "wget"):
            path = pathlib.Path(self.fake_tools.name) / tool
            path.write_text("#!/bin/sh\nexit 85\n")
            path.chmod(0o700)
        self.env = {"PATH": self.fake_tools.name + ":/usr/bin:/bin", "ZSETUP_ROOT": self.fake_tools.name + "/cache", "ZSETUP_CONFIRM_FILE": "/dev/null"}

    def test_managed_entry_prepares_exact_private_context_without_bootstrap(self):
        with tempfile.TemporaryDirectory(prefix="kaiplus entry ") as temporary:
            work = pathlib.Path(temporary)
            context = work / "context.json"
            context.write_text("{}")
            binary = work / "kaiplus"
            binary.write_text('#!/bin/sh\n[ "$#" = 6 ] && [ "$1" = _skills_prepare ] && [ "$3" = --source ] && [ "$4" = kaiplus ] && [ "$5" = --system ] || exit 71\nprintf "%s|%s\\n" "$2" "$6"\n')
            binary.chmod(0o700)
            for name in ("install.sh", "kai-skills-install.sh"):
                for system in ("istoreos", "ubuntu"):
                    result = subprocess.run(["/bin/sh", str(ROOT / "apps/kai-skills" / name), "--source", "kaiplus", "--system", system, "--context", str(context)],
                                            env={**self.env, "KAI_PLUS_BIN": str(binary)}, capture_output=True, text=True, timeout=5)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.strip(), str(context) + "|" + system)

    def test_missing_private_context_fails_before_network_or_normal_install(self):
        for args in (["--source"], ["--source", "other", "--system", "istoreos", "--context", "/missing/context"],
                     ["--source", "kaiplus", "--system", "invalid;id", "--context", "/missing/context"],
                     ["--source", "kaiplus", "--system", "istoreos", "--context", "/missing/context", "--upgrade"]):
            result = subprocess.run(["/bin/sh", str(ROOT / "apps/kai-skills/install.sh"), *args],
                                    env=self.env, capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 2)
            self.assertIn("KaiPlus", result.stderr)


if __name__ == "__main__":
    unittest.main()
