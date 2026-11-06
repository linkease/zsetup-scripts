"""OpenWrt adapter tests: package/init/UCI fixtures, never host services."""
import os
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'ddnsto/tests'))
import openwrt_lifecycle_test as fixtures

ORIGINAL = fixtures.ORIGINAL


class Adapter(unittest.TestCase):
    setUp = fixtures.OpenWrtLifecycleTests.setUp
    calls = fixtures.OpenWrtLifecycleTests.calls

    def invoke(self, action, fail=''):
        script = '\n'.join('. "' + str(ROOT / p) + '"' for p in (
            'ddnsto/business.sh', 'ddnsto/managed-cli.sh',
            'ddnsto/openwrt-lifecycle.sh', 'ddnsto/openwrt-adapter.sh'))
        script += '''
binary=$DDNSTO_OPENWRT_BIN_PATH; config=$DDNSTO_CONFIG_PATH
service_path=$DDNSTO_SERVICE_PATH; package_manager=opkg
TOKEN=; VERIFY_STATUS=0
ddnsto_bootstrap_safe_ancestors() { return 0; }
sleep() { :; }
if [ "$ACTION" = update ]; then
    ddnsto_openwrt_apply_packages() { pinned-reinstall; }
    ddnsto_openwrt_apply
else
    ddnsto_openwrt_local
fi
'''
        return subprocess.run(['sh', '-eu', '-c', script], text=True,
            capture_output=True, env=dict(os.environ, ACTION=action, FAIL=fail,
                PATH=str(self.tools) + ':' + os.environ['PATH'], FIXTURE=str(self.root),
                DDNSTO_OPENWRT_BIN_PATH=str(self.binary),
                DDNSTO_CONFIG_PATH=str(self.config), DDNSTO_SERVICE_PATH=str(self.service)))

    def test_status_does_not_require_native_or_mutate(self):
        result = self.invoke('status')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('local_service=running', result.stdout)
        self.assertEqual(self.config.read_text(), ORIGINAL)
        self.assertNotIn('uci-command', self.calls())

    def test_update_preserves_config_even_when_package_hook_replaces_it(self):
        for enabled in ('0', '1'):
            original = ORIGINAL.replace("enabled '0'", "enabled '" + enabled + "'")
            self.config.write_text(original)
            result = self.invoke('update')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.config.read_text(), original)
            self.assertEqual((self.root / 'stopped').exists(), enabled == '0')

    def test_failed_update_retains_config_and_reports_partial_packages(self):
        result = self.invoke('update', 'callback')
        self.assertEqual(result.returncode, 9, result.stderr)
        self.assertEqual(self.config.read_text(), ORIGINAL)
        self.assertIn('partial', result.stderr)

    def test_start_stop_restart_preserve_identity(self):
        for action in ('start', 'stop', 'restart'):
            result = self.invoke(action)
            self.assertEqual(result.returncode, 0, result.stderr)
            expected = ORIGINAL.replace("enabled '0'", "enabled '" + ('0' if action == 'stop' else '1') + "'")
            self.assertEqual(self.config.read_text(), expected)
            self.assertEqual((self.root / 'stopped').exists(), action == 'stop')

    def test_repeated_install_refuses_before_package_mutation(self):
        result = self.invoke('install')
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.config.read_text(), ORIGINAL)


if __name__ == '__main__':
    unittest.main()
