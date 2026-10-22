"""Isolated lifecycle tests: never call the host service manager."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ManagementTests(unittest.TestCase):
    def run_action(self, platform, action, *, missing=False, fail=False, extra='', manager='systemd', symlink=False, load='loaded', state_error=False, busy=False,
                   foreign=False, legacy=False, package_manager='opkg', owner='ddnsto', package_error=False,
                   dropins=False, disk_foreign=False, swap_on_enable=False, owner_path='', package_missing=False):
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder)
            lock = home / 'installer.lock'
            if busy:
                lock.mkdir()
            if not missing:
                for name in ('binary', 'ddnsto-config.json', 'config'):
                    (home / name).write_text('unchanged')
                (home / 'binary').chmod(0o755)
            if not legacy:
                (home / '.installer-linux-v1').write_text(
                    f'ddnsto-linux-v1\n{home}/binary\n{home}/ddnsto-config.json\n')
            executable = '/foreign/program' if disk_foreign else str(home / 'binary')
            (home / 'unit').write_text(f'[Service]\nExecStart={executable} run\n')
            if symlink:
                (home / 'binary').unlink()
                (home / 'binary').symlink_to(home / 'config')
            script = r'''
set -u
. "$SOURCE/business.sh"
. "$SOURCE/docker-lifecycle.sh"
. "$SOURCE/linux-lifecycle.sh"
. "$SOURCE/openwrt-lifecycle.sh"
if [ -f "$SOURCE/service-management.sh" ]; then . "$SOURCE/service-management.sh"; fi
ddnsto_local_platform() { detected_platform=$PLATFORM; package_manager=$PACKAGE_MANAGER; }
ddnsto_linux_preflight() {
    SUDO=; linux_service_name=com.linkease.ddnstoshell; linux_service_manager=$MANAGER
    linux_config_dir=$DDNSTO_LINUX_CONFIG_DIR; linux_config_file=$linux_config_dir/ddnsto-config.json
}
ddnsto_linux_unit_path() { printf '%s\n' "$FIXTURE/unit"; }
ddnsto_privileged() { "$@"; }
id() { echo 0; }
opkg() {
    printf 'opkg %s\n' "$*" >> "$FIXTURE/calls"
    [ "$PACKAGE_ERROR" = 0 ] || return 8
    case "$1" in
        search)
            resolved_owner=$OWNER
            if [ -n "$OWNER_PATH" ] && [ "${2##*/}" != "$OWNER_PATH" ]; then resolved_owner=ddnsto; fi
            printf '%s - 4.2.6\n' "$resolved_owner" ;;
        list-installed) if [ "$PACKAGE_MISSING" = 1 ]; then printf 'other - 1\n'; else printf 'ddnsto - 4.2.6\n'; fi ;;
        *) return 99 ;;
    esac
}
apk() {
    printf 'apk %s\n' "$*" >> "$FIXTURE/calls"
    [ "$PACKAGE_ERROR" = 0 ] || return 8
    case "$*" in
        '-q info --who-owns '*)
            resolved_owner=$OWNER
            if [ -n "$OWNER_PATH" ] && [ "${4##*/}" != "$OWNER_PATH" ]; then resolved_owner=ddnsto; fi
            printf '%s\n' "$resolved_owner" ;;
        info) if [ "$PACKAGE_MISSING" = 1 ]; then printf 'other\n'; else printf 'ddnsto\n'; fi ;;
        *) return 99 ;;
    esac
}
systemctl() {
    printf '%s\n' "$*" >> "$FIXTURE/calls"
    case "$1" in
        show) case "$2" in
            --property=LoadState) printf '%s\n' "$LOAD" ;;
            --property=ActiveState) [ "$STATE_ERROR" = 0 ] || return 9; if [ -f "$FIXTURE/stopped" ]; then echo inactive; else echo active; fi ;;
            --property=FragmentPath) printf '%s\n' "$FIXTURE/unit" ;;
            --property=NeedDaemonReload) echo no ;;
            --property=DropInPaths) [ "$DROPINS" = 0 ] || echo /foreign/override.conf ;;
            --property=ExecStart)
                executable=$DDNSTO_BIN_PATH
                [ "$FOREIGN" = 0 ] || executable=/foreign/program
                printf '{ path=%s ; argv[]=%s run ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }\n' "$executable" "$executable" ;;
            *) printf '\n' ;;
        esac ;;
        is-active) [ ! -f "$FIXTURE/stopped" ] ;;
        stop) [ "$FAIL" = 0 ] || return 7; touch "$FIXTURE/stopped" ;;
        start) rm -f "$FIXTURE/stopped" ;;
        enable) if [ "$SWAP_ON_ENABLE" = 1 ]; then printf '[Service]\nExecStart=/foreign/program run\n' > "$FIXTURE/unit"; fi ;;
    esac
}
sleep() { :; }
bootstrap_and_run() { echo 'unexpected download' >&2; exit 99; }
set -- --action "$ACTION" $EXTRA
. "$SOURCE/main.sh"
'''
            service = home / 'service'
            service.write_text('#!/bin/sh\n'
                'printf "%s\\n" "$*" >> "$FIXTURE/calls"\n'
                'case "$1" in\n'
                ' status) [ ! -f "$FIXTURE/stopped" ];;\n'
                ' stop) [ "$FAIL" = 0 ] || exit 7; touch "$FIXTURE/stopped";;\n'
                ' start) rm -f "$FIXTURE/stopped";;\n'
                'esac\n')
            service.chmod(0o755)
            rc_service = home / 'rc-service'
            rc_service.write_text('#!/bin/sh\n[ "$1" != --exists ] || exit 0\nshift\nexec "$FIXTURE/service" "$@"\n')
            rc_service.chmod(0o755)
            rc_update = home / 'rc-update'
            rc_update.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$FIXTURE/calls"\n')
            rc_update.chmod(0o755)
            result = subprocess.run(['sh', '-c', script], text=True, capture_output=True,
                env=dict(os.environ, SOURCE=str(ROOT), FIXTURE=folder, PLATFORM=platform,
                    PATH=folder + os.pathsep + os.environ['PATH'],
                    MANAGER=manager, ACTION=action, FAIL=str(int(fail)), EXTRA=extra,
                    FOREIGN=str(int(foreign)), DROPINS=str(int(dropins)), SWAP_ON_ENABLE=str(int(swap_on_enable)),
                    PACKAGE_MANAGER=package_manager, OWNER=owner, PACKAGE_ERROR=str(int(package_error)),
                    OWNER_PATH=owner_path, PACKAGE_MISSING=str(int(package_missing)),
                    LOAD=load, STATE_ERROR=str(int(state_error)),
                    DDNSTO_LOCK_DIR=str(lock),
                    DDNSTO_BIN_PATH=str(home / 'binary'), DDNSTO_OPENWRT_BIN_PATH=str(home / 'binary'),
                    DDNSTO_LINUX_CONFIG_DIR=folder, DDNSTO_CONFIG_PATH=str(home / 'config'),
                    DDNSTO_SERVICE_PATH=str(service)))
            calls = (home / 'calls').read_text() if (home / 'calls').exists() else ''
            self.assertEqual(lock.exists(), busy, 'changed foreign lock or leaked owned lock')
            if not missing:
                self.assertEqual((home / 'ddnsto-config.json').read_text(), 'unchanged')
                self.assertEqual((home / 'config').read_text(), 'unchanged')
            return result, calls

    def test_status_does_not_mutate(self):
        for platform in ('linux', 'openwrt'):
            result, calls = self.run_action(platform, 'status')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('local_service=running cloud_status=unverified', result.stdout)
            self.assertNotIn('stop', calls)
            self.assertNotIn('enable', calls)

    def test_management_respects_installation_lock(self):
        for platform in ('linux', 'openwrt'):
            result, calls = self.run_action(platform, 'stop', busy=True)
            self.assertEqual(result.returncode, 16, result.stderr)
            self.assertNotIn('disable', calls)
            self.assertNotIn('stop', calls)
            result, _ = self.run_action(platform, 'status', busy=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_lifecycle(self):
        for platform in ('linux', 'openwrt'):
            for action in ('start', 'stop', 'restart'):
                result, calls = self.run_action(platform, action)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('disable' if action == 'stop' else 'enable', calls)
                self.assertIn('local_service=' + ('stopped' if action == 'stop' else 'running'), result.stdout)

    def test_stop_failure_is_not_success(self):
        for platform in ('linux', 'openwrt'):
            result, _ = self.run_action(platform, 'stop', fail=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('local_service=stopped', result.stdout)

    def test_openrc_only_legacy_status_is_allowed(self):
        for action in ('status', 'start', 'stop', 'restart'):
            result, calls = self.run_action('linux', action, manager='openrc')
            self.assertEqual(result.returncode, 0 if action == 'status' else 2, result.stderr)
            if action != 'status':
                self.assertEqual(calls, '')

    def test_foreign_systemd_command_is_never_mutated(self):
        for action in ('start', 'stop', 'restart'):
            result, calls = self.run_action('linux', action, foreign=True)
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            self.assertFalse(any(line.split()[0] in ('enable', 'disable', 'start', 'stop') for line in calls.splitlines()), calls)

    def test_disk_replacement_and_overrides_are_refused(self):
        for kwargs in ({'disk_foreign': True}, {'dropins': True}):
            result, calls = self.run_action('linux', 'restart', **kwargs)
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            self.assertFalse(any(line.startswith(('enable ', 'stop ', 'start ')) for line in calls.splitlines()), calls)

    def test_legacy_linux_installation_is_read_only(self):
        result, _ = self.run_action('linux', 'status', legacy=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        for action in ('start', 'stop', 'restart'):
            result, calls = self.run_action('linux', action, legacy=True)
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            self.assertFalse(any(line.startswith(('enable ', 'disable ', 'stop ', 'start ')) for line in calls.splitlines()), calls)

    def test_recheck_before_each_service_mutation(self):
        result, calls = self.run_action('linux', 'restart', swap_on_enable=True)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn('enable com.linkease.ddnstoshell', calls)
        self.assertNotIn('stop com.linkease.ddnstoshell', calls)
        self.assertNotIn('start com.linkease.ddnstoshell', calls)

    def test_openwrt_requires_confirmed_package_ownership(self):
        for package_manager in ('opkg', 'apk'):
            for action in ('start', 'stop', 'restart'):
                for kwargs in ({'owner': 'foreign'}, {'package_error': True}, {'package_missing': True},
                               {'owner': 'foreign', 'owner_path': 'service'},
                               {'owner': 'foreign', 'owner_path': 'config'},
                               {'owner': 'foreign', 'owner_path': 'binary'}):
                    result, calls = self.run_action('openwrt', action, package_manager=package_manager, **kwargs)
                    self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                    self.assertFalse(any(line in ('enable', 'disable', 'stop', 'start', 'status') for line in calls.splitlines()), calls)

    def test_owned_apk_service_is_supported(self):
        for action in ('start', 'stop', 'restart'):
            result, _ = self.run_action('openwrt', action, package_manager='apk')
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_unknown_or_missing_unit_rejected(self):
        for kwargs in ({'load': 'not-found'}, {'state_error': True}, {'symlink': True}):
            result, _ = self.run_action('linux', 'status', **kwargs)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('local_service=stopped', result.stdout)

    def test_device_and_docker_guards(self):
        for platform, extra in (('synology', ''), ('qnap', ''), ('unraid', ''), ('linux', '--method docker')):
            result, calls = self.run_action(platform, 'stop', extra=extra)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertEqual(calls, '')

    def test_missing_install_rejected(self):
        result, calls = self.run_action('linux', 'start', missing=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, '')

    def test_credentials_and_install_flags_rejected(self):
        for extra in ('--token-file nonexistent', '--plan', '--force-version lite', '--verify-status'):
            result, calls = self.run_action('linux', 'status', extra=extra)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertEqual(calls, '')


if __name__ == '__main__':
    unittest.main()
