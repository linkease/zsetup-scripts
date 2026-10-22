#!/usr/bin/env python3
"""Real installer transactions; replace only downloads and OS service boundaries."""
import io
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BINARY = '''#!/bin/sh
case "${1:-}" in
  -v) echo VERSION; exit 0 ;;
  stop|uninstall) exit 0 ;;
esac
[ "${1:-}" != -u ] || printf 'new-token' > "$DDNSTO_LINUX_CONFIG_DIR/ddnsto-config.json"
if [ "VERSION" = new ] && [ "${START_BROKEN:-0}" = 1 ]; then exit 0; fi
if [ "VERSION" = old ] && [ "${RECOVERY_BROKEN:-0}" = 1 ]; then exit 0; fi
touch "$SERVICE_ACTIVE"
printf '{"addr":"127.0.0.1:18334","pid":111,"startedAt":"fixture"}' > "$DDNSTO_LINUX_CONFIG_DIR/.ddnsto_http_addr.json"
'''
HARNESS = r'''
. "$BUSINESS"
[ ! -f "$PRODUCT_PINS" ] || . "$PRODUCT_PINS"
[ ! -f "$LINUX_SERVICE" ] || . "$LINUX_SERVICE"
status() { printf '%s\n' "$*" >&2; }
id() { printf 0; }
ddnsto_download() { printf 'download\n' >> "$TEST_LOG"; case "$1" in *SHA256SUMS) : > "$2" ;; *) cp "$ARCHIVE" "$2" ;; esac; }
ddnsto_checksum() { printf '%064d' 0; }
systemctl() {
  printf 'systemctl %s\n' "$*" >> "$TEST_LOG"
  case "$1" in
    show-environment) [ "${NO_MANAGER:-0}" = 0 ] ;;
    is-active) test -f "$SERVICE_ACTIVE" ;;
    stop) [ "${STOP_BROKEN:-0}" = 0 ] || return 25; rm -f "$SERVICE_ACTIVE" "$DDNSTO_LINUX_CONFIG_DIR/.ddnsto_http_addr.json" ;;
    *) return 1 ;;
  esac
}
readlink() {
  case "$*" in
    /proc/111/exe) [ "${WRONG_PID:-0}" = 0 ] && printf '%s' "$DDNSTO_BIN_PATH" || printf '/unrelated-program' ;;
    *) command readlink "$@" ;;
  esac
}
curl() { printf 'health %s\n' "$*" >> "$TEST_LOG"; [ "${HEALTH_BROKEN:-0}" = 0 ] && printf ok; }
wget() { curl "$@"; }
sleep() { :; }
if [ "${TEST_ACTION:-update}" = install ]; then
    ddnsto_install --token fixture-token
elif [ "${TEST_ACTION:-update}" = retainedinstall ]; then
    # Retained reinstall must never receive a credential or prompt for one.
    ddnsto_prompt_token() { printf 'unexpected Token prompt\n' >&2; return 2; }
    ddnsto_install --action install
else
    ddnsto_install --action update
fi
'''


class LinuxService(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='ddnsto-linux-service-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / 'bin').mkdir()
        (self.root / 'config').mkdir()
        self.binary = self.root / 'bin/ddnsto'
        self.config = self.root / 'config/ddnsto-config.json'
        self.config.write_text('old-token')
        self.config.chmod(0o600)
        self.old = BINARY.replace('VERSION', 'old')
        self.binary.write_text(self.old)
        self.binary.chmod(0o755)
        (self.root / 'active').touch()
        archive = self.root / 'archive.tar.gz'
        payload = BINARY.replace('VERSION', 'new').encode()
        with tarfile.open(archive, 'w:gz') as tar:
            member = tarfile.TarInfo('ddnsto-standard-4.2.3/ddnsto.x86_64')
            member.size = len(payload)
            tar.addfile(member, io.BytesIO(payload))
        self.env = os.environ | {
            'BUSINESS': str(ROOT / 'business.sh'), 'LINUX_SERVICE': str(ROOT / 'linux-service.sh'),
            'PRODUCT_PINS': str(ROOT / 'product-pins.sh'),
            'ZSETUP_BIN': '/unused-native', 'ZSETUP_OS': 'linux', 'ZSETUP_ARCH': 'x86_64',
            'ZSETUP_PACKAGE_MANAGER': 'unknown', 'ZSETUP_SOURCE_BASES': 'https://fixture.invalid',
            'ZSETUP_WORK_DIR': str(self.root / 'work'), 'DDNSTO_BIN_PATH': str(self.binary),
            'DDNSTO_LINUX_CONFIG_DIR': str(self.root / 'config'), 'ARCHIVE': str(archive),
            'SERVICE_ACTIVE': str(self.root / 'active'), 'TEST_LOG': str(self.root / 'log'),
            'DDNSTO_LOCK_DIR': str(self.root / 'installer.lock'),
        }

    def run_install(self, **env):
        lock = self.root / 'installer.lock'
        had_lock = lock.exists()
        result = subprocess.run(['sh', '-eu', '-c', HARNESS], env=self.env | env,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(lock.exists(), had_lock, 'leaked lock or removed foreign lock')
        return result

    def test_missing_manager_rejected_before_download_or_replace(self):
        result = self.run_install(NO_MANAGER='1')
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.binary.read_text(), self.old)
        self.assertNotIn('download', (self.root / 'log').read_text())

    def test_busy_management_lock_rejects_update_before_download(self):
        lock = self.root / 'installer.lock'
        lock.mkdir()
        result = self.run_install()
        self.assertEqual(result.returncode, 16, result.stderr)
        self.assertTrue(lock.exists())
        self.assertFalse((self.root / 'log').exists())
        self.assertEqual(self.binary.read_text(), self.old)

    def test_unpinned_linux_version_rejected_before_download_or_replace(self):
        result = self.run_install(DDNSTO_VERSION='9.9.9')
        self.assertEqual(result.returncode, 11, result.stderr)
        self.assertEqual(self.binary.read_text(), self.old)
        self.assertNotIn('download', (self.root / 'log').read_text())

    def test_false_success_restores_binary_and_original_token(self):
        result = self.run_install(START_BROKEN='1')
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.binary.read_text(), self.old)
        self.assertEqual(self.config.read_text(), 'old-token')
        self.assertNotIn('DDNSTO installed;', result.stderr)
        self.assertTrue((self.root / 'active').exists(), 'old service must restart')

    def test_first_install_false_success_removes_failed_candidate(self):
        self.binary.unlink()
        self.config.unlink()
        (self.root / 'active').unlink()
        result = self.run_install(START_BROKEN='1', TEST_ACTION='install')
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.binary.exists())
        self.assertFalse(self.config.exists())

    def test_healthy_service_checks_discovered_address(self):
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('local_service=healthy', result.stderr)
        self.assertIn('http://127.0.0.1:18334/healthz', (self.root / 'log').read_text())
        self.assertIn('cloud_status=unverified', result.stderr)
        self.assertEqual(self.config.read_text(), 'old-token', 'update must not pass -u or overwrite configuration')
        self.assertFalse(list(self.binary.parent.glob('.ddnsto-backup.*')))

    def test_retained_install_without_token_preserves_config_and_identity(self):
        self.binary.unlink()
        (self.root / 'active').unlink()
        # Exercise the complete install transaction, starting from uninstall's
        # persisted state, rather than just checking the existing-policy flag.
        config_bytes = b'{\r\n  "token": "retained-token", "routeridx": 7,\r\n  "custom": {"preserve": true}\r\n}\r\n'
        self.config.write_bytes(config_bytes)
        identity = self.config.parent / '.ddnsto_boot.cfg'
        identity_bytes = b'retained-device-identity\x00\r\n'
        identity.write_bytes(identity_bytes)
        retained = self.config.parent / '.uninstalled-linux-v1'
        installed = self.config.parent / '.installer-linux-v1'
        marker_bytes = f'ddnsto-linux-v1\n{self.binary}\n{self.config}\n'.encode()
        retained.write_bytes(marker_bytes)

        result = self.run_install(TEST_ACTION='retainedinstall')

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.binary.read_text(), BINARY.replace('VERSION', 'new'))
        self.assertTrue((self.root / 'active').exists())
        self.assertIn('local_service=healthy', result.stderr)
        self.assertIn('cloud_status=unverified', result.stderr)
        self.assertEqual(self.config.read_bytes(), config_bytes)
        self.assertEqual(identity.read_bytes(), identity_bytes)
        self.assertEqual(installed.read_bytes(), marker_bytes)
        self.assertFalse(retained.exists())
        self.assertIn('download', (self.root / 'log').read_text())
        self.assertIn('http://127.0.0.1:18334/healthz', (self.root / 'log').read_text())
        self.assertFalse(list(self.binary.parent.glob('.ddnsto-backup.*')))
        self.assertNotIn('retained-token', result.stdout + result.stderr)

    def test_other_process_health_does_not_count_as_success(self):
        result = self.run_install(WRONG_PID='1')
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('DDNSTO installed;', result.stderr)

    def test_health_failure_does_not_count_as_success(self):
        result = self.run_install(HEALTH_BROKEN='1')
        self.assertNotEqual(result.returncode, 0, result.stderr)

    def test_stop_error_cannot_be_hidden_by_old_client_exit_zero(self):
        result = self.run_install(STOP_BROKEN='1')
        self.assertEqual(result.returncode, 25, result.stderr)
        self.assertEqual(self.binary.read_text(), self.old)

    def test_failed_recovery_keeps_backup_and_reports_manual_action(self):
        result = self.run_install(START_BROKEN='1', RECOVERY_BROKEN='1')
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertTrue(list(self.binary.parent.glob('.ddnsto-backup.*')))
        self.assertIn('manual recovery', result.stderr)


if __name__ == '__main__':
    unittest.main()
