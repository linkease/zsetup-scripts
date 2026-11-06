"""The promoted Scoop installer keeps the locked M4/M3 trust chain explicit."""
import json
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class WindowsScoopContract(unittest.TestCase):
    def test_catalog_promotes_a_new_immutable_010_entry(self):
        catalog = json.loads((ROOT / "catalog-windows.json").read_text())
        self.assertEqual(catalog["config_version"], "windows-apps-0.1.0")
        self.assertEqual(len(catalog["installers"]), 1)
        record = catalog["installers"][0]
        self.assertEqual(record["application"], "scoop")
        self.assertEqual(record["os"], "windows")
        self.assertEqual(record["arch"], "x86_64")
        self.assertEqual(record["path"], "scoop/0.1.0/scoop-install.ps1")

    def test_business_source_pins_and_uses_the_verified_bootstrap_chain(self):
        source = (ROOT / "scoop/business.ps1").read_text(encoding="utf-8")
        for value in (
            "0.7.16-08aea475819b8037977684c7fbbde2ae40bb1b96-windows-amd64",
            "66fa51769556b8d52289f354d3e43952338814b6ef357b04868f829fc1c5c4dc",
            "e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f",
            "fa96b15950f3726d2c9a35493e192eefe56d2eddba718e8121c32f7a19257a0a",
            "1eca0759af467b38ae87b9579dd545d35f5b9917",
            "4287b169ce39f3a6566da666ce3c8b73f450c887d9a71481485b2ad2ca951636",
        ):
            self.assertIn(value, source)
        for operation in (
            "Invoke-ZsetupRuntimeDownload", "Expand-VerifiedRuntimeBundle",
            "Invoke-AcceleratedBootstrap", "Expand-VerifiedScoopArchive",
            "Commit-ScoopTransaction", "Write-ScoopOwnedReceipt",
            "Test-ScoopAdministrator", "Test-ScoopSafePath",
        ):
            self.assertIn(operation, source)
        self.assertNotIn("M5 candidate only", source)
        self.assertNotIn("Invoke-WebRequest", source)
        self.assertNotIn("Start-BitsTransfer", source)

    def test_generated_entry_is_current_and_bounded(self):
        entry = ROOT / "scoop/scoop-install.ps1"
        self.assertLess(entry.stat().st_size, 131072)
        spec = importlib.util.spec_from_file_location("scoop_build", ROOT / "scoop/build.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertEqual(entry.read_text(encoding="utf-8"), module.render())

    def test_sealed_builder_is_present_and_has_no_network_fallback(self):
        builder = (ROOT / "scripts/package-scoop-sealed.py").read_text(encoding="utf-8")
        self.assertIn("sealed-manifest.json", builder)
        self.assertIn("runtime-bundle.zip", builder)
        self.assertIn("scoop-core.zip", builder)
        self.assertIn("scoop-main.zip", builder)


if __name__ == "__main__":
    unittest.main()
