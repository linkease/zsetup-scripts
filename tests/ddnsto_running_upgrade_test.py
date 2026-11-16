"""Running-old-version scenarios. OS/package/download boundaries are fixtures.

No real client, router, launchd or host services are modified. Run directly.
Linux native filesystem transactions have a separate disposable-container suite.
"""
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'ddnsto/tests'))
import macos_behavior_test as mac
import openwrt_lifecycle_test as ow
import asus_transaction_test as asus


class MacRunningUpgrade(unittest.TestCase):
    setUp = mac.MacInstaller.setUp
    tool = mac.MacInstaller.tool
    run_script = mac.MacInstaller.run_script
    receipt = mac.MacInstaller.receipt

    def old_running(self):
        self.assertEqual(self.run_script().returncode, 0)
        (self.install / 'ddnsto').write_bytes(b'old 4.2.7 fixture binary')
        self.receipt('4.2.7')
        config = self.config / 'ddnsto.yaml'
        config.write_text(config.read_text() + 'routerName: preserved\n')
        (self.config / '.ddnsto_boot.cfg').write_bytes(b'preserved-device-identity')
        self.assertTrue((self.root / 'running').exists())
        return {p: p.read_bytes() for p in (config, self.config / '.ddnsto_boot.cfg',
                self.install / 'ddnsto', self.config / '.installer-macos-version')}

    def test_old_running_upgrade_replaces_bytes_and_restarts_preserving_identity(self):
        before = self.old_running()
        calls_before = (self.root / 'service.log').read_text()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('local_service=running', result.stdout)
        calls = (self.root / 'service.log').read_text()[len(calls_before):].splitlines()
        self.assertLess(calls.index('bootout'), calls.index('bootstrap'))
        self.assertLess(calls.index('bootstrap'), calls.index('kickstart'))
        self.assertEqual((self.install / 'ddnsto').read_bytes(), b'new binary')
        self.assertTrue((self.config / '.installer-macos-version').read_text().startswith('4.2.8 '))
        for path in (self.config / 'ddnsto.yaml', self.config / '.ddnsto_boot.cfg'):
            self.assertEqual(path.read_bytes(), before[path])
        self.assertTrue((self.root / 'running').exists())

    def test_download_failure_keeps_old_running_without_stop(self):
        before = self.old_running()
        calls_before = (self.root / 'service.log').read_text()
        result = self.run_script(FAIL_DOWNLOAD='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('bootout', (self.root / 'service.log').read_text()[len(calls_before):])
        self.assertTrue((self.root / 'running').exists())
        for path, data in before.items(): self.assertEqual(path.read_bytes(), data)

    def test_new_start_failure_restores_old_bytes_receipt_config_and_running(self):
        before = self.old_running()
        calls_before = (self.root / 'service.log').read_text()
        result = self.run_script(FAIL_START='1')
        self.assertNotEqual(result.returncode, 0)
        calls = (self.root / 'service.log').read_text()[len(calls_before):].splitlines()
        self.assertIn('bootout', calls)
        self.assertGreaterEqual(calls.count('bootstrap'), 2)
        self.assertNotIn('local_service=running', result.stdout)
        for path, data in before.items(): self.assertEqual(path.read_bytes(), data)
        self.assertTrue((self.root / 'running').exists())


class OpenWrtRunningUpgrade(unittest.TestCase):
    setUp = ow.OpenWrtLifecycleTests.setUp
    main_command = ow.OpenWrtLifecycleTests.main_command
    invoke_main = ow.OpenWrtLifecycleTests.invoke_main
    calls = ow.OpenWrtLifecycleTests.calls

    def old_running(self):
        self.config.write_text(ow.ORIGINAL.replace("enabled '0'", "enabled '1'"))
        self.assertFalse((self.root / 'stopped').exists())
        return self.config.read_bytes(), self.binary.read_bytes()

    def test_opkg_and_apk_running_update_restarts_with_identical_configuration(self):
        before, old_binary = self.old_running()
        for manager in ('opkg', 'apk'):
            with self.subTest(manager=manager):
                (self.root / 'calls').write_text('')
                result = self.invoke_main('--action', 'update', RUN_PACKAGES='1', PACKAGE_MANAGER=manager)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.config.read_bytes(), before)
                self.assertNotEqual(self.binary.read_bytes(), old_binary)
                self.assertFalse((self.root / 'stopped').exists())
                self.assertNotIn('EARLY_START', self.calls())
                self.assertLess(self.calls().index('ddnsto stop'), self.calls().index('ddnsto restart'))
                self.assertIn('ddnsto status', self.calls())

    def test_partial_package_failure_preserves_config_but_is_not_success(self):
        before, _ = self.old_running()
        for manager in ('opkg', 'apk'):
            with self.subTest(manager=manager):
                result = self.invoke_main('--action', 'update', RUN_PACKAGES='1',
                                          PACKAGE_MANAGER=manager, FAIL='package-install')
                self.assertEqual(result.returncode, 23, result.stderr)
                self.assertEqual(self.config.read_bytes(), before)
                self.assertIn('partial', result.stderr)
                self.assertNotIn('installation completed', result.stdout)

    def test_post_update_not_running_cannot_report_success(self):
        before, _ = self.old_running()
        result = self.invoke_main('--action', 'update', RUN_PACKAGES='1', FAIL='not-running')
        self.assertEqual(result.returncode, 13, result.stderr)
        self.assertIn('service restart failed', result.stderr)
        self.assertEqual(self.config.read_bytes(), before)
        self.assertNotIn('installation completed', result.stdout)


class AsusRunningUpgrade(unittest.TestCase):
    invoke = asus.AsusTransaction.invoke

    def test_old_version_fetches_before_stop_then_installs_and_starts(self):
        result, events, config = self.invoke(version='4.2.7')
        self.assertEqual(result.returncode, 0, result.stderr)
        for first, second in [('fetch', 'stop'), ('backup', 'stop'), ('stop', 'install'), ('install', 'start')]:
            self.assertLess(events.index(first), events.index(second))
        self.assertEqual(config['ddnsto_token'], 'same-token')
        self.assertEqual(config['ddnsto_feat_password'], 'keep-$()-secret')

    def test_old_version_download_failure_does_not_stop(self):
        result, events, _ = self.invoke(version='4.2.7', failure='download')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(events, ['fetch'])

    def test_old_version_install_or_start_failure_requests_recovery(self):
        for failure in ('install', 'start'):
            with self.subTest(failure=failure):
                result, events, config = self.invoke(version='4.2.7', failure=failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('restore', events)
                self.assertEqual(config['ddnsto_token'], 'same-token')
        # restore_plugin is a boundary stub here: this proves recovery is
        # requested, NOT that a real router's old process actually recovers.


class UnsupportedUpgrade(unittest.TestCase):
    def test_qnap_unraid_and_windows_do_not_enter_shell_upgrade(self):
        for platform in ('qnap', 'unraid', 'windows'):
            with self.subTest(platform=platform):
                result = subprocess.run(['sh', '-c',
                    f'. "{ROOT}/ddnsto/auto-install.sh"\n'
                    'detected_platform=$1\nddnsto_ensure_preflight', 'test', platform],
                    capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('E_PLATFORM', result.stderr)

    def test_docker_selection_does_not_migrate_running_native_install(self):
        result = subprocess.run(['sh', '-c',
            f'. "{ROOT}/ddnsto/auto-install.sh"\n'
            'detected_platform=linux; TOKEN=fixture; REQUESTED_METHOD=docker\n'
            'ddnsto_ensure_preflight'], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('E_METHOD', result.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
