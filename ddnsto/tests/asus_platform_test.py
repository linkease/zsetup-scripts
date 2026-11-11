"""ASUS routing decisions only; never execute a vendor installer."""
from pathlib import Path
import subprocess
import unittest

MODULE = Path(__file__).resolve().parents[1] / "asus-platform.sh"


class AsusPlatformTest(unittest.TestCase):
    def select(self, model="RT-AX86U", kernel="4.1.52", arch="aarch64",
               source="https://rogsoft.ddnsto.com"):
        self.assertTrue(MODULE.is_file(), "ASUS channel selector is not implemented")
        return subprocess.run(
            ["sh", "-eu", "-c", '. "$1"; shift; ddnsto_asus_channel "$@"',
             "test", str(MODULE), model, kernel, arch, source],
            capture_output=True, text=True, timeout=3)

    def test_six_channels(self):
        cases = [
            ("RT-AX86U", "4.1.52", "aarch64", "rogsoft"),
            ("RT-AC68U", "2.6.36.4", "armv7l", "armsoft"),
            ("TX-AX6000", "5.4.0", "aarch64", "mtksoft"),
            ("ZenWiFi_BD4", "4.4.60", "armv7l", "ipq32soft"),
            ("TUF_6500", "4.4.60", "aarch64", "ipq64soft"),
            ("RT-AX89X", "4.4.60", "aarch64", "qcasoft"),
        ]
        for model, kernel, arch, channel in cases:
            with self.subTest(channel=channel):
                result = self.select(model, kernel, arch, f"https://{channel}.ddnsto.com")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), channel)

    def test_all_known_mtk_models_without_channel(self):
        for model in ("TX-AX6000", "TUF-AX4200Q", "RT-AX57_Go", "GS7",
                      "ZenWiFi_BT8P", "GS7_Air", "GS-BE7200X"):
            result = self.select(model=model, source="")
            self.assertEqual(result.stdout.strip(), "mtksoft")
            self.assertEqual(result.returncode, 0)

    def test_channel_conflict_fails_closed(self):
        result = self.select(model="TX-AX6000")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_architecture_is_not_a_channel(self):
        result = self.select(model="unknown", source="")
        self.assertNotEqual(result.returncode, 0)

    def test_untrusted_source_is_not_used(self):
        for source in ("http://rogsoft.ddnsto.com", "https://evil.example/rogsoft",
                       "https://rogsoft.ddnsto.com.evil.example", "$(touch /tmp/not-run)"):
            self.assertNotEqual(self.select(source=source).returncode, 0)

    def test_modern_channel_rejects_legacy_kernel(self):
        self.assertNotEqual(self.select(kernel="2.6.36", arch="armv7l").returncode, 0)

    def test_armsoft_rejects_modern_kernel_and_arm64(self):
        self.assertNotEqual(self.select(source="https://armsoft.ddnsto.com").returncode, 0)
        self.assertNotEqual(self.select(kernel="2.6.36", source="https://armsoft.ddnsto.com").returncode, 0)

    def test_unknown_kernel_and_architecture_rejected(self):
        for kernel, arch in (("unknown", "aarch64"), ("3.10.0", "aarch64"),
                             ("4.1.52", "mips"), ("4.1.52", "x86_64")):
            self.assertNotEqual(self.select(kernel=kernel, arch=arch).returncode, 0)

    def test_malformed_kernel_rejected_without_output(self):
        for kernel in ("4.1garbage", "5.", "6..1", "4.01.1", "4.1.52/evil"):
            result = self.select(kernel=kernel)
            self.assertEqual(result.returncode, 2, kernel)
            self.assertEqual(result.stdout, "")

    def test_vendor_kernel_suffix_and_source_slash(self):
        result = self.select(kernel="4.1.52-vendor+", source="https://rogsoft.ddnsto.com/")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "rogsoft")

    def test_unknown_model_requires_verified_caller_and_channel_hint(self):
        # The pure selector is not a firmware identity/authenticity check.
        result = self.select(model="future-model")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "rogsoft")

    def test_exact_reviewed_package_pins(self):
        expected = {
            "rogsoft": ("hnd", 8104981, "671c1c77d7b867f5019af35e8702be665695e30c107138ae150d045e11df1960"),
            "armsoft": ("arm384", 3430887, "8e0ff71269b8ba8674427896310d99309d97eae92b007d97cb968eb1d880664d"),
            "mtksoft": ("mtk", 8105004, "8d08921e49bed7bcafed48dc6c6b6795467f77767a97cc8af23f0b463285248a"),
            "ipq32soft": ("ipq32", 8105008, "56c0298ec811e51cf93390bbfa2f9489752188320aaf96c43d2b19289ba7580d"),
            "ipq64soft": ("ipq64", 8105008, "4cb863a85d5c5dcd00ff8a3f5a09fa90465b59b48e48cdce12163be62b1f10ce"),
            "qcasoft": ("qca", 8105006, "fa021afaf9424f032ff9e084e76c80fadd7fe74e844060e0d84ac6053db19216"),
        }
        for channel, (marker, size, sha) in expected.items():
            result = subprocess.run(
                ["sh", "-eu", "-c", '. "$1"; ddnsto_asus_package "$2"',
                 "test", str(MODULE), channel], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.split(), [
                f"https://asusgo.koolcenter.com/{channel}/ddnsto/ddnsto.tar.gz",
                "4.2.8", marker, str(size), sha])

    def test_unknown_channel_cannot_form_download_url(self):
        result = subprocess.run(
            ["sh", "-eu", "-c", '. "$1"; ddnsto_asus_package "$2"',
             "test", str(MODULE), "../../evil"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
