"""Windows environment contract; executable PowerShell fixtures are optional."""
from pathlib import Path
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'ddnsto/templates/install.ps1.in'


class WindowsEnvironmentContract(unittest.TestCase):
    def test_legacy_without_record_defaults_to_production(self):
        source = SOURCE.read_text(encoding='utf-8-sig')
        guard = source.split('function Assert-DDNSTOBusinessEnvironment(', 1)[1].split('function Set-DDNSTOBusinessEnvironment', 1)[0]
        missing = guard.split('if (-not $current) {', 1)[1].split('if ($current -cne', 1)[0]
        self.assertNotIn('Test-Path', missing)
        self.assertIn("$current = 'production'", missing)
        self.assertNotIn('Stop-DDNSTOError', missing)

    def test_public_entry_and_core_forward_environment(self):
        source = SOURCE.read_text(encoding='utf-8-sig')
        self.assertGreaterEqual(source.count("[ValidateSet('production', 'test')][string]$Environment = 'production'"), 4)
        self.assertIn('-Environment $Environment -SwitchEnvironment:$SwitchEnvironment', source)

    def test_task_uses_process_scoped_assignment_not_policy_override(self):
        source = SOURCE.read_text(encoding='utf-8-sig')
        self.assertIn('function Get-DDNSTOEnvironmentAction', source)
        self.assertIn('DDNSTO_TEST_SERVER_ASSIGNMENT_JSON', source)
        self.assertIn('-NoProfile -NonInteractive -EncodedCommand ', source)
        self.assertNotIn('-ExecutionPolicy Bypass', source)
        self.assertNotIn('[EnvironmentVariableTarget]::Machine', source)

    def test_unknown_and_mismatch_fail_closed(self):
        source = SOURCE.read_text(encoding='utf-8-sig')
        self.assertIn('E_ENV_UNKNOWN', source)
        self.assertIn('E_ENV_MISMATCH', source)
        self.assertIn('E_ENV_SWITCH_ACTION', source)
        self.assertIn('old-identity', source)

    def test_environment_guard_does_not_require_full_yaml_validation(self):
        source = SOURCE.read_text(encoding='utf-8-sig')
        guard = source.split('function Assert-DDNSTOBusinessEnvironment(', 1)[1].split('function Set-DDNSTOBusinessEnvironment', 1)[0]
        self.assertNotIn('$keys', guard)
        self.assertNotIn('-cnotmatch', guard)

    def test_rejects_custom_boot_paths_before_lock(self):
        source = SOURCE.read_text(encoding='utf-8-sig')
        self.assertIn('publicWssURLs|bootConfigPath', source)
        install = source.split('function Invoke-DDNSTOInstall {', 1)[1]
        self.assertLess(install.index('Assert-DDNSTOBusinessEnvironment'), install.index("'.install-lock'"))
        self.assertIn("if (Get-DDNSTOTask) { $null = Assert-DDNSTOManagedTask $InstallDir }", source)

    def test_stop_checks_exact_child_path_before_return(self):
        source = SOURCE.read_text(encoding='utf-8-sig')
        stop = source.split('function Stop-DDNSTOTask {', 1)[1].split('function Remove-DDNSTOTask', 1)[0]
        self.assertIn('Get-CimInstance', stop)
        self.assertIn('ExecutablePath, $binary', stop)
        self.assertIn('$clients.Count -eq 0', stop)
        self.assertNotIn('Stop-Process', stop)

    def test_existing_task_fixtures_distinguish_launcher_and_client(self):
        default = (ROOT / 'ddnsto/tests/windows_default_test.ps1').read_text(encoding='utf-8-sig')
        self.assertIn('New-DDNSTOFixtureAction', default)
        self.assertNotIn('ExecutablePath=$script:task.Actions[0].Execute', default)

    @unittest.skipUnless(shutil.which('pwsh'), 'PowerShell runtime unavailable; not a behavior pass')
    def test_executable_environment_fixture(self):
        result = subprocess.run(['pwsh', '-NoProfile', '-File', str(ROOT / 'ddnsto/tests/windows_environment_test.ps1')], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
