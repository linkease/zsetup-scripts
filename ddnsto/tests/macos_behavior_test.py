#!/usr/bin/env python3
"""Execute the installer with isolated native-download/launchd boundaries."""
import os
from pathlib import Path
import plistlib
import pty
import select
import time
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'install-macos.sh'


class MacInstaller(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.install = self.root / 'install'
        self.config = self.root / 'config & data'
        self.agents = self.root / 'agents'
        self.env = os.environ | {
            'PATH': str(self.bin) + ':' + os.environ['PATH'],
            'DDNSTO_INSTALL_DIR': str(self.install), 'DDNSTO_CONFIG_DIR': str(self.config),
            'DDNSTO_LAUNCH_AGENTS_DIR': str(self.agents), 'TEST_ROOT': str(self.root),
            'ZSETUP_BIN': str(self.bin / 'zsetup'),
            'TMPDIR': str(self.root),
        }
        self.tool('uname', 'echo "${TEST_OS:-Darwin}"\n')
        # uname -m needs its architecture; all other native platform probes are isolated.
        self.tool('uname', '[ "$1" != -m ] || { echo "${TEST_ARCH:-arm64}"; exit; }; echo "${TEST_OS:-Darwin}"\n')
        self.tool('zsetup', '''
[ "$1" != --version ] || { echo 'zsetup 0.3.0'; exit; }
printf 'download\n' >> "$TEST_ROOT/download.log"
[ "${FAIL_DOWNLOAD:-0}" = 0 ] || exit 11
while [ "$#" -gt 0 ]; do
 if [ "$1" = -o ]; then shift; dest=$1; fi
 shift
done
mkdir -p "$TEST_ROOT/payload"
printf 'new binary' > "$TEST_ROOT/payload/ddnsto_cli.arm64"
cp "$TEST_ROOT/payload/ddnsto_cli.arm64" "$TEST_ROOT/payload/ddnsto_cli.amd64"
tar -czf "$dest" -C "$TEST_ROOT/payload" ddnsto_cli.arm64 ddnsto_cli.amd64
''')
        self.tool('launchctl', '''
printf '%s\n' "$1" >> "$TEST_ROOT/service.log"
case "$1" in
print-disabled)
 [ "${FAIL_DISABLED_QUERY:-0}" = 0 ] || exit 7
 echo 'disabled services = {'
 echo ' "com.ddnsto.client.other" => disabled'
 if [ -f "$TEST_ROOT/disabled" ]; then
  printf ' "com.ddnsto.client" => %s\n' "${DISABLED_WORD:-disabled}"
 else
  echo ' "com.ddnsto.client" => enabled'
 fi
 echo '}' ;;
enable)
 [ "${FAIL_ENABLE:-0}" = 0 ] || exit 8
 rm -f "$TEST_ROOT/disabled" ;;
disable) touch "$TEST_ROOT/disabled" ;;
print)
 [ -f "$TEST_ROOT/running" ] || exit 1
 echo 'pid = 123'
 printf 'path = %s/com.ddnsto.client.plist\n' "$DDNSTO_LAUNCH_AGENTS_DIR"
 printf 'program = %s/ddnsto\n' "${FOREIGN_PROGRAM:-$DDNSTO_INSTALL_DIR}"
 printf '%s/ddnsto.yaml\n' "$DDNSTO_CONFIG_DIR" ;;
bootout)
 [ "${FAIL_BOOTOUT:-0}" = 0 ] || exit 9
 rm -f "$TEST_ROOT/running" ;;
bootstrap)
 [ -f "$3" ] || exit 4
 if [ -f "$TEST_ROOT/disabled" ]; then
  echo 'Bootstrap failed: 5: Input/output error' >&2; exit 5
 fi
 if [ "${FAIL_START:-0}" = 1 ] && [ ! -f "$TEST_ROOT/failed-once" ]; then
  touch "$TEST_ROOT/failed-once"; exit 9
 fi
 touch "$TEST_ROOT/running" ;;
kickstart) : ;;
esac
''')

    def tool(self, name, body):
        p = self.bin / name
        p.write_text('#!/bin/sh\nset -eu\n' + body)
        p.chmod(0o755)

    def run_script(self, args=('--token', 'test-token'), **env):
        return subprocess.run(['sh', str(SCRIPT), *args], env=self.env | env,
                              capture_output=True, text=True, timeout=20)

    def run_menu(self, choice, token=None, **env):
        pid, terminal = pty.fork()
        if pid == 0:
            os.execve('/bin/sh', ['sh', str(SCRIPT)], self.env | env)
        output = b''
        selected = entered = False
        deadline = time.monotonic() + 12
        try:
            while time.monotonic() < deadline:
                ready, _, _ = select.select([terminal], [], [], 0.1)
                if not ready:
                    continue
                try:
                    part = os.read(terminal, 8192)
                except OSError:
                    break
                if not part:
                    break
                output += part
                if b'Choose [0]:' in output and not selected:
                    os.write(terminal, (choice + '\n').encode())
                    selected = True
                if b'DDNSTO token:' in output and token is not None and not entered:
                    os.write(terminal, (token + '\n').encode())
                    entered = True
            else:
                os.kill(pid, 15)
                self.fail('interactive lifecycle timed out')
        finally:
            os.close(terminal)
            _, status = os.waitpid(pid, 0)
        return os.waitstatus_to_exitcode(status), output.decode()

    def test_menu_lists_all_actions_and_default_is_noop(self):
        self.assertEqual(self.run_script().returncode, 0)
        before = (self.root / 'service.log').read_bytes()
        for choice in ('', '0', 'invalid'):
            with self.subTest(choice=choice):
                code, output = self.run_menu(choice)
                self.assertEqual(code, 2 if choice == 'invalid' else 0, output)
                for item in ('2) Status', '3) Start', '4) Stop', '5) Restart',
                             '6) Repair', '7) Change Token', '8) Uninstall'):
                    self.assertIn(item, output)
                self.assertNotIn('DDNSTO token:', output)
                self.assertEqual((self.root / 'service.log').read_bytes(), before)

    def test_menu_dispatches_management_repair_and_uninstall_offline(self):
        self.assertEqual(self.run_script().returncode, 0)
        cfg = (self.config / 'ddnsto.yaml').read_bytes()
        downloads = (self.root / 'download.log').read_bytes()
        for choice, running in [('2', True), ('4', False), ('3', True),
                                ('5', True), ('6', True), ('8', False)]:
            with self.subTest(choice=choice):
                code, output = self.run_menu(choice, FAIL_DOWNLOAD='1')
                self.assertEqual(code, 0, output)
                self.assertEqual((self.root / 'running').exists(), running)
                self.assertNotIn('DDNSTO token:', output)
                self.assertEqual((self.config / 'ddnsto.yaml').read_bytes(), cfg)
                self.assertEqual((self.root / 'download.log').read_bytes(), downloads)
        self.assertFalse((self.install / 'ddnsto').exists())
        self.assertIn('retained', (self.config / '.installer-macos-v1').read_text())

    def test_menu_update_still_uses_explicit_update_transaction(self):
        self.assertEqual(self.run_script().returncode, 0)
        code, output = self.run_menu('1')
        self.assertEqual(code, 0, output)
        self.assertIn('operation=update', output)
        self.assertEqual((self.root / 'download.log').read_text().count('download'), 2)

    def test_menu_configure_prompts_visible_token_once(self):
        self.assertEqual(self.run_script().returncode, 0)
        identity = self.config / '.ddnsto_boot.cfg'
        identity.write_text('preserve-identity')
        code, output = self.run_menu('7', token='menu-visible-token', FAIL_DOWNLOAD='1')
        self.assertEqual(code, 0, output)
        self.assertEqual(output.count('menu-visible-token'), 1, output)
        self.assertIn('operation=configure', output)
        self.assertIn("userToken: 'menu-visible-token'", (self.config / 'ddnsto.yaml').read_text())
        self.assertEqual(identity.read_text(), 'preserve-identity')

    def test_menu_repairs_missing_plist_without_downloading(self):
        self.assertEqual(self.run_script().returncode, 0)
        plist = self.agents / 'com.ddnsto.client.plist'
        plist.unlink()
        code, output = self.run_menu('6', FAIL_DOWNLOAD='1')
        self.assertEqual(code, 0, output)
        self.assertTrue(plist.is_file())

    def test_menu_mutations_respect_existing_lock(self):
        self.assertEqual(self.run_script().returncode, 0)
        (self.config / '.install-lock').mkdir()
        before = (self.config / 'ddnsto.yaml').read_bytes()
        for choice in ('3', '4', '5', '6', '7', '8'):
            with self.subTest(choice=choice):
                code, output = self.run_menu(choice, token='unused-new-token')
                self.assertNotEqual(code, 0, output)
                self.assertTrue((self.config / '.install-lock').is_dir())
                self.assertTrue((self.root / 'running').exists())
                self.assertEqual((self.config / 'ddnsto.yaml').read_bytes(), before)

    def test_plist_program_duplicate_keys_and_foreign_workdir_are_rejected(self):
        self.assertEqual(self.run_script().returncode, 0)
        self.assertEqual(self.run_script(('--action', 'stop')).returncode, 0)
        plist = self.agents / 'com.ddnsto.client.plist'
        original = plist.read_text()
        mutations = [
            original.replace('<dict>', '<dict><key>Program</key><string>/foreign/program</string>'),
            original.replace('<dict>', '<dict><key>Label</key><string>foreign.label</string>'),
            original.replace('<key>WorkingDirectory</key>', '<key>ForeignDirectory</key>'),
            original.replace('</dict>', '<key>EnvironmentVariables</key><dict><key>X</key><string>Y</string></dict></dict>'),
        ]
        for content in mutations:
            plist.write_text(content)
            for action in ('start', 'repair', 'uninstall'):
                with self.subTest(action=action, content=content):
                    before = (self.root / 'service.log').read_bytes()
                    result = self.run_script(('--action', action))
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertEqual((self.root / 'service.log').read_bytes(), before)
                    self.assertEqual(plist.read_text(), content)

    def test_failed_rollback_stop_retains_backup_and_does_not_restore_live_files(self):
        self.assertEqual(self.run_script().returncode, 0)
        self.assertEqual(self.run_script(('--action', 'stop')).returncode, 0)
        old = (self.config / 'ddnsto.yaml').read_bytes()
        launchctl = (self.bin / 'launchctl').read_text()
        self.tool('launchctl', '''
if [ "$1" = kickstart ]; then touch "$TEST_ROOT/rollback"; exit 9; fi
if [ "$1" = bootout ] && [ -f "$TEST_ROOT/rollback" ]; then exit 9; fi
''' + launchctl)
        result = self.run_script(('--action', 'configure', '--token', 'new-token'))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('recovery incomplete', result.stderr)
        self.assertTrue((self.root / 'running').exists())
        self.assertIn("userToken: 'new-token'", (self.config / 'ddnsto.yaml').read_text())
        backups = list(self.root.glob('ddnsto.*/old-config'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), old)
        self.assertFalse((self.config / '.install-lock').exists())

    def test_retained_reinstall_signal_restores_retained_marker(self):
        self.assertEqual(self.run_script().returncode, 0)
        self.assertEqual(self.run_script(('--action', 'uninstall')).returncode, 0)
        marker = self.config / '.installer-macos-v1'
        before = marker.read_bytes()
        # Deliver TERM after the real marker write, before transaction commit.
        command = '''printf() {
 command printf "$@"
 if [ "${2:-}" = ddnsto-macos-v1 ]; then kill -TERM "$$"; fi
}
review_source=$1
shift
. "$review_source"
'''
        result = subprocess.run(['sh', '-c', command, 'fixture', str(SCRIPT)], env=self.env,
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 143, result.stderr)
        self.assertEqual(marker.read_bytes(), before)
        self.assertFalse((self.install / 'ddnsto').exists())
        self.assertIn('configuration=retained', self.run_script(('--action', 'status')).stdout)
        self.assertEqual(self.run_script(()).returncode, 0)

    def test_install_and_repeat_preserves_config_and_identity(self):
        first = self.run_script()
        self.assertEqual(first.returncode, 0, first.stderr)
        cfg = self.config / 'ddnsto.yaml'
        content = cfg.read_text() + 'routerName: custom-name\n'
        cfg.write_text(content)
        identity = self.config / '.ddnsto_boot.cfg'
        identity.write_text('identity-fixture')
        repeat = self.run_script(())
        self.assertEqual(repeat.returncode, 0, repeat.stderr)
        self.assertEqual(cfg.read_text(), content)
        self.assertEqual(identity.read_text(), 'identity-fixture')
        self.assertEqual(cfg.stat().st_mode & 0o777, 0o600)
        plist = plistlib.loads((self.agents / 'com.ddnsto.client.plist').read_bytes())
        self.assertEqual(plist['WorkingDirectory'], str(self.config))
        self.assertIn('cloud_status=unverified', repeat.stdout)

    def test_explicit_native_platform_installs(self):
        r = self.run_script(('--platform', 'macos', '--method', 'native', '--token', 'test-token'))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue((self.root / 'running').exists())

    def test_default_repeat_does_not_download_or_restart(self):
        self.assertEqual(self.run_script().returncode, 0)
        before = (self.root / 'service.log').read_bytes()
        r = self.run_script((), FAIL_DOWNLOAD='1')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('operation=none', r.stdout)
        self.assertEqual((self.root / 'service.log').read_bytes(), before)

    def test_explicit_update_preserves_config_without_token(self):
        self.assertEqual(self.run_script().returncode, 0)
        before = (self.config / 'ddnsto.yaml').read_bytes()
        r = self.run_script(('--action', 'update'))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.config / 'ddnsto.yaml').read_bytes(), before)

    def test_mismatched_platform_does_not_touch_launchd(self):
        r = self.run_script(('--platform', 'linux'))
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn('platform mismatch', r.stderr)
        self.assertFalse((self.root / 'service.log').exists())

    def test_stop_then_start_without_download_preserves_config(self):
        first = self.run_script()
        self.assertEqual(first.returncode, 0, first.stderr)
        before = (self.config / 'ddnsto.yaml').read_bytes()
        stopped = self.run_script(('--action', 'stop'), FAIL_DOWNLOAD='1')
        self.assertEqual(stopped.returncode, 0, stopped.stderr)
        self.assertFalse((self.root / 'running').exists())
        self.assertTrue((self.root / 'disabled').exists())
        self.assertIn('local_service=stopped', stopped.stdout)
        status = self.run_script(('--action', 'status'), FAIL_DOWNLOAD='1')
        self.assertEqual(status.returncode, 0, status.stderr)
        self.assertIn('local_service=stopped', status.stdout)
        started = self.run_script(('--action', 'start'), FAIL_DOWNLOAD='1')
        self.assertEqual(started.returncode, 0, started.stderr)
        self.assertTrue((self.root / 'running').exists())
        self.assertFalse((self.root / 'disabled').exists())
        self.assertEqual((self.config / 'ddnsto.yaml').read_bytes(), before)

    def test_status_without_install_does_not_create_files(self):
        r = self.run_script(('--action', 'status'))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('local_service=not-installed', r.stdout)
        self.assertFalse(self.config.exists())

    def test_restart_without_download(self):
        self.assertEqual(self.run_script().returncode, 0)
        r = self.run_script(('--action', 'restart'), FAIL_DOWNLOAD='1')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue((self.root / 'running').exists())

    def test_management_respects_install_lock(self):
        self.assertEqual(self.run_script().returncode, 0)
        (self.config / '.install-lock').mkdir()
        r = self.run_script(('--action', 'stop'))
        self.assertNotEqual(r.returncode, 0)
        self.assertTrue((self.root / 'running').exists())

    def test_start_failure_restores_binary_config_and_service(self):
        first = self.run_script()
        self.assertEqual(first.returncode, 0, first.stderr)
        binary = self.install / 'ddnsto'
        binary.write_text('old binary')
        cfg = self.config / 'ddnsto.yaml'
        old = cfg.read_bytes()
        failed = self.run_script(('--action', 'update'), FAIL_START='1')
        self.assertNotEqual(failed.returncode, 0)
        self.assertEqual(binary.read_text(), 'old binary')
        self.assertEqual(cfg.read_bytes(), old)
        self.assertTrue((self.root / 'running').exists())

    def test_download_failure_does_not_mutate(self):
        result = self.run_script(FAIL_DOWNLOAD='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.install / 'ddnsto').exists())
        self.assertFalse((self.root / 'service.log').exists())

    def test_disabled_reinstall_enables_before_start_and_preserves_identity(self):
        self.assertEqual(self.run_script().returncode, 0)
        cfg = self.config / 'ddnsto.yaml'
        old = cfg.read_bytes()
        identity = self.config / '.ddnsto_boot.cfg'
        identity.write_text('existing-device-identity')
        for word in ('disabled', 'true'):
            with self.subTest(output=word):
                (self.root / 'running').unlink(missing_ok=True)
                (self.root / 'disabled').touch()
                result = self.run_script(('--action', 'update'), DISABLED_WORD=word)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse((self.root / 'disabled').exists())
                self.assertTrue((self.root / 'running').exists())
                self.assertEqual(cfg.read_bytes(), old)
                self.assertEqual(identity.read_text(), 'existing-device-identity')

    def test_disabled_cold_install(self):
        (self.root / 'disabled').touch()
        result = subprocess.run(['sh', str(SCRIPT), '--token', 'test-token'],
                                env=self.env, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / 'disabled').exists())
        self.assertTrue((self.root / 'running').exists())

    def test_disabled_reinstall_failure_restores_disabled_state_and_files(self):
        self.assertEqual(self.run_script().returncode, 0)
        (self.root / 'running').unlink()
        (self.root / 'disabled').touch()
        binary = self.install / 'ddnsto'
        binary.write_text('old binary')
        cfg = self.config / 'ddnsto.yaml'
        old = cfg.read_bytes()
        result = self.run_script(('--action', 'update'), FAIL_START='1')
        self.assertNotEqual(result.returncode, 0)
        # Ensure the new start was reached, not rejected early as still disabled.
        self.assertTrue((self.root / 'failed-once').exists())
        self.assertTrue((self.root / 'disabled').exists())
        self.assertFalse((self.root / 'running').exists())
        self.assertEqual(binary.read_text(), 'old binary')
        self.assertEqual(cfg.read_bytes(), old)

    def test_disabled_cold_start_failure_restores_disabled_state(self):
        (self.root / 'disabled').touch()
        result = self.run_script(FAIL_START='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.root / 'failed-once').exists())
        self.assertTrue((self.root / 'disabled').exists())
        self.assertFalse((self.root / 'running').exists())
        self.assertFalse((self.install / 'ddnsto').exists())

    def test_disabled_state_query_failure_does_not_replace_or_stop_old_service(self):
        self.assertEqual(self.run_script().returncode, 0)
        binary = self.install / 'ddnsto'
        binary.write_text('old binary')
        (self.root / 'service.log').write_text('')
        result = self.run_script(('--action', 'update'), FAIL_DISABLED_QUERY='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(binary.read_text(), 'old binary')
        self.assertTrue((self.root / 'running').exists())
        self.assertNotIn('bootout', (self.root / 'service.log').read_text())

    def test_enabled_service_does_not_change_disable_override(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = (self.root / 'service.log').read_text().splitlines()
        self.assertNotIn('enable', calls)
        self.assertNotIn('disable', calls)

    def test_enable_failure_preserves_disabled_state(self):
        (self.root / 'disabled').touch()
        result = self.run_script(FAIL_ENABLE='1')
        self.assertEqual(result.returncode, 8, result.stderr)
        self.assertTrue((self.root / 'disabled').exists())
        self.assertFalse((self.root / 'running').exists())
        self.assertFalse((self.install / 'ddnsto').exists())

    def test_enable_failure_does_not_stop_a_loaded_disabled_service(self):
        self.assertEqual(self.run_script().returncode, 0)
        (self.root / 'disabled').touch()  # disable alone does not unload a job
        binary = self.install / 'ddnsto'
        binary.write_text('old binary')
        (self.root / 'service.log').write_text('')
        result = self.run_script(('--action', 'update'), FAIL_ENABLE='1')
        self.assertEqual(result.returncode, 8, result.stderr)
        self.assertTrue((self.root / 'disabled').exists())
        self.assertTrue((self.root / 'running').exists())
        self.assertEqual(binary.read_text(), 'old binary')
        self.assertNotIn('bootout', (self.root / 'service.log').read_text())

    def test_start_failure_restores_a_loaded_disabled_service(self):
        self.assertEqual(self.run_script().returncode, 0)
        (self.root / 'disabled').touch()
        result = self.run_script(('--action', 'update'), FAIL_START='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.root / 'failed-once').exists())
        self.assertTrue((self.root / 'disabled').exists())
        self.assertTrue((self.root / 'running').exists())

    def test_wrong_os_rejected_before_download(self):
        result = self.run_script(TEST_OS='Linux')
        self.assertEqual(result.returncode, 2)
        self.assertIn('macOS', result.stderr)
        self.assertFalse((self.root / 'payload').exists())

    def test_multiline_token_rejected(self):
        result = self.run_script(('--token', 'first\nsecond'))
        self.assertEqual(result.returncode, 2)
        self.assertFalse((self.root / 'payload').exists())

    def prepare_cold_bootstrap(self):
        (self.bin / 'zsetup').rename(self.root / 'native-fixture')
        self.env['ZSETUP_BIN'] = ''
        self.tool('curl', '''
while [ "$#" -gt 0 ]; do
 case "$1" in
  -o) shift; output=$1 ;;
  https://*) printf '%s\\n' "$1" >> "$TEST_ROOT/bootstrap.log" ;;
 esac
 shift
done
cp "$TEST_ROOT/native-fixture" "$output"
''')
        # The fixture cannot run Mach-O on Linux; isolate ONLY native-byte hash.
        self.tool('shasum', '''
case "${TEST_ARCH:-arm64}" in
 arm64) digest=06ec453f851bd0395cf9ea8539de168f80a9628d1a25597dd598c85f9dc633b0 ;;
 *) digest=608323145bcd8f083c0845b4bd0481eabccf0d74b99aa2aa6a88e59b34ce5b31 ;;
esac
printf '%s  %s\\n' "${BAD_DIGEST:-$digest}" "$3"
''')

    def test_cold_bootstrap_downloads_native_without_preinstall(self):
        self.prepare_cold_bootstrap()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('/0.3.0/zsetup-macos-aarch64', (self.root / 'bootstrap.log').read_text())
        self.assertTrue((self.install / 'ddnsto').exists())

    def test_bootstrap_hash_mismatch_never_executes_or_installs(self):
        self.prepare_cold_bootstrap()
        result = self.run_script(BAD_DIGEST='0' * 64)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('checksum', result.stderr.lower())
        self.assertFalse((self.root / 'payload').exists())
        self.assertFalse((self.install / 'ddnsto').exists())

    def test_maintained_entry_bootstraps_intel_mac(self):
        self.prepare_cold_bootstrap()
        result = subprocess.run(['sh', str(SCRIPT), '--token', 'test-token'],
                                env=self.env | {'TEST_ARCH': 'x86_64'}, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('/0.3.0/zsetup-macos-x86_64', (self.root / 'bootstrap.log').read_text())
        self.assertTrue((self.install / 'ddnsto').exists())

    def test_first_install_echoes_token_once_without_logging_it_again(self):
        pid, terminal = pty.fork()
        if pid == 0:
            os.execve('/bin/sh', ['sh', str(SCRIPT)], self.env)
        output = b''
        sent = False
        deadline = time.monotonic() + 10
        try:
            while time.monotonic() < deadline:
                ready, _, _ = select.select([terminal], [], [], 0.1)
                if not ready:
                    continue
                try:
                    part = os.read(terminal, 8192)
                except OSError:
                    break
                if not part:
                    break
                output += part
                if b'DDNSTO token:' in output and not sent:
                    os.write(terminal, b'visible-fixture-token\n')
                    sent = True
            else:
                os.kill(pid, 15)
                self.fail('interactive installer timed out')
        finally:
            os.close(terminal)
            _, status = os.waitpid(pid, 0)
        self.assertEqual(os.waitstatus_to_exitcode(status), 0, output.decode())
        self.assertTrue(sent)
        self.assertEqual(output.count(b'visible-fixture-token'), 1, output.decode())
        self.assertIn('visible-fixture-token', (self.config / 'ddnsto.yaml').read_text())

    def test_selected_version_is_explained_as_pinned_not_latest(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('selected client version 4.2.1', result.stderr)
        self.assertIn('pinned by this installer; latest release not checked', result.stderr)

    def test_first_start_failure_removes_only_owned_files(self):
        self.config.mkdir()
        identity = self.config / '.ddnsto_boot.cfg'
        identity.write_text('preexisting identity')
        result = self.run_script(FAIL_START='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.install / 'ddnsto').exists())
        self.assertFalse((self.config / 'ddnsto.yaml').exists())
        self.assertFalse((self.agents / 'com.ddnsto.client.plist').exists())
        self.assertEqual(identity.read_text(), 'preexisting identity')

    def test_unmanaged_job_is_not_stopped(self):
        (self.root / 'running').touch()
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.root / 'running').exists())
        self.assertNotIn('bootout', (self.root / 'service.log').read_text())

    def test_lock_is_not_removed_by_competing_installer(self):
        lock = self.config / '.install-lock'
        lock.mkdir(parents=True)
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(lock.is_dir())
        self.assertFalse((self.install / 'ddnsto').exists())

    def test_uninstall_retains_state_and_reinstall_uses_it(self):
        self.assertEqual(self.run_script().returncode, 0)
        cfg = self.config / 'ddnsto.yaml'
        before = cfg.read_bytes()
        identity = self.config / '.ddnsto_boot.cfg'
        identity.write_text('identity')
        unrelated = self.install / 'other'
        unrelated.write_text('keep')
        for _ in range(2):
            result = self.run_script(('--action', 'uninstall'), FAIL_DOWNLOAD='1')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((self.install / 'ddnsto').exists())
            self.assertFalse((self.agents / 'com.ddnsto.client.plist').exists())
            self.assertFalse((self.root / 'running').exists())
            self.assertEqual(cfg.read_bytes(), before)
            self.assertEqual(identity.read_text(), 'identity')
            self.assertEqual(unrelated.read_text(), 'keep')
        status = self.run_script(('--action', 'status'))
        self.assertIn('local_service=not-installed', status.stdout)
        self.assertIn('configuration=retained', status.stdout)
        rejected = self.run_script(('--token', 'replacement'))
        self.assertNotEqual(rejected.returncode, 0)
        result = self.run_script(())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(cfg.read_bytes(), before)
        self.assertEqual(identity.read_text(), 'identity')
        self.assertTrue((self.root / 'running').exists())

    def test_repair_missing_and_stale_plist_offline(self):
        self.assertEqual(self.run_script().returncode, 0)
        plist = self.agents / 'com.ddnsto.client.plist'
        original = plist.read_bytes()
        cfg = (self.config / 'ddnsto.yaml').read_bytes()
        for missing in (True, False):
            with self.subTest(missing=missing):
                if missing:
                    plist.unlink()
                else:
                    plist.write_bytes(original.replace(b'<key>KeepAlive</key><true/>', b'<key>KeepAlive</key><false/>'))
                (self.root / 'disabled').touch()
                result = self.run_script(('--action', 'repair'), FAIL_DOWNLOAD='1')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(plist.read_bytes(), original)
                self.assertEqual((self.config / 'ddnsto.yaml').read_bytes(), cfg)
                self.assertTrue((self.root / 'running').exists())
                self.assertFalse((self.root / 'disabled').exists())

    def test_repair_failure_restores_missing_plist_and_disabled_state(self):
        self.assertEqual(self.run_script().returncode, 0)
        plist = self.agents / 'com.ddnsto.client.plist'
        plist.unlink()
        (self.root / 'running').unlink()
        (self.root / 'disabled').touch()
        result = self.run_script(('--action', 'repair'), FAIL_START='1', FAIL_DOWNLOAD='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.root / 'failed-once').exists())
        self.assertFalse(plist.exists())
        self.assertTrue((self.root / 'disabled').exists())
        self.assertFalse((self.root / 'running').exists())

    def test_lifecycle_rejects_foreign_job_and_marker(self):
        self.assertEqual(self.run_script().returncode, 0)
        for action in ('repair', 'uninstall', 'update', 'stop', 'start', 'restart', 'status'):
            with self.subTest(action=action):
                (self.root / 'service.log').write_text('')
                result = self.run_script(('--action', action), FOREIGN_PROGRAM='/foreign')
                self.assertNotEqual(result.returncode, 0)
                calls = (self.root / 'service.log').read_text().splitlines()
                self.assertFalse(set(calls) & {'bootout', 'bootstrap', 'enable', 'disable'})
        (self.config / '.installer-macos-v1').write_text('foreign')
        result = self.run_script(('--action', 'uninstall'))
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.install / 'ddnsto').exists())

    def test_new_actions_respect_shared_lock(self):
        self.assertEqual(self.run_script().returncode, 0)
        lock = self.config / '.install-lock'
        lock.mkdir()
        for action in ('uninstall', 'repair'):
            result = self.run_script(('--action', action))
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(lock.exists())
            self.assertTrue((self.root / 'running').exists())

    def test_retained_reinstall_failure_keeps_config(self):
        self.assertEqual(self.run_script().returncode, 0)
        before = (self.config / 'ddnsto.yaml').read_bytes()
        result = self.run_script(('--action', 'uninstall'))
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.run_script((), FAIL_START='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.config / 'ddnsto.yaml').read_bytes(), before)
        self.assertFalse((self.install / 'ddnsto').exists())
        self.assertIn('configuration=retained', self.run_script(('--action', 'status')).stdout)

    def test_uninstall_stop_failure_does_not_remove_files(self):
        self.assertEqual(self.run_script().returncode, 0)
        result = self.run_script(('--action', 'uninstall'), FAIL_BOOTOUT='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.install / 'ddnsto').exists())
        self.assertTrue((self.agents / 'com.ddnsto.client.plist').exists())

    def test_repair_failure_restores_loaded_job_with_missing_plist(self):
        self.assertEqual(self.run_script().returncode, 0)
        plist = self.agents / 'com.ddnsto.client.plist'
        plist.unlink()
        result = self.run_script(('--action', 'repair'), FAIL_START='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.root / 'running').exists(), result.stderr)
        self.assertFalse(plist.exists())

    def test_configure_offline_preserves_other_settings_and_identity(self):
        self.assertEqual(self.run_script().returncode, 0)
        cfg = self.config / 'ddnsto.yaml'
        cfg.write_text(cfg.read_text() + 'routerName: custom\n')
        identity = self.config / '.ddnsto_boot.cfg'
        identity.write_text('keep')
        result = self.run_script(('--action', 'configure', '--token', "new'quoted"), FAIL_DOWNLOAD='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("userToken: 'new''quoted'", cfg.read_text())
        self.assertIn('routerName: custom', cfg.read_text())
        self.assertEqual(identity.read_text(), 'keep')
        self.assertNotIn("new'quoted", result.stdout + result.stderr)

    def test_configure_failure_restores_config_and_disabled_loaded_job(self):
        self.assertEqual(self.run_script().returncode, 0)
        cfg = self.config / 'ddnsto.yaml'
        before = cfg.read_bytes()
        (self.root / 'disabled').touch()
        result = self.run_script(('--action', 'configure', '--token', 'replacement'), FAIL_START='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.root / 'failed-once').exists())
        self.assertEqual(cfg.read_bytes(), before)
        self.assertTrue((self.root / 'running').exists())
        self.assertTrue((self.root / 'disabled').exists())

    def test_configure_requires_token_and_lock(self):
        self.assertEqual(self.run_script().returncode, 0)
        before = (self.config / 'ddnsto.yaml').read_bytes()
        result = self.run_script(('--action', 'configure'))
        self.assertNotEqual(result.returncode, 0)
        (self.config / '.install-lock').mkdir()
        result = self.run_script(('--action', 'configure', '--token', 'new'))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.config / 'ddnsto.yaml').read_bytes(), before)

    def test_busy_install_lock_blocks_downloads(self):
        (self.config / '.install-lock').mkdir(parents=True)
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'download.log').exists())

    def test_bootout_failure_does_not_attempt_rollback_over_running_files(self):
        self.assertEqual(self.run_script().returncode, 0)
        (self.root / 'service.log').write_text('')
        result = self.run_script(('--action', 'repair'), FAIL_BOOTOUT='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.root / 'running').exists())
        self.assertNotIn('bootstrap', (self.root / 'service.log').read_text().splitlines())

    def test_foreign_plist_and_symlink_never_removed(self):
        self.assertEqual(self.run_script().returncode, 0)
        plist = self.agents / 'com.ddnsto.client.plist'
        original = plist.read_bytes()
        plist.write_bytes(original.replace(str(self.install).encode(), b'/foreign'))
        for action in ('repair', 'uninstall'):
            result = self.run_script(('--action', action))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b'/foreign', plist.read_bytes())
        plist.unlink()
        target = self.root / 'unrelated.plist'
        target.write_bytes(original)
        plist.symlink_to(target)
        result = self.run_script(('--action', 'uninstall'))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(target.read_bytes(), original)

    def test_offline_actions_reject_credentials_and_plan(self):
        self.assertEqual(self.run_script().returncode, 0)
        for action in ('repair', 'uninstall'):
            for extra in (('--token', 'new'), ('--plan',)):
                result = self.run_script(('--action', action, *extra))
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue((self.root / 'running').exists())

    def test_configure_rejects_ambiguous_yaml_without_changes(self):
        self.assertEqual(self.run_script().returncode, 0)
        cfg = self.config / 'ddnsto.yaml'
        cfg.write_text(cfg.read_text() + "userToken: 'duplicate'\n")
        before = cfg.read_bytes()
        result = self.run_script(('--action', 'configure', '--token', 'new'))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(cfg.read_bytes(), before)
        self.assertTrue((self.root / 'running').exists())

    def test_uninstall_removal_failure_restores_files_job_and_override(self):
        self.assertEqual(self.run_script().returncode, 0)
        self.tool('rm', '''
if [ "${2:-}" = "$DDNSTO_INSTALL_DIR/ddnsto" ]; then
 /bin/rm -f "$DDNSTO_INSTALL_DIR/ddnsto"
 exit 9
fi
exec /bin/rm "$@"
''')
        result = self.run_script(('--action', 'uninstall'))
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.install / 'ddnsto').exists())
        self.assertTrue((self.agents / 'com.ddnsto.client.plist').exists())
        self.assertTrue((self.root / 'running').exists())
        self.assertFalse((self.root / 'disabled').exists())
        self.assertEqual((self.config / '.installer-macos-v1').read_text(), 'ddnsto-macos-v1\n')


if __name__ == '__main__':
    unittest.main()
