"""Entry routing without any host service or Docker mutation."""
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = '. "$BUSINESS"\n' + (ROOT / 'main.sh').read_text().removesuffix('main "$@"\n') + r'''
ddnsto_local_platform() { detected_platform=$TEST_PLATFORM; }
ddnsto_offer_install_method() { :; }
id() { printf 0; }
ddnsto_with_operation_lock() { printf 'LOCK\n'; "$@"; }
ddnsto_docker_lifecycle() { printf 'DOCKER %s %s %s\n' "$ACTION" "$DEVICE_NAME" "$NETWORK"; }
ddnsto_docker_plan() { printf 'DOCKER_PLAN\n'; }
ddnsto_linux_lifecycle() { printf 'LINUX %s\n' "$ACTION"; }
ddnsto_openwrt_lifecycle() { printf 'OPENWRT %s\n' "$ACTION"; }
ddnsto_manage_service() { printf 'SERVICE %s\n' "$ACTION"; }
ddnsto_plan() { printf 'NATIVE_PLAN\n'; }
bootstrap_and_run() { printf 'UNEXPECTED_BOOTSTRAP\n'; return 99; }
status() { :; }
main "$@"
'''


class EntryDispatch(unittest.TestCase):
    def test_help_lists_candidate_actions_and_limits(self):
        r = self.invoke('--help')
        self.assertEqual(r.returncode, 0)
        for action in ['repair', 'configure', 'uninstall', 'download', '--device-name', '--network']:
            self.assertIn(action, r.stdout)
        self.assertIn('manual', r.stdout)

    def invoke(self, *args, platform='linux'):
        return subprocess.run(['sh', '-eu', '-c', SCRIPT, 'entry', *args],
            env=dict(os.environ, BUSINESS=str(ROOT / 'business.sh'), TEST_PLATFORM=platform),
            text=True, capture_output=True)

    def test_explicit_docker_install_is_not_native_or_bootstrap(self):
        r = self.invoke('--method', 'docker', '--device-name', 'test', '--network', 'bridge', '--token', 'fixture')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, 'LOCK\nDOCKER install test bridge\n')

    def test_docker_plan_and_status_do_not_lock(self):
        for args, expected in [(('--plan',), 'DOCKER_PLAN\n'), (('--action', 'status'), 'DOCKER status  \n')]:
            r = self.invoke('--method', 'docker', *args)
            self.assertEqual((r.returncode, r.stdout), (0, expected), r.stderr)

    def test_native_lifecycle_remains_offline(self):
        for platform in ['linux', 'openwrt']:
            for action in ['repair', 'configure', 'uninstall']:
                args = ('--token', 'fixture') if action == 'configure' else ()
                r = self.invoke('--action', action, *args, platform=platform)
                self.assertEqual((r.returncode, r.stdout), (0, f'LOCK\n{platform.upper()} {action}\n'), r.stderr)

    def test_docker_fields_and_download_options_cannot_be_ignored_by_native(self):
        for args in [('--network', 'host'), ('--device-name', 'test'), ('--action', 'status', '--output-dir', '/tmp/example')]:
            r = self.invoke(*args)
            self.assertEqual(r.returncode, 2, r.stderr)
            self.assertEqual(r.stdout, '')

    def test_menu_action_revalidates_installation_options(self):
        script = SCRIPT.rsplit('main "$@"', 1)[0] + '''
ddnsto_existing_policy() { INSTALL_SKIPPED=0; ACTION=repair; }
main "$@"
'''
        r = subprocess.run(['sh', '-eu', '-c', script, 'entry', '--force-version', 'standard'],
            env=dict(os.environ, BUSINESS=str(ROOT / 'business.sh'), TEST_PLATFORM='linux', ZSETUP_INSTALLER_MODE='0'),
            text=True, capture_output=True)
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertNotIn('LOCK', r.stdout)
        self.assertNotIn('UNEXPECTED_BOOTSTRAP', r.stdout)


if __name__ == '__main__':
    unittest.main()
