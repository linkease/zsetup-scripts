"""Controlled ASUS transactions on disposable fixtures; no host services."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class AsusTransaction(unittest.TestCase):
    def invoke(self, token="same-token", version="4.2.8", failure=""):
        module = ROOT / "asus-transaction.sh"
        self.assertTrue(module.exists(), "controlled ASUS transaction is missing")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "dbus").mkdir()
            values = {"ddnsto_token": "same-token", "ddnsto_version": version,
                      "ddnsto_enable": "1", "ddnsto_feat_password": "keep-$()-secret"}
            for key, value in values.items():
                (root / "dbus" / key).write_text(value)
            script = f'''
set -eu
. "{ROOT}/auto-install.sh"
. "{module}"
ASUS_STATE=$FIXTURE
ASUS_CANCEL=$FIXTURE/cancel
TOKEN=$INPUT_TOKEN
ddnsto_asus_preflight() {{ ASUS_CHANNEL=rogsoft; ASUS_ARCH=aarch64; }}
ddnsto_asus_busy() {{ [ "$FAIL" != busy ]; }}
ddnsto_asus_get() {{ cat "$FIXTURE/dbus/$1" 2>/dev/null || :; }}
ddnsto_asus_set() {{ printf '%s' "$2" > "$FIXTURE/dbus/$1"; }}
ddnsto_asus_mktemp() {{ if [ "$FAIL" = account_race ]; then printf foreign-token > "$FIXTURE/dbus/ddnsto_token"; fi; mktemp -d "$1/attempt.XXXXXX"; }}
ddnsto_asus_fetch() {{ echo fetch >> "$FIXTURE/events"; [ "$FAIL" != download ] || return 11; touch "$1"; }}
ddnsto_asus_extract() {{ mkdir "$2"; printf 'verified candidate' > "$2/ddnsto"; }}
ddnsto_asus_backup_plugin() {{ echo backup >> "$FIXTURE/events"; mkdir "$ASUS_ATTEMPT/changed"; }}
ddnsto_asus_install_plugin() {{ echo install >> "$FIXTURE/events"; if [ "$FAIL" = cancel_commit ]; then touch "$ASUS_CANCEL"; fi; [ "$FAIL" != install ]; }}
ddnsto_asus_restore_plugin() {{ echo restore >> "$FIXTURE/events"; }}
ddnsto_asus_stop() {{ echo stop >> "$FIXTURE/events"; }}
ddnsto_asus_start() {{ echo start >> "$FIXTURE/events"; if [ "$FAIL" = account_start_race ]; then printf foreign-token > "$FIXTURE/dbus/ddnsto_token"; fi; }}
ddnsto_asus_running() {{ [ "$FAIL" != start ]; }}
ddnsto_asus_reusable() {{ [ "$FAIL" = reuse ]; }}
ddnsto_asus_ensure_locked
'''
            result = subprocess.run(["sh", "-c", script], text=True, capture_output=True,
                                    env=os.environ | {"FIXTURE": directory, "INPUT_TOKEN": token, "FAIL": failure})
            events = (root / "events").read_text().splitlines() if (root / "events").exists() else []
            after = {p.name: p.read_text() for p in (root / "dbus").iterdir()}
            return result, events, after

    def test_same_account_keeps_feature_configuration(self):
        result, events, after = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(events.index("fetch"), events.index("stop"))
        self.assertLess(events.index("backup"), events.index("stop"))
        self.assertEqual(after["ddnsto_token"], "same-token")
        self.assertEqual(after["ddnsto_feat_password"], "keep-$()-secret")

    def test_foreign_account_never_downloads_or_stops(self):
        result, events, _ = self.invoke(token="another-token")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("E_ACCOUNT", result.stderr)
        self.assertEqual(events, [])
        self.assertNotIn("another-token", result.stderr)

    def test_newer_version_is_not_overwritten(self):
        result, events, _ = self.invoke(version="4.2.9")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("E_VERSION", result.stderr)
        self.assertEqual(events, [])

    def test_download_failure_does_not_stop_or_replace(self):
        result, events, _ = self.invoke(failure="download")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(events, ["fetch"])

    def test_install_failure_attempts_recovery(self):
        result, events, after = self.invoke(failure="install")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("restore", events)
        self.assertEqual(after["ddnsto_token"], "same-token")

    def test_start_failure_is_not_success(self):
        result, events, _ = self.invoke(failure="start")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("E_START", result.stderr)
        self.assertIn("restore", events)

    def test_busy_software_center_is_not_modified(self):
        result, events, _ = self.invoke(failure="busy")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("E_BUSY", result.stderr)
        self.assertEqual(events, [])

    def test_identity_is_revalidated_against_captured_snapshot(self):
        result, events, after = self.invoke(failure='account_race')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('E_ACCOUNT', result.stderr)
        self.assertEqual(events, [])
        self.assertEqual(after['ddnsto_token'], 'foreign-token')

    def test_cancellation_after_commit_finishes_recovery(self):
        result, events, after = self.invoke(failure='cancel_commit')
        self.assertEqual(result.returncode, 143)
        self.assertIn('restore', events)
        self.assertNotIn('start', events)
        self.assertEqual(after['ddnsto_token'], 'same-token')

    def test_verified_running_managed_install_is_not_reinstalled(self):
        result, events, after = self.invoke(failure='reuse')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(events, [])
        self.assertEqual(after['ddnsto_token'], 'same-token')

    def test_account_changed_during_start_cannot_report_success(self):
        result, events, after = self.invoke(failure='account_start_race')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('E_ACCOUNT', result.stderr)
        self.assertIn('restore', events)
        self.assertEqual(after['ddnsto_token'], 'foreign-token')


if __name__ == "__main__":
    unittest.main()
