"""Native lifecycle using real files and isolated service/client boundaries."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HARNESS = r'''
set -eu
. "$SOURCE/business.sh"
[ ! -f "$SOURCE/linux-lifecycle.sh" ] || . "$SOURCE/linux-lifecycle.sh"
id() { echo 0; }
ddnsto_linux_preflight() {
    SUDO=; linux_service_manager=${MANAGER:-systemd}; linux_service_name=com.linkease.ddnstoshell
    linux_config_dir=$DDNSTO_LINUX_CONFIG_DIR; linux_config_file=$linux_config_dir/ddnsto-config.json
}
ddnsto_linux_unit_path() { printf '%s\n' "$FIXTURE/unit"; }
ddnsto_linux_unit_environment_path() { printf '%s\n' "$FIXTURE/optional-environment"; }
ddnsto_privileged() {
    case "$1:$2" in
        rm:-rf) [ "${CLEANUP_FAIL:-0}" = 0 ] || return 31 ;;
        rm:-f) if [ "${MARKER_FAIL:-0}" = 1 ] && [ "$3" = "$FIXTURE/.installer-linux-v1" ]; then return 32; fi ;;
    esac
    "$@"
}
systemctl() {
    printf '%s\n' "$*" >> "$FIXTURE/calls"
    case "$1" in
        show)
            [ "${QUERY_FAIL:-0}" = 0 ] || return 1
            case "$2" in
                --property=LoadState) if [ -e "$FIXTURE/unit" ] || [ -f "$FIXTURE/cached-unit" ]; then echo loaded; else echo not-found; fi ;;
                --property=FragmentPath) echo "$FIXTURE/unit" ;;
                --property=DropInPaths) printf '%s\n' "${DROPINS:-}" ;;
                --property=EnvironmentFiles)
                    if [ "${OPTIONAL_ENVIRONMENT:-0}" = 1 ]; then printf '%s (ignore_errors=yes)\n' "$FIXTURE/optional-environment"; else printf '\n'; fi ;;
                --property=NeedDaemonReload) echo "${RELOAD_NEEDED:-no}" ;;
                --property=ActiveState)
                    [ "${ACTIVE_QUERY_FAIL:-0}" = 0 ] || return 1
                    if [ -f "$FIXTURE/running" ]; then echo active; else echo inactive; fi ;;
                --property=ExecStart) printf '{ path=%s ; argv[]=%s run ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }\n' "${EXECUTABLE:-$DDNSTO_BIN_PATH}" "${EXECUTABLE:-$DDNSTO_BIN_PATH}" ;;
                *) printf '\n' ;;
            esac ;;
        is-active) test -f "$FIXTURE/running" ;;
        is-enabled) cat "$FIXTURE/enabled"; test "$(cat "$FIXTURE/enabled")" = enabled ;;
        stop)
            rm -f "$FIXTURE/running"
            if [ "${SWAP_CONFIG:-}" = symlink ]; then
                rm -f "$FIXTURE/ddnsto-config.json"
                ln -s "$FIXTURE/foreign-data" "$FIXTURE/ddnsto-config.json"
            elif [ "${SWAP_CONFIG:-}" = directory ]; then
                rm -f "$FIXTURE/ddnsto-config.json"
                mkdir -p "$FIXTURE/ddnsto-config.json"
            fi
            if [ "${SWAP_AFTER_STOP:-0}" = 1 ]; then
                printf '[Service]\nExecStart=/usr/bin/foreign run\n' > "$FIXTURE/unit"
            fi ;;
        start) [ "${RESTORE_FAIL:-0}" = 0 ] || return 30; touch "$FIXTURE/running" ;;
        enable|disable) case "$1" in enable) echo enabled;; disable) echo disabled;; esac > "$FIXTURE/enabled" ;;
        daemon-reload) if [ ! -e "$FIXTURE/unit" ]; then rm -f "$FIXTURE/cached-unit"; fi ;;
        *) echo 'unexpected systemctl operation' >&2; return 99 ;;
    esac
}
ddnsto_linux_stop() { systemctl stop "$linux_service_name"; }
ddnsto_linux_running() { test -f "$FIXTURE/running"; }
ddnsto_linux_wait_healthy() { [ "$BROKEN" = 0 ] && test -f "$FIXTURE/running"; }
ddnsto_parse_args --action "$TEST_ACTION" $EXTRA
ddnsto_with_operation_lock ddnsto_linux_lifecycle
'''


class LinuxLifecycle(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.binary = self.root / 'ddnsto'
        self.config = self.root / 'ddnsto-config.json'
        self.marker = self.root / '.installer-linux-v1'
        self.retained = self.root / '.uninstalled-linux-v1'
        self.config.write_text(json.dumps({'token': 'old-token', 'routeridx': 7, 'custom': {'preserve': True}}))
        (self.root / '.ddnsto_boot.cfg').write_text('identity')
        self.binary.write_text('''#!/bin/sh
case "$1" in
 uninstall) [ "$BROKEN" = 0 ] || exit 24; rm -f "$FIXTURE/unit";;
 -daemon) printf '[Service]\\nExecStart=%s run\\n' "$DDNSTO_BIN_PATH" > "$FIXTURE/unit"; touch "$FIXTURE/running"; echo enabled > "$FIXTURE/enabled";;
esac
''')
        self.binary.chmod(0o755)
        self.marker.write_text(f'ddnsto-linux-v1\n{self.binary}\n{self.config}\n')
        (self.root / 'unit').write_text(f'[Service]\nExecStart={self.binary} run\n# preserve custom comment\n')
        (self.root / 'enabled').write_text('enabled\n')
        (self.root / 'running').touch()
        self.env = dict(os.environ, SOURCE=str(ROOT), FIXTURE=str(self.root), BROKEN='0',
                        DDNSTO_BIN_PATH=str(self.binary), DDNSTO_LINUX_CONFIG_DIR=str(self.root),
                        DDNSTO_LOCK_DIR=str(self.root / 'lock'), EXTRA='')

    def run_action(self, action, **env):
        r = subprocess.run(['sh', '-c', HARNESS], env=self.env | {'TEST_ACTION': action} | env,
                           text=True, capture_output=True, timeout=5)
        self.assertFalse((self.root / 'lock').exists())
        self.assertEqual((self.root / '.ddnsto_boot.cfg').read_text(), 'identity')
        return r

    def test_uninstall_retains_config_and_is_repeatable(self):
        old = self.config.read_bytes()
        r = self.run_action('uninstall')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(self.binary.exists())
        self.assertFalse((self.root / 'unit').exists())
        self.assertFalse(self.marker.exists())
        self.assertTrue(self.retained.is_file())
        self.assertEqual(self.config.read_bytes(), old)
        self.assertIn('config=retained', r.stdout)
        self.assertEqual(self.run_action('uninstall').returncode, 0)

    def test_uninstall_failure_restores_binary_config(self):
        old = self.config.read_bytes()
        r = self.run_action('uninstall', BROKEN='1')
        self.assertNotEqual(r.returncode, 0)
        self.assertTrue(self.binary.exists())
        self.assertTrue(self.marker.exists())
        self.assertEqual(self.config.read_bytes(), old)
        self.assertNotIn('operation=uninstall', r.stdout)

    def test_refuse_unmanaged_install(self):
        self.marker.unlink()
        for action in ('repair', 'uninstall'):
            r = self.run_action(action)
            self.assertEqual(r.returncode, 2, r.stderr)
            self.assertTrue(self.binary.exists())
        self.assertFalse((self.root / 'calls').exists())

    def test_repair_recreates_missing_service(self):
        (self.root / 'unit').unlink()
        (self.root / 'running').unlink()
        old = self.config.read_bytes()
        r = self.run_action('repair')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue((self.root / 'unit').exists())
        self.assertIn('operation=repair', r.stdout)
        self.assertEqual(self.config.read_bytes(), old)

    def test_configure_changes_only_token(self):
        r = self.run_action('configure', EXTRA="--token replacement")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(self.config.read_text()), {'token': 'replacement', 'routeridx': 7, 'custom': {'preserve': True}})
        self.assertNotIn('replacement', r.stdout + r.stderr)

    def test_configure_failure_restores_original_bytes(self):
        old = self.config.read_bytes()
        r = self.run_action('configure', EXTRA='--token replacement', BROKEN='1')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.config.read_bytes(), old)

    def test_retained_config_policy_uses_no_new_credentials(self):
        self.binary.unlink()
        self.marker.rename(self.retained)
        script = '. "$SOURCE/business.sh"; business_platform=linux; ddnsto_parse_args; ddnsto_existing_policy; test "$RETAINED_CONFIG" = 1'
        r = subprocess.run(['sh', '-eu', '-c', script], env=self.env, text=True, capture_output=True)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_retained_repeat_refuses_external_service_and_query_error(self):
        self.binary.unlink()
        self.marker.rename(self.retained)
        for extra in ({}, {'QUERY_FAIL': '1'}):
            r = self.run_action('uninstall', **extra)
            self.assertNotEqual(r.returncode, 0, r.stdout)
            self.assertNotIn('operation=none', r.stdout)
            self.assertTrue((self.root / 'unit').exists())

    def test_replaced_unit_is_not_stopped_or_removed(self):
        for action in ('repair', 'configure', 'uninstall'):
            r = self.run_action(action, EXTRA='--token new' if action == 'configure' else '',
                                EXECUTABLE='/usr/bin/foreign-service')
            self.assertNotEqual(r.returncode, 0, r.stdout)
            self.assertTrue((self.root / 'running').exists())
            self.assertTrue(self.binary.exists())
            self.assertTrue(self.marker.exists())

    def test_unit_dropins_or_stale_disk_definition_are_rejected(self):
        for extra in ({'DROPINS': '/etc/systemd/system/foreign.conf'}, {'RELOAD_NEEDED': 'yes'}):
            r = self.run_action('uninstall', **extra)
            self.assertNotEqual(r.returncode, 0, r.stdout)
            self.assertTrue((self.root / 'running').exists())

    def test_configure_rollback_restores_unit_bytes_and_disabled_state(self):
        old_unit = (self.root / 'unit').read_bytes()
        (self.root / 'enabled').write_text('disabled\n')
        (self.root / 'running').unlink()
        r = self.run_action('configure', EXTRA='--token replacement', BROKEN='1')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual((self.root / 'unit').read_bytes(), old_unit)
        self.assertEqual((self.root / 'enabled').read_text(), 'disabled\n')
        self.assertFalse((self.root / 'running').exists())

    def test_uninstall_marker_failure_restores_markers_and_unit(self):
        old_unit = (self.root / 'unit').read_bytes()
        r = self.run_action('uninstall', MARKER_FAIL='1')
        self.assertNotEqual(r.returncode, 0)
        self.assertTrue(self.marker.exists())
        self.assertFalse(self.retained.exists())
        self.assertEqual((self.root / 'unit').read_bytes(), old_unit)
        self.assertNotIn('operation=uninstall', r.stdout)

    def test_cleanup_failure_does_not_emit_success(self):
        r = self.run_action('uninstall', CLEANUP_FAIL='1')
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn('operation=uninstall', r.stdout)

    def test_retained_repeat_refuses_missing_or_symlinked_config(self):
        self.binary.unlink()
        self.marker.rename(self.retained)
        (self.root / 'unit').unlink()
        self.config.unlink()
        self.assertNotEqual(self.run_action('uninstall').returncode, 0)
        self.config.symlink_to(self.root / '.ddnsto_boot.cfg')
        self.assertNotEqual(self.run_action('uninstall').returncode, 0)

    def test_openrc_unverified_ownership_is_refused_without_service_calls(self):
        r = self.run_action('uninstall', MANAGER='openrc')
        self.assertNotEqual(r.returncode, 0)
        self.assertTrue((self.root / 'running').exists())
        self.assertTrue((self.root / 'unit').exists())
        self.assertFalse((self.root / 'calls').exists())

    def test_disk_unit_replacement_is_rejected_even_if_loaded_command_matches(self):
        (self.root / 'unit').write_text('[Service]\nExecStart=/usr/bin/foreign run\n')
        r = self.run_action('uninstall')
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertTrue((self.root / 'running').exists())
        self.assertIn('foreign', (self.root / 'unit').read_text())

    def test_configure_preserves_verified_unit_definition(self):
        old_unit = (self.root / 'unit').read_bytes()
        r = self.run_action('configure', EXTRA='--token replacement')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.root / 'unit').read_bytes(), old_unit)

    def test_unit_replaced_after_stop_is_not_deleted_by_action_or_rollback(self):
        r = self.run_action('uninstall', SWAP_AFTER_STOP='1')
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn('foreign', (self.root / 'unit').read_text())
        self.assertTrue(self.binary.exists())
        self.assertIn('recovery incomplete', r.stderr)
        self.assertEqual(len(list(self.root.glob('.lifecycle.*'))), 1)

    def test_failed_restart_keeps_recovery_backup_and_reports_failure(self):
        old = self.config.read_bytes()
        r = self.run_action('configure', EXTRA='--token replacement', RESTORE_FAIL='1')
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertEqual(self.config.read_bytes(), old)
        self.assertIn('recovery incomplete', r.stderr)
        self.assertNotIn('operation=configure', r.stdout)
        backup, = self.root.glob('.lifecycle.*')
        self.assertEqual((backup / 'config').read_bytes(), old)

    def test_unknown_active_state_is_not_treated_as_stopped(self):
        r = self.run_action('uninstall', ACTIVE_QUERY_FAIL='1')
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertTrue((self.root / 'running').exists())
        self.assertTrue(self.binary.exists())

    def test_retained_state_with_running_unit_is_not_a_successful_noop(self):
        self.binary.unlink()
        self.marker.rename(self.retained)
        (self.root / 'unit').unlink()
        r = self.run_action('uninstall')
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertNotIn('operation=none', r.stdout)

    def test_symlinked_unit_is_not_removed(self):
        unit = self.root / 'unit'
        foreign = self.root / 'foreign-unit'
        unit.rename(foreign)
        unit.symlink_to(foreign)
        r = self.run_action('uninstall')
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertTrue(unit.is_symlink())
        self.assertTrue(foreign.exists())
        self.assertTrue((self.root / 'running').exists())

    def test_ancestor_symlink_is_refused(self):
        alias = self.root / 'alias'
        alias.symlink_to(self.root, target_is_directory=True)
        r = self.run_action('uninstall', DDNSTO_BIN_PATH=str(alias / 'ddnsto'))
        self.assertNotEqual(r.returncode, 0)
        self.assertTrue((self.root / 'running').exists())

    def test_conflicting_retained_marker_is_not_overwritten(self):
        self.retained.write_text('foreign marker\n')
        r = self.run_action('uninstall')
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertEqual(self.retained.read_text(), 'foreign marker\n')

    def test_generated_unit_with_quoted_argument_and_absent_optional_environment(self):
        (self.root / 'unit').write_text(
            f'[Service]\nExecStart={self.binary} "run"\n'
            f'EnvironmentFile=-{self.root}/optional-environment\n')
        r = self.run_action('uninstall', OPTIONAL_ENVIRONMENT='1')
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_existing_optional_environment_is_not_trusted(self):
        (self.root / 'optional-environment').write_text('LD_PRELOAD=/foreign.so\n')
        r = self.run_action('uninstall', OPTIONAL_ENVIRONMENT='1')
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertTrue((self.root / 'running').exists())

    def test_uninstall_reloads_systemd_before_verifying_removal(self):
        (self.root / 'cached-unit').touch()
        r = self.run_action('uninstall')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse((self.root / 'cached-unit').exists())

    def test_configure_rejects_partial_valid_json_without_mutation(self):
        for content in ('{"token":"old"} trailing-invalid', '{"token":"a"}\n{"token":"b"}'):
            with self.subTest(content=content):
                self.config.write_text(content)
                r = self.run_action('configure', EXTRA='--token replacement')
                self.assertNotEqual(r.returncode, 0, r.stdout)
                self.assertEqual(self.config.read_text(), content)
                self.assertTrue((self.root / 'running').exists())

    def test_config_replaced_by_symlink_after_stop_does_not_overwrite_target(self):
        foreign = self.root / 'foreign-data'
        foreign.write_text('unrelated data')
        r = self.run_action('uninstall', SWAP_CONFIG='symlink')
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertEqual(foreign.read_text(), 'unrelated data')
        self.assertTrue(self.binary.exists())
        self.assertIn('recovery incomplete', r.stderr)

    def test_config_replaced_by_directory_is_not_a_successful_uninstall(self):
        r = self.run_action('uninstall', SWAP_CONFIG='directory')
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertFalse((self.config / 'config').exists())
        self.assertTrue(self.binary.exists())


if __name__ == '__main__':
    unittest.main()
