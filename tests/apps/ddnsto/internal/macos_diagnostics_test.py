"""Private event diagnostics; platform and service boundaries stay in fixtures."""
from pathlib import Path
import unittest
import macos_behavior_test as macos


class MacDiagnostics(unittest.TestCase):
    setUp = macos.MacInstaller.setUp
    tool = macos.MacInstaller.tool
    run_script = macos.MacInstaller.run_script

    def log(self, result):
        paths = [line.removeprefix('脱敏诊断记录：') for line in result.stderr.splitlines()
                 if line.startswith('脱敏诊断记录：')]
        self.assertEqual(len(paths), 1, result.stderr)
        path = Path(paths[0])
        self.assertTrue(path.is_file())
        self.assertEqual(path.parent.parent, self.config)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
        text = path.read_text()
        for line in text.splitlines():
            self.assertRegex(line, r'^(stage=(checking|account|version|installing|starting|stable|rollback|recovery_failed)|error=E_EXECUTOR|exit_code=[0-9]+)$')
        self.assertEqual(text.count('exit_code='), 1, text)
        self.assertIn(f'exit_code={result.returncode}\n', text)
        return path, text

    def test_install_and_start_have_separate_private_retained_logs(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        first, text = self.log(result)
        self.assertIn('stage=installing\n', text)
        self.assertIn('stage=starting\n', text)
        self.assertIn('stage=stable\n', text)
        result = self.run_script(FAIL_DOWNLOAD='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        second, text = self.log(result)
        self.assertNotEqual(first, second)
        self.assertTrue(first.is_file())
        self.assertIn('stage=starting\n', text)
        self.assertNotIn('stage=installing\n', text)

    def test_download_failure_logs_only_fixed_events_and_exit_code(self):
        native = (self.bin / 'zsetup').read_text()
        self.tool('zsetup', '''
if [ "$1" = download ]; then
 printf 'RAW-ERROR private-token userToken: secret-config\\n' >&2
 exit 11
fi
''' + native)
        result = self.run_script(('--token', 'private-token'))
        self.assertEqual(result.returncode, 11, result.stderr)
        _, text = self.log(result)
        self.assertIn('error=E_EXECUTOR\n', text)
        self.assertIn('stage=installing\n', text)
        self.assertNotIn('private-token', text)
        self.assertNotIn('RAW-ERROR', text)
        self.assertNotIn('secret-config', text)
        self.assertNotIn('private-token', result.stdout + result.stderr)
        self.assertNotIn('RAW-ERROR', result.stdout + result.stderr)

    def test_account_rejection_gets_diagnostics_without_credentials(self):
        self.assertEqual(self.run_script().returncode, 0)
        result = self.run_script(('--token', 'foreign-private-token'))
        self.assertNotEqual(result.returncode, 0)
        _, text = self.log(result)
        self.assertIn('stage=account\n', text)
        self.assertNotIn('foreign-private-token', text)
        self.assertNotIn('test-token', text)

    def test_start_failure_log_survives_rollback(self):
        result = self.run_script(FAIL_START='1')
        self.assertNotEqual(result.returncode, 0)
        _, text = self.log(result)
        self.assertIn('stage=rollback\n', text)
        self.assertNotIn('stage=stable\n', text)
        self.assertFalse((self.install / 'ddnsto').exists())

    def test_unsafe_parent_reports_no_log_and_does_not_write(self):
        self.root.chmod(0o777)
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('未建立私有诊断记录', result.stderr)
        self.assertNotIn('脱敏诊断记录：', result.stderr)
        self.assertFalse(self.config.exists())

    def test_advanced_status_does_not_create_diagnostics(self):
        result = self.run_script(('--action', 'status'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('脱敏诊断记录：', result.stderr)
        self.assertFalse(self.config.exists())

    def test_signal_preserves_exit_code_and_diagnostic_file(self):
        native = (self.bin / 'zsetup').read_text()
        self.tool('zsetup', '''
if [ "$1" = download ]; then kill -TERM "$PPID"; exit 0; fi
''' + native)
        result = self.run_script()
        self.assertEqual(result.returncode, 143, result.stderr)
        self.log(result)

    def test_log_creation_failure_does_not_start_service(self):
        self.tool('mktemp', 'exit 1\n')
        result = self.run_script()
        self.assertEqual(result.returncode, 12, result.stderr)
        self.assertIn('未建立私有诊断记录', result.stderr)
        self.assertNotIn('脱敏诊断记录：', result.stderr)
        self.assertFalse((self.root / 'service.log').exists())

    def test_inherited_diagnostic_path_is_never_reused(self):
        target = self.root / 'unrelated.log'
        target.write_text('keep')
        result = self.run_script(diagnostic_path=str(target), DDNSTO_FLOW_DIR=str(self.root))
        self.assertEqual(result.returncode, 0, result.stderr)
        path, _ = self.log(result)
        self.assertNotEqual(path, target)
        self.assertEqual(target.read_text(), 'keep')

    def test_failed_recovery_has_one_final_exit_record(self):
        launchctl = (self.bin / 'launchctl').read_text()
        self.tool('launchctl', '''
if [ "$1" = kickstart ]; then exit 9; fi
if [ "$1" = bootout ]; then exit 9; fi
''' + launchctl)
        result = self.run_script()
        self.assertEqual(result.returncode, 1, result.stderr)
        _, text = self.log(result)
        self.assertIn('stage=recovery_failed\n', text)

    def test_bootstrap_raw_errors_are_not_diagnostics(self):
        self.env['ZSETUP_BIN'] = ''
        self.tool('curl', "printf 'RAW-BOOTSTRAP private-token\\n' >&2; exit 7\n")
        result = self.run_script(('--token', 'private-token'))
        self.assertEqual(result.returncode, 11, result.stderr)
        _, text = self.log(result)
        self.assertNotIn('RAW-BOOTSTRAP', text + result.stdout + result.stderr)
        self.assertNotIn('private-token', text + result.stdout + result.stderr)

    def test_native_version_raw_errors_are_not_diagnostics(self):
        self.tool('zsetup', "printf 'RAW-VERSION private-token\\n' >&2; exit 7\n")
        result = self.run_script(('--token', 'private-token'))
        self.assertNotEqual(result.returncode, 0)
        _, text = self.log(result)
        self.assertNotIn('RAW-VERSION', text + result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
