"""Lifecycle boundary tests; all UCI, package and init operations are fakes.

Metadata fixtures follow upstream opkg_cmd.c print_pkg/opkg_search_cmd and
apk-tools v2.14.4 app_info.c info_who_owns (quiet output is a package name).
No real packages or host services are invoked.
"""
import json
import os
from pathlib import Path
import pty
import select
import time
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'openwrt-lifecycle.sh'
MAIN_HARNESS = r'''
. "$APP/business.sh"
. "$APP/openwrt-lifecycle.sh"
. "$APP/product-pins.sh"
if [ -f "$APP/method-selection.sh" ]; then . "$APP/method-selection.sh"; fi
id() { printf '%s\n' "${FAKE_UID:-0}"; }
ddnsto_local_platform() { detected_platform=openwrt; package_manager=$PACKAGE_MANAGER; }
status() { :; }
ddnsto_verified_download() {
    printf 'download %s\n' "$1" >> "$FIXTURE/calls"
    printf 'verified fixture package' > "$2"
}
bootstrap_and_run() {
    [ "${RUN_PACKAGES:-0}" = 1 ] || { printf 'UNEXPECTED_DOWNLOAD\n' >&2; return 99; }
    arch=x86_64
    work_dir=$FIXTURE/work
    transaction_dir=$FIXTURE/transaction
    mkdir -p "$transaction_dir"
    ddnsto_with_operation_lock ddnsto_openwrt
}
sleep() { :; }
. "$APP/main.sh"
'''
ORIGINAL = """config ddnsto
 option token 'old-secret'
 option enabled '0'
 option index '17'
 option router_id 'op-keep'
 option identity_mode 'v2'
 option device_uuid 'keep-uuid'
 option feat_enabled '1'
"""

FAKE = r'''#!/usr/bin/env python3
import json, os, pathlib, re, signal, sys
root = pathlib.Path(os.environ['FIXTURE'])
args = sys.argv[1:]
tool = pathlib.Path(sys.argv[0]).name
with (root / 'calls').open('a') as log:
    log.write(tool + ' ' + ('uci-command' if tool == 'uci' else ' '.join(args)) + '\n')
fail = os.environ.get('FAIL', '')
if tool == 'pinned-reinstall':
    (root / 'etc/config/ddnsto').write_text('package defaults\n')
    if fail == 'callback': sys.exit(9)
    sys.exit(0)
if tool == 'uci':
    folder = pathlib.Path(args[args.index('-c') + 1])
    args = args[args.index('-q') + 1:]
    command = args[0]
    path = folder / 'ddnsto'
    if command == 'changes':
        print(os.environ.get('PENDING', ''), end='')
        sys.exit(0)
    if fail == command:
        print('secret from failed tool: old-secret new-secret', file=sys.stderr)
        sys.exit(7)
    content = path.read_text()
    if command == 'get':
        if args[1] in ('ddnsto.@ddnsto[0]', 'ddnsto.@ddnsto[1]'):
            count = content.count('config ddnsto')
            if count <= int(args[1][-2]): sys.exit(1)
            print('ddnsto'); sys.exit(0)
        key = args[1].split('.')[-1]
        match = re.search(r"option " + key + r" '([^']*)'", content)
        if not match: sys.exit(1)
        print(match.group(1)); sys.exit(0)
    if command == 'set':
        key, value = args[1].split('=', 1)
        key = key.split('.')[-1]
        line = "option " + key + " '" + value + "'"
        content, count = re.subn(r"option " + key + r" '[^']*'", lambda m: line, content)
        if not count: content += ' ' + line + '\n'
        path.write_text(content)
    sys.exit(0)
if tool in ('opkg', 'apk'):
    db = root / 'packages'
    packages = json.loads(db.read_text())
    if fail == 'metadata': sys.exit(8)
    if fail == 'post-metadata' and 'ddnsto' not in packages: sys.exit(8)
    if args in (['list-installed'], ['info']) and 'LISTING' in os.environ:
        print(os.environ['LISTING']); sys.exit(0)
    if args == ['list-installed']:
        print('\n'.join(p + ' - 4.2.6-1' for p in packages)); sys.exit(0)
    if args == ['info']:
        print('\n'.join(packages)); sys.exit(0)
    if args[:2] == ['info', '-e']: sys.exit(0 if args[2] in packages else 1)
    if args == ['update']: sys.exit(0)
    if args[0] == 'search' or '--who-owns' in args:
        owner = os.environ.get('OWNER', 'ddnsto')
        if owner == 'none': sys.exit(1)
        print(owner + (' - 4.2.6-1 - DDNSTO client' if tool == 'opkg' else ''))
        sys.exit(0)
    if args[0] in ('remove', 'del'):
        # Model package hooks deleting even a modified conffile.
        if os.environ.get('REMOVE_KEEPS_CONFIG') != '1':
            (root / 'etc/config/ddnsto').unlink(missing_ok=True)
        if fail == 'signal-remove':
            os.kill(os.getppid(), signal.SIGTERM); sys.exit(0)
        if fail == 'restore-directory': (root / 'etc/config/ddnsto').mkdir()
        if fail == 'restore-symlink': (root / 'etc/config/ddnsto').symlink_to(root / 'sentinel')
        if fail == 'marker-directory': (root / 'etc/config/.uninstalled-openwrt-v1').mkdir()
        if fail != 'lying-remove':
            db.write_text(json.dumps([p for p in packages if p not in args[1:]]))
            if 'ddnsto' in args[1:]:
                (root / 'usr/sbin/ddnstod').unlink(missing_ok=True)
                (root / 'etc/init.d/ddnsto').unlink(missing_ok=True)
        if fail == 'remove': sys.exit(9)
        sys.exit(0)
    if args[0] in ('install', 'add'):
        name = pathlib.Path(args[-1]).name.split('.')[0]
        if name.startswith('ddnsto_'): name = 'ddnsto'
        if fail == 'package-install' and name == 'luci-app-ddnsto': sys.exit(23)
        if name not in packages: packages.append(name)
        db.write_text(json.dumps(packages))
        if name == 'ddnsto':
            config = root / 'etc/config/ddnsto'
            if not config.exists(): config.write_text("config ddnsto\n option enabled '0'\n option index '0'\n")
            for path in (root / 'usr/sbin/ddnstod', root / 'etc/init.d/ddnsto'):
                path.write_text(pathlib.Path(__file__).read_text()); path.chmod(0o755)
            # Actual pinned init checks enabled before procd_open_instance.
            if "option enabled '1'" in config.read_text():
                with (root / 'calls').open('a') as log: log.write('EARLY_START\n')
                config.write_text(config.read_text().replace('op-keep', 'op-corrupted'))
        sys.exit(0)
    sys.exit(98)
if tool == 'ddnstod': sys.exit(0)
if tool == 'ddnsto':
    if fail == 'signal-' + args[0]:
        os.kill(os.getppid(), signal.SIGTERM); sys.exit(0)
    if fail == args[0]:
        print('old-secret new-secret', file=sys.stderr); sys.exit(7)
    if args[0] == 'stop': (root / 'stopped').touch()
    if args[0] == 'restart': (root / 'stopped').unlink(missing_ok=True)
    if args[0] == 'status':
        counter = root / 'status-count'
        count = int(counter.read_text()) if counter.exists() else 0
        counter.write_text(str(count + 1))
        if fail == 'slow-start' and count < 2: sys.exit(1)
        if fail == 'not-running' or (root / 'stopped').exists(): sys.exit(1)
    sys.exit(0)
sys.exit(99)
'''


class OpenWrtLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = self.root / 'etc/config/ddnsto'
        self.binary = self.root / 'usr/sbin/ddnstod'
        self.service = self.root / 'etc/init.d/ddnsto'
        self.tools = self.root / 'tools'
        self.tools.mkdir()
        for path in (self.config, self.binary, self.service):
            path.parent.mkdir(parents=True, exist_ok=True)
        self.config.write_text(ORIGINAL)
        self.config.chmod(0o600)
        self.binary.write_text('client must never execute')
        self.binary.chmod(0o755)
        self.service.write_text(FAKE)
        self.service.chmod(0o755)
        for name in ('uci', 'opkg', 'apk', 'pinned-reinstall'):
            path = self.tools / name
            path.write_text(FAKE)
            path.chmod(0o755)
        self.packages = ['ddnsto', 'luci-app-ddnsto', 'luci-i18n-ddnsto-zh-cn', 'unrelated']
        (self.root / 'packages').write_text(json.dumps(self.packages))

    def run_action(self, action, manager='opkg', **extra):
        env = dict(os.environ, FIXTURE=str(self.root), SOURCE=str(SOURCE),
                   PATH=str(self.tools) + ':' + os.environ['PATH'], ACTION=action,
                   TOKEN='new-secret' if action == 'configure' else '',
                   DDNSTO_OPENWRT_BIN_PATH=str(self.binary),
                   DDNSTO_CONFIG_PATH=str(self.config), DDNSTO_SERVICE_PATH=str(self.service),
                   PACKAGE_MANAGER=manager)
        env.update(extra)
        return subprocess.run(['sh', '-c', '''
set -eu
if [ -f "$SOURCE" ]; then . "$SOURCE"; fi
binary=$DDNSTO_OPENWRT_BIN_PATH
config=$DDNSTO_CONFIG_PATH
service_path=$DDNSTO_SERVICE_PATH
package_manager=$PACKAGE_MANAGER
sleep() { :; }
if [ "$ACTION" = retained ]; then
    ddnsto_openwrt_with_retained_config pinned-reinstall pinned-package
else
    ddnsto_openwrt_lifecycle
fi
'''], env=env, text=True, capture_output=True)

    def calls(self):
        path = self.root / 'calls'
        return path.read_text() if path.exists() else ''

    def main_command(self, *args, **extra):
        env = dict(os.environ, FIXTURE=str(self.root), APP=str(SOURCE.parent),
                   PATH=str(self.tools) + ':' + os.environ['PATH'],
                   DDNSTO_OPENWRT_BIN_PATH=str(self.binary),
                   DDNSTO_CONFIG_PATH=str(self.config), DDNSTO_SERVICE_PATH=str(self.service),
                   DDNSTO_LOCK_DIR=str(self.root / 'machine.lock'), PACKAGE_MANAGER='opkg',
                   ZSETUP_INSTALLER_MODE='0', DDNSTO_MEM_MB='1024')
        env.update(extra)
        return ['sh', '-eu', '-c', MAIN_HARNESS, 'test', *args], env

    def invoke_main(self, *args, **extra):
        command, env = self.main_command(*args, **extra)
        return subprocess.run(command, env=env, text=True, capture_output=True, timeout=10)

    def test_main_initializes_paths_for_configure_and_repair(self):
        for manager in ('opkg', 'apk'):
            for action in ('configure', 'repair'):
                with self.subTest(manager=manager, action=action):
                    args = ['--action', action]
                    if action == 'configure': args += ['--token', 'new-secret']
                    result = self.invoke_main(*args, PACKAGE_MANAGER=manager)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('operation=' + action, result.stdout)
                    self.assertFalse((self.root / 'machine.lock').exists())

    def test_main_nonroot_and_missing_noninteractive_token_do_not_mutate(self):
        for extra, args in (({'FAKE_UID': '1000'}, ['--token', 'new-secret']), ({}, [])):
            result = self.invoke_main('--action', 'configure', *args, **extra)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertEqual(self.config.read_text(), ORIGINAL)
            self.assertNotIn('ddnsto restart', self.calls())

    def test_main_configure_prompts_visibly_for_a_new_token(self):
        command, env = self.main_command('--action', 'configure')
        pid, terminal = pty.fork()
        if pid == 0:
            os.execvpe(command[0], command, env)
        output = b''
        sent = False
        deadline = time.monotonic() + 10
        try:
            while time.monotonic() < deadline:
                if not select.select([terminal], [], [], .1)[0]: continue
                try: part = os.read(terminal, 4096)
                except OSError: break
                if not part: break
                output += part
                if b'DDNSTO token:' in output and not sent:
                    os.write(terminal, b'new-secret\n')
                    sent = True
            else:
                os.kill(pid, 15)
                self.fail('configure token prompt timed out')
        finally:
            os.close(terminal)
            _, status = os.waitpid(pid, 0)
        self.assertEqual(os.waitstatus_to_exitcode(status), 0, output.decode())
        self.assertTrue(sent)
        self.assertIn(b'new-secret', output)
        self.assertIn("option token 'new-secret'", self.config.read_text())

    def test_configure_preserves_identity_and_updates_only_token_enabled(self):
        result = self.run_action('configure')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.config.read_text(), ORIGINAL.replace('old-secret', 'new-secret').replace("enabled '0'", "enabled '1'"))
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)
        self.assertIn('cloud_status=unverified', result.stdout)
        self.assertNotIn('secret', result.stdout + result.stderr)
        self.assertIn('ddnsto restart', self.calls())

    def test_configure_failure_restores_original_and_does_not_leak_token(self):
        for failure in ('set', 'commit', 'enable', 'restart', 'not-running'):
            with self.subTest(failure=failure):
                self.config.write_text(ORIGINAL)
                result = self.run_action('configure', FAIL=failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.config.read_text(), ORIGINAL)
                self.assertNotIn('secret', result.stdout + result.stderr)
                self.assertNotIn('operation=configure', result.stdout)
                self.assertIn('failed', result.stderr)
                self.assertEqual(list(self.config.parent.glob('.ddnsto-lifecycle.*')), [])

    def test_unowned_or_ambiguous_installations_are_rejected_before_mutation(self):
        for manager in ('opkg', 'apk'):
            for owner in ('none', 'ddnsto-external', 'docker', 'ddnsto\nother'):
                with self.subTest(manager=manager, owner=owner):
                    result = self.run_action('configure', manager, OWNER=owner)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(self.config.read_text(), ORIGINAL)
                    self.assertNotIn('ddnsto restart', self.calls())

    def test_invalid_inputs_pending_uci_and_symlinks_do_not_mutate(self):
        for extra in ({'TOKEN': ''}, {'TOKEN': 'bad\ntoken'}, {'TOKEN': 'private token'},
                      {'TOKEN': 'private\ttoken'}, {'PENDING': 'ddnsto.token=pending'},
                      {'FAIL': 'metadata'}, {'REQUESTED_METHOD': 'docker'},
                      {'PACKAGE_MANAGER': 'unknown'}):
            with self.subTest(extra=extra):
                result = self.run_action('configure', **extra)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.config.read_text(), ORIGINAL)
                if extra.get('TOKEN'):
                    self.assertNotIn(extra['TOKEN'], result.stdout + result.stderr)
        saved = self.config.with_name('saved')
        self.config.rename(saved)
        self.config.symlink_to(saved)
        result = self.run_action('configure')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(saved.read_text(), ORIGINAL)
        self.assertTrue(self.config.is_symlink())

    def test_parent_symlink_is_rejected(self):
        original = self.config.parent
        saved = original.with_name('saved-config')
        original.rename(saved)
        original.symlink_to(saved, target_is_directory=True)
        result = self.run_action('configure')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.config.read_text(), ORIGINAL)

    def test_repair_enables_and_restarts_existing_package_without_changing_token(self):
        for manager in ('opkg', 'apk'):
            with self.subTest(manager=manager):
                self.config.write_text(ORIGINAL)
                result = self.run_action('repair', manager)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.config.read_text(), ORIGINAL.replace("enabled '0'", "enabled '1'"))
                self.assertIn('operation=repair', result.stdout)
                self.assertNotIn('remove ', self.calls())
                self.assertNotIn(' add ', self.calls())

    def test_repair_missing_init_requires_explicit_update_and_does_not_create_one(self):
        self.service.unlink()
        result = self.run_action('repair')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('explicit update', result.stderr)
        self.assertFalse(self.service.exists())
        self.assertEqual(self.config.read_text(), ORIGINAL)

    def test_repair_rejects_credentials_missing_token_and_multiple_sections(self):
        result = self.run_action('repair', TOKEN='new-secret')
        self.assertNotEqual(result.returncode, 0)
        for contents in (ORIGINAL.replace("option token 'old-secret'", "option token ''"),
                         ORIGINAL + '\nconfig ddnsto\n', ORIGINAL.replace('config ddnsto', 'config other')):
            self.config.write_text(contents)
            result = self.run_action('repair')
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(self.config.read_text(), contents)

    def test_uninstall_restores_config_after_hooks_and_removes_only_known_packages(self):
        unrelated = self.root / 'etc/ddnsto/device-identity.json'
        unrelated.parent.mkdir()
        unrelated.write_text('retain even unrelated/native state')
        for manager in ('opkg', 'apk'):
            with self.subTest(manager=manager):
                (self.config.parent / '.uninstalled-openwrt-v1').unlink(missing_ok=True)
                (self.root / 'packages').write_text(json.dumps(self.packages))
                result = self.run_action('uninstall', manager)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.config.read_text(), ORIGINAL)
                self.assertEqual(json.loads((self.root / 'packages').read_text()), ['unrelated'])
                self.assertEqual(unrelated.read_text(), 'retain even unrelated/native state')
                self.assertIn('operation=uninstall', result.stdout)
                self.assertIn('config=retained', result.stdout)
                self.assertEqual(list(self.config.parent.glob('.ddnsto-lifecycle.*')), [])

    def test_uninstall_partial_failure_is_explicit_and_config_is_restored(self):
        for manager in ('opkg', 'apk'):
            for failure in ('remove', 'lying-remove', 'post-metadata'):
                with self.subTest(manager=manager, failure=failure):
                    (self.root / 'packages').write_text(json.dumps(self.packages))
                    result = self.run_action('uninstall', manager, FAIL=failure)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(self.config.read_text(), ORIGINAL)
                    self.assertIn('partial', result.stderr)
                    self.assertNotIn('operation=uninstall', result.stdout)

    def test_uninstall_unowned_does_not_remove_packages(self):
        result = self.run_action('uninstall', OWNER='ddnsto-external')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('remove ', self.calls())
        self.assertEqual(self.config.read_text(), ORIGINAL)

    def test_uninstall_stop_failure_never_calls_package_removal(self):
        result = self.run_action('uninstall', FAIL='stop')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('remove ', self.calls())
        self.assertEqual(self.config.read_text(), ORIGINAL)

    def test_uninstall_keeps_recovery_backup_if_config_destination_becomes_unsafe(self):
        (self.root / 'sentinel').write_text('do not overwrite')
        for failure in ('restore-directory', 'restore-symlink'):
            with self.subTest(failure=failure):
                (self.root / 'packages').write_text(json.dumps(self.packages))
                result = self.run_action('uninstall', FAIL=failure)
                self.assertEqual(result.returncode, 14, result.stderr)
                self.assertIn('backup retained', result.stderr)
                backups = list(self.config.parent.glob('.ddnsto-lifecycle.*/original'))
                self.assertTrue(backups)
                self.assertTrue(all(p.read_text() == ORIGINAL for p in backups))
                self.assertEqual((self.root / 'sentinel').read_text(), 'do not overwrite')
                self.assertNotIn('operation=uninstall', result.stdout)
                if self.config.is_symlink(): self.config.unlink()
                else: self.config.rmdir()
                self.config.write_text(ORIGINAL)

    def test_uninstall_broken_package_uses_metadata_without_synthesizing_init(self):
        self.binary.unlink()
        self.service.unlink()
        result = self.run_action('uninstall')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.config.read_text(), ORIGINAL)
        self.assertFalse(self.service.exists())
        self.assertNotIn('ddnsto stop', self.calls())

    def test_repair_waits_for_procd_status(self):
        result = self.run_action('repair', FAIL='slow-start')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('local_service=running', result.stdout)

    def test_signals_restore_config(self):
        for action, failure in (('configure', 'signal-restart'), ('uninstall', 'signal-remove')):
            with self.subTest(action=action):
                result = self.run_action(action, FAIL=failure)
                self.assertEqual(result.returncode, 143, result.stderr)
                self.assertEqual(self.config.read_text(), ORIGINAL)
                self.assertNotIn('operation=' + action, result.stdout)

    def test_malformed_metadata_fails_closed(self):
        for manager, listing in (('opkg', 'ddnsto - 4.2.6-1\ninvalid name - x'),
                                 ('apk', 'ddnsto\ninvalid name')):
            with self.subTest(manager=manager):
                result = self.run_action('uninstall', manager, LISTING=listing)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.config.read_text(), ORIGINAL)
                self.assertNotIn('ddnsto stop', self.calls())

    def test_retained_reinstall_restores_config_after_package_only_callback(self):
        for failure, expected in (('', 0), ('callback', 9)):
            with self.subTest(failure=failure):
                result = self.run_action('retained', FAIL=failure)
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertEqual(self.config.read_text(), ORIGINAL)
                self.assertIn('pinned-reinstall pinned-package', self.calls())
                self.assertNotIn('ddnsto restart', self.calls())
                self.assertEqual(list(self.config.parent.glob('.ddnsto-lifecycle.*')), [])

    def test_main_uninstall_and_retained_reinstall_preserve_identity_and_finish(self):
        self.config.write_text(ORIGINAL.replace("enabled '0'", "enabled '1'"))
        result = self.invoke_main('--action', 'uninstall')
        self.assertEqual(result.returncode, 0, result.stderr)
        marker = self.config.parent / '.uninstalled-openwrt-v1'
        self.assertTrue(marker.is_file(), 'uninstall must retain ownership evidence')
        self.assertIn(str(self.config), marker.read_text())
        self.assertIn(str(self.binary), marker.read_text())
        self.assertNotIn('secret', marker.read_text())
        result = self.invoke_main(RUN_PACKAGES='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('EARLY_START', self.calls())
        self.assertEqual(self.config.read_text(), ORIGINAL.replace("enabled '0'", "enabled '1'"))
        self.assertFalse(marker.exists())
        self.assertTrue(self.binary.is_file())
        self.assertIn('ddnsto restart', self.calls())

    def test_uninstall_rejects_foreign_marker_without_removing_packages(self):
        marker = self.config.parent / '.uninstalled-openwrt-v1'
        marker.write_text('foreign marker')
        result = self.invoke_main('--action', 'uninstall')
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertNotIn('remove ', self.calls())
        self.assertEqual(marker.read_text(), 'foreign marker')

    def test_existing_openwrt_update_preserves_config_and_quiesces_package_hooks(self):
        for manager in ('opkg', 'apk'):
            with self.subTest(manager=manager):
                original = ORIGINAL.replace("enabled '0'", "enabled '1'")
                self.config.write_text(original)
                result = self.invoke_main('--action', 'update', PACKAGE_MANAGER=manager,
                                          RUN_PACKAGES='1', REMOVE_KEEPS_CONFIG='1')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn('EARLY_START', self.calls())
                self.assertEqual(self.config.read_text(), original)
                self.assertIn('ddnsto restart', self.calls())

    def test_update_failure_restores_configuration_without_claiming_package_rollback(self):
        result = self.invoke_main('--action', 'update', RUN_PACKAGES='1', FAIL='package-install')
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertEqual(self.config.read_text(), ORIGINAL)
        self.assertNotIn('packages installed', result.stdout)
        self.assertIn('partial', result.stderr)

    def test_update_preserves_disabled_state(self):
        result = self.invoke_main('--action', 'update', RUN_PACKAGES='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.config.read_text(), ORIGINAL)
        self.assertNotIn('ddnsto restart', self.calls())
        self.assertTrue((self.root / 'stopped').exists())

    def test_fresh_install_configures_only_after_package_hooks(self):
        for manager in ('opkg', 'apk'):
            with self.subTest(manager=manager):
                for path in (self.config, self.binary, self.service): path.unlink(missing_ok=True)
                (self.root / 'packages').write_text('[]')
                result = self.invoke_main('--token', 'new-secret', RUN_PACKAGES='1', PACKAGE_MANAGER=manager)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn('EARLY_START', self.calls())
                self.assertIn("option token 'new-secret'", self.config.read_text())

    def test_missing_files_do_not_authorize_removing_a_registered_external_package(self):
        for path in (self.config, self.binary, self.service): path.unlink()
        result = self.invoke_main(RUN_PACKAGES='1')
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertNotIn('remove ', self.calls())
        self.assertNotIn('download ', self.calls())

    def test_unsafe_marker_created_by_hook_does_not_claim_uninstall_success(self):
        result = self.invoke_main('--action', 'uninstall', FAIL='marker-directory')
        self.assertEqual(result.returncode, 15, result.stderr)
        self.assertEqual(self.config.read_text(), ORIGINAL)
        self.assertNotIn('operation=uninstall', result.stdout)


if __name__ == '__main__':
    unittest.main()
