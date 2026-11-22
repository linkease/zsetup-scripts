#!/usr/bin/env python3
"""Current Linux service adapter tests; never touch the host service manager."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

HARNESS = r'''
set -u
ddnsto_error() { printf '%s\n' "$1" >&2; }
ddnsto_privileged() { "$@"; }
id() { [ "${1:-}" = -u ] && { printf 0; return; }; command id "$@"; }
systemctl() {
    printf 'systemctl %s\n' "$*" >> "$TEST_LOG"
    case "$1" in
        show-environment) [ "${NO_MANAGER:-0}" = 0 ] ;;
        is-active) [ -f "$SERVICE_ACTIVE" ] ;;
        stop) [ "${STOP_BROKEN:-0}" = 0 ] || return 25; rm -f "$SERVICE_ACTIVE" "$LINUX_CONFIG_DIR/.ddnsto_http_addr.json" ;;
        *) return 1 ;;
    esac
}
readlink() {
    case "$1" in
        /proc/111/exe) [ "${WRONG_PID:-0}" = 0 ] && printf '%s\n' "$BIN_PATH" || printf '%s\n' /unrelated-program ;;
        *) command readlink "$@" ;;
    esac
}
curl() {
    printf 'curl %s\n' "$*" >> "$TEST_LOG"
    [ "${HEALTH_BROKEN:-0}" = 0 ] && printf ok
}
wget() { curl "$@"; }
sleep() { :; }
. "$CLI"
. "$SERVICE"
linux_service_name=com.linkease.ddnstoshell
linux_service_manager=systemd
linux_config_dir=$LINUX_CONFIG_DIR
linux_config_file=$LINUX_CONFIG_DIR/ddnsto-config.json
bin_path=$BIN_PATH
export SERVICE_ACTIVE LINUX_CONFIG_DIR BIN_PATH RECOVERY_BROKEN
eval "$TEST_BODY"
'''


class LinuxService(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='ddnsto-linux-service-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.config_dir = self.root / 'config'
        self.config_dir.mkdir()
        self.binary = self.root / 'ddnsto'
        self.binary.write_text('#!/bin/sh\nexit 0\n')
        self.binary.chmod(0o755)
        self.active = self.root / 'active'
        self.log = self.root / 'calls'
        self.env = os.environ | {
            'CLI': str(ROOT / 'managed-cli.sh'),
            'SERVICE': str(ROOT / 'linux-service.sh'),
            'LINUX_CONFIG_DIR': str(self.config_dir),
            'BIN_PATH': str(self.binary),
            'SERVICE_ACTIVE': str(self.active),
            'TEST_LOG': str(self.log),
            'RECOVERY_BROKEN': '0',
        }

    def healthy_state(self):
        self.active.touch()
        (self.config_dir / '.ddnsto_http_addr.json').write_text(
            '{"addr":"127.0.0.1:18334","pid":111,"startedAt":"fixture"}')

    def run_body(self, body, **env):
        return subprocess.run(
            ['sh', '-eu', '-c', HARNESS], env=self.env | env | {'TEST_BODY': body},
            capture_output=True, text=True, timeout=10)

    def test_preflight_accepts_running_systemd(self):
        result = self.run_body('ddnsto_linux_preflight; printf "%s" "$linux_service_manager"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'systemd')

    def test_preflight_rejects_missing_manager_without_mutation(self):
        result = self.run_body('ddnsto_linux_preflight', NO_MANAGER='1')
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn('systemd', result.stderr)
        self.assertFalse(self.active.exists())

    def test_healthy_service_checks_discovered_local_address(self):
        self.healthy_state()
        result = self.run_body('ddnsto_linux_wait_healthy')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('http://127.0.0.1:18334/healthz', self.log.read_text())

    def test_other_process_health_does_not_count_as_success(self):
        self.healthy_state()
        result = self.run_body('ddnsto_linux_wait_healthy', WRONG_PID='1')
        self.assertEqual(result.returncode, 13, result.stderr)
        self.assertIn('health check failed', result.stderr)

    def test_failed_health_endpoint_does_not_count_as_success(self):
        self.healthy_state()
        result = self.run_body('ddnsto_linux_wait_healthy', HEALTH_BROKEN='1')
        self.assertEqual(result.returncode, 13, result.stderr)

    def test_stop_error_is_propagated(self):
        self.healthy_state()
        result = self.run_body('ddnsto_linux_stop', STOP_BROKEN='1')
        self.assertEqual(result.returncode, 25, result.stderr)
        self.assertTrue(self.active.exists())

    def test_restore_reinstates_binary_config_and_healthy_service(self):
        backup = self.root / 'backup'
        backup.mkdir()
        restored = '''#!/bin/sh
[ "${RECOVERY_BROKEN:-0}" = 0 ] || exit 0
touch "$SERVICE_ACTIVE"
printf '%s' '{"addr":"127.0.0.1:18334","pid":111,"startedAt":"fixture"}' > "$LINUX_CONFIG_DIR/.ddnsto_http_addr.json"
'''
        (backup / 'binary').write_text(restored)
        (backup / 'binary').chmod(0o755)
        (backup / 'config').write_text('retained-token')
        (self.config_dir / 'ddnsto-config.json').write_text('candidate-token')
        self.healthy_state()
        body = f'backup={backup}; had_old=1; had_config=1; replacement_started=1; ddnsto_linux_restore'
        result = self.run_body(body)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.binary.read_text(), restored)
        self.assertEqual((self.config_dir / 'ddnsto-config.json').read_text(), 'retained-token')
        self.assertTrue(self.active.exists())

    def test_failed_recovery_keeps_reviewed_backup(self):
        backup = self.root / 'backup'
        backup.mkdir()
        (backup / 'binary').write_text('#!/bin/sh\nexit 0\n')
        (backup / 'binary').chmod(0o755)
        (backup / 'config').write_text('retained-token')
        (self.config_dir / 'ddnsto-config.json').write_text('candidate-token')
        self.healthy_state()
        body = f'backup={backup}; had_old=1; had_config=1; replacement_started=1; ddnsto_linux_restore'
        result = self.run_body(body, RECOVERY_BROKEN='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((backup / 'binary').exists())
        self.assertTrue((backup / 'config').exists())

    def test_current_product_identity_is_fixed(self):
        script = '. "$1"; printf "%s %s" "$(ddnsto_pinned_version standard linux)" "$(ddnsto_pinned_sha linux-binary/ddnsto-standard-4.2.8.tar.gz)"'
        result = subprocess.run(['sh', '-eu', '-c', script, 'test', str(ROOT / 'product-pins.sh')],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '4.2.8 3bf7ada14448b5aa04afa171e497f85d0b8bb4adcf2209991e52ef5826d4e975')


if __name__ == '__main__':
    unittest.main()
