"""Entry routing without any host service or Docker mutation."""
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = '. "$BUSINESS"\n. "$CLI"\n. "$LAUNCHER"\n' + (ROOT / 'main.sh').read_text().removesuffix('main "$@"\n') + r'''
ddnsto_local_platform() { detected_platform=$TEST_PLATFORM; }
ddnsto_business_environment_preflight() { :; }
id() { printf 0; }
ddnsto_machine_locked() { printf 'LOCK\n'; "$@"; }
ddnsto_docker_locked() { printf 'LOCK\n'; ddnsto_docker_lifecycle; }
ddnsto_docker_lifecycle() { printf 'DOCKER %s %s %s\n' "$ACTION" "$DEVICE_NAME" "$NETWORK"; }
ddnsto_docker_plan() { printf 'DOCKER_PLAN\n'; }
ddnsto_managed_native() { :; }
ddnsto_managed_action() { printf 'LOCK\nLINUX %s\n' "$ACTION"; }
ddnsto_openwrt_local() { printf 'OPENWRT %s\n' "$ACTION"; }
ddnsto_ensure_entry() { printf 'ENSURE\n'; }
ddnsto_plan() { printf 'NATIVE_PLAN\n'; }
bootstrap_and_run() { printf 'UNEXPECTED_BOOTSTRAP\n'; return 99; }
status() { :; }
main "$@"
'''


class EntryDispatch(unittest.TestCase):
    def test_help_lists_candidate_actions_and_limits(self):
        r = self.invoke('--help')
        self.assertEqual(r.returncode, 0)
        for action in ['ensure', 'repair', 'configure', 'uninstall', 'download', '--env']:
            self.assertIn(action, r.stdout)
        self.assertIn('manual', r.stdout)
        self.assertIn('Docker: explicit selection only', r.stdout)

    def invoke(self, *args, platform='linux'):
        return subprocess.run(['sh', '-eu', '-c', SCRIPT, 'entry', *args],
            env=dict(os.environ, BUSINESS=str(ROOT / 'business.sh'), CLI=str(ROOT / 'managed-cli.sh'),
                     LAUNCHER=str(ROOT.parent / 'lib/install-launcher.sh'), TEST_PLATFORM=platform),
            text=True, capture_output=True)

    def test_explicit_docker_install_is_not_native_or_bootstrap(self):
        r = self.invoke('--action', 'install', '--method', 'docker', '--device-name', 'test', '--network', 'bridge', '--token', 'fixture')
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

    def test_default_action_routes_to_current_ensure_entry(self):
        r = self.invoke('--token', 'fixture')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, 'ENSURE\n')
        self.assertNotIn('UNEXPECTED_BOOTSTRAP', r.stdout)


if __name__ == '__main__':
    unittest.main()
