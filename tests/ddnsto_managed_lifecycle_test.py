"""Isolated native lifecycle contract. Run ONLY in a dedicated disposable container.

Set DDNSTO_LIFECYCLE_SANDBOX=1 and create /ddnsto-lifecycle-sandbox there.
DDNSTO_TEST_NATIVE points at the published 0.5.0 executable. No product runs.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
PREFIX = Path('/opt/linkease/ddnsto')
UNIT = Path('/etc/systemd/system/com.linkease.ddnstoshell.service')
CONFIG = Path('/etc/ddnsto/ddnsto-config.json')
FIXTURE = Path('/ddnsto-lifecycle-sandbox')
NATIVE = os.environ.get('DDNSTO_TEST_NATIVE', '/fixture/zsetup')
ENABLED = os.environ.get('DDNSTO_LIFECYCLE_SANDBOX') == '1' and FIXTURE.is_dir()

SYSTEMCTL = r'''#!/usr/bin/python3
import json, os, sys
from pathlib import Path
p = Path('/ddnsto-lifecycle-sandbox/state.json')
s = json.loads(p.read_text())
a = sys.argv[1:]; op = a[0]
unit = '/etc/systemd/system/com.linkease.ddnstoshell.service'
wrapper = '/opt/linkease/ddnsto/versions/4.2.8/bin/.service-run'
if op == 'show':
    prop = next(x.split('=', 1)[1] for x in a if x.startswith('--property='))
    defaults = dict(FragmentPath=unit if Path(unit).is_file() else '',
        LoadState='loaded' if Path(unit).is_file() else 'not-found',
        ActiveState=s['active'], UnitFileState=s['enabled'], NeedDaemonReload='no',
        ExecStart='{ path=/bin/sh ; argv[]=/bin/sh ' + wrapper + ' ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }' if Path(unit).is_file() else '')
    print(s.get('properties', {}).get(prop, defaults.get(prop, '')))
    sys.exit(0)
if op == 'is-active': sys.exit(0 if s['active'] == 'active' else 3)
if op == 'is-enabled': sys.exit(0 if s['enabled'] == 'enabled' else 1)
with open('/ddnsto-lifecycle-sandbox/calls', 'a') as f: f.write(op + '\n')
if s.get('fail') == op:
    if not s.get('persistent'): s.pop('fail'); p.write_text(json.dumps(s))
    sys.exit(9)
if op in ('start', 'restart'): s['active'] = 'active'
elif op == 'stop': s['active'] = 'inactive'
elif op == 'enable': s['enabled'] = 'enabled'
elif op == 'disable': s['enabled'] = 'disabled'
elif op != 'daemon-reload': sys.exit(98)
p.write_text(json.dumps(s))
'''


@unittest.skipUnless(ENABLED, 'requires explicitly marked disposable container')
class ManagedLifecycle(unittest.TestCase):
    def setUp(self):
        self.assertEqual(os.geteuid(), 0)
        # These fixed paths are touched only after the explicit sandbox guard.
        if PREFIX.exists(): shutil.rmtree(PREFIX)
        UNIT.unlink(missing_ok=True)
        global_lock = Path('/etc/zsetup/install-locks/ddnsto')
        if global_lock.exists(): shutil.rmtree(global_lock)
        (FIXTURE / 'state.json').unlink(missing_ok=True)
        CONFIG.parent.mkdir(parents=True, exist_ok=True)
        self.original = b'{ "token": "old", "deviceId": 123, "nested": {"keep":true} }\n'
        CONFIG.write_bytes(self.original)
        CONFIG.chmod(0o600)
        binary = PREFIX / 'versions/4.2.8/bin'
        binary.mkdir(parents=True)
        (binary / 'ddnsto').write_text('#!/bin/sh\nexit 97\n')
        (binary / 'ddnsto').chmod(0o755)
        (binary / '.service-run').write_text(f"#!/bin/sh\nexec '{binary}/ddnsto' run\n")
        (binary / '.service-run').chmod(0o755)
        (binary.parent / '.files').write_text('.service-run\nddnsto\n')
        (binary.parent / '.arch').write_text('x86_64\n')
        (binary.parent / '.artifact-sha256').write_text('3bf7ada14448b5aa04afa171e497f85d0b8bb4adcf2209991e52ef5826d4e975\n')
        (PREFIX / '.managed').write_text('ddnsto\n')
        (PREFIX / 'current').symlink_to('versions/4.2.8')
        UNIT.parent.mkdir(parents=True, exist_ok=True)
        UNIT.write_text(f'[Unit]\nDescription=DdnstoShell Service\n[Service]\nExecStart=/bin/sh "{binary}/.service-run"\nRestart=always\n[Install]\nWantedBy=multi-user.target\n')
        (FIXTURE / 'bin').mkdir(exist_ok=True)
        (FIXTURE / 'bin/systemctl').write_text(SYSTEMCTL)
        (FIXTURE / 'bin/systemctl').chmod(0o755)
        (FIXTURE / 'calls').write_text('')
        self.state(active='inactive', enabled='disabled')

    def state(self, **values):
        path = FIXTURE / 'state.json'
        old = json.loads(path.read_text()) if path.exists() else {}
        old.update(values)
        path.write_text(json.dumps(old))

    def run_action(self, action, setup='', health=0):
        sources = ['lib/install-storage.sh', 'lib/install-bounds.sh',
                   'lib/install-transaction.sh', 'lib/install-service.sh',
                   'ddnsto/product-pins.sh', 'ddnsto/managed-service.sh']
        script = 'set -eu\n' + ''.join(f'. "{ROOT / p}"\n' for p in sources)
        script += f'''
ZSETUP_BIN='{NATIVE}'; detected_platform=linux; ACTION=$1; TOKEN='new-token'
ddnsto_error() {{ printf '%s\\n' "$*" >&2; }}
status() {{ :; }}
ddnsto_service_health() {{ return {health}; }}
{setup}
ddnsto_managed_action
'''
        return subprocess.run(['sh', '-c', script, 'test', action], text=True,
                              capture_output=True, timeout=30,
                              env={**os.environ, 'PATH': f'{FIXTURE}/bin:/usr/bin:/bin'})

    def assert_clean(self):
        self.assertFalse((PREFIX / '.service-lock').exists())
        self.assertFalse((PREFIX / '.staging/.install-lock').exists())
        self.assertEqual(list((PREFIX / '.staging').glob('.transaction.*')), [])
        self.assertFalse(Path('/etc/zsetup/install-locks/ddnsto').exists())

    def test_start_and_restart_enable_stop_disables(self):
        for action in ('start', 'stop', 'restart'):
            result = self.run_action(action)
            self.assertEqual(result.returncode, 0, result.stderr)
            state = json.loads((FIXTURE / 'state.json').read_text())
            self.assertEqual(state['active'], 'inactive' if action == 'stop' else 'active')
            self.assertEqual(state['enabled'], 'disabled' if action == 'stop' else 'enabled')
            self.assert_clean()

    def test_configure_preserves_identity_and_rolls_back_exact_bytes(self):
        result = self.run_action('configure')
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = json.loads(self.original); expected['token'] = 'new-token'
        self.assertEqual(json.loads(CONFIG.read_bytes()), expected)
        CONFIG.write_bytes(self.original)
        result = self.run_action('configure', health=13)
        self.assertEqual(result.returncode, 13, result.stderr)
        self.assertEqual(CONFIG.read_bytes(), self.original)
        self.assert_clean()

    def test_failed_start_restores_stopped_disabled_state(self):
        self.state(fail='start')
        result = self.run_action('start')
        self.assertEqual(result.returncode, 9, result.stderr)
        state = json.loads((FIXTURE / 'state.json').read_text())
        self.assertEqual((state['active'], state['enabled']), ('inactive', 'disabled'))
        self.assert_clean()

    def test_failed_rollback_retains_snapshots_and_both_locks(self):
        self.state(active='active', enabled='enabled', fail='start', persistent=True)
        result = self.run_action('configure')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('recovery incomplete', result.stderr)
        self.assertTrue((PREFIX / '.service-lock').is_dir())
        self.assertTrue((PREFIX / '.staging/.install-lock').is_dir())
        backups = list((PREFIX / '.staging').glob('.transaction.*/old-config'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), self.original)

    def test_repair_only_missing_unit_without_product_execution(self):
        before = UNIT.read_bytes()
        result = self.run_action('repair')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(UNIT.read_bytes(), before)
        UNIT.unlink()
        self.state(active='inactive', enabled='disabled')
        result = self.run_action('repair')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('ExecStart=/bin/sh', UNIT.read_text())
        self.assertEqual(CONFIG.read_bytes(), self.original)
        self.assert_clean()

    def test_unsafe_effective_units_rejected_before_mutation(self):
        for prop, value in [('DropInPaths', '/evil.conf'), ('ExecStop', '/evil'),
                            ('NeedDaemonReload', 'yes'), ('FragmentPath', '/foreign'),
                            ('ExecStart', '{ path=/evil ; argv[]=/evil ; }'),
                            ('Environment', 'LD_PRELOAD=/evil'), ('RootImage', '/evil')]:
            with self.subTest(prop=prop):
                self.state(properties={prop: value})
                result = self.run_action('stop')
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((FIXTURE / 'calls').read_text(), '')
                self.assert_clean()

    def test_receipt_wrapper_and_unknown_entry_rejected(self):
        for relative in ('versions/4.2.8/.files', 'versions/4.2.8/bin/.service-run'):
            path = PREFIX / relative; original = path.read_bytes()
            path.write_text('foreign\n')
            result = self.run_action('start')
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((FIXTURE / 'calls').read_text(), '')
            path.write_bytes(original)
        (PREFIX / 'versions/4.2.8/bin/unknown').write_text('unknown')
        self.assertNotEqual(self.run_action('start').returncode, 0)

    def test_lock_is_not_bypassed_by_inherited_flag(self):
        lock = PREFIX / '.service-lock'; lock.mkdir(); (lock / 'owner').write_text('999\n')
        result = self.run_action('stop', 'SERVICE_DEST_LOCK_HELD=1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((lock / 'owner').read_text(), '999\n')
        self.assertEqual((FIXTURE / 'calls').read_text(), '')

    def test_uninstall_retains_config_and_reversible_backup(self):
        before = UNIT.read_bytes()
        result = self.run_action('uninstall')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(UNIT.exists())
        self.assertFalse((PREFIX / 'current').exists())
        self.assertFalse((PREFIX / '.managed').exists())
        self.assertEqual(CONFIG.read_bytes(), self.original)
        backup = next(PREFIX.glob('.uninstalled.*'))
        self.assertEqual((backup / 'unit').read_bytes(), before)
        self.assertTrue((backup / 'versions/4.2.8/bin/ddnsto').is_file())
        self.assertEqual((backup / 'config').read_bytes(), self.original)
        self.assert_clean()

    def test_global_lock_conflict_preserved(self):
        lock = Path('/etc/zsetup/install-locks/ddnsto')
        lock.mkdir(parents=True); (lock / 'owner').write_text('docker-owner\n')
        result = self.run_action('stop')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((lock / 'owner').read_text(), 'docker-owner\n')
        self.assertEqual((FIXTURE / 'calls').read_text(), '')

    def test_install_prepare_joins_global_lock_before_snapshots(self):
        Path('/run/systemd/system').mkdir(parents=True, exist_ok=True)
        lock = Path('/etc/zsetup/install-locks/ddnsto')
        lock.mkdir(parents=True); (lock / 'owner').write_text('docker-owner\n')
        result = self.run_action('install', '''
installer_storage_check() { :; }
installer_service_prepare ddnsto
exit $?
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((lock / 'owner').read_text(), 'docker-owner\n')
        self.assertFalse((PREFIX / '.service-lock').exists())
        self.assertEqual(list((PREFIX / '.staging').glob('.transaction.*/old-unit')), [])

    def test_uninstall_failure_restores_and_unknown_entries_are_preserved(self):
        self.state(active='active', enabled='enabled', fail='daemon-reload')
        result = self.run_action('uninstall')
        self.assertEqual(result.returncode, 9, result.stderr)
        self.assertTrue(UNIT.is_file())
        self.assertTrue((PREFIX / 'current/bin/ddnsto').is_file())
        self.assertEqual(CONFIG.read_bytes(), self.original)
        self.assert_clean()
        # A retained recovery backup is itself a conflict, never deleted by a
        # second uninstall. Unknown content outside the receipt also survives.
        unknown = PREFIX / 'unknown'; unknown.write_text('retain me')
        (FIXTURE / 'calls').write_text('')
        result = self.run_action('uninstall')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(unknown.read_text(), 'retain me')
        self.assertEqual((FIXTURE / 'calls').read_text(), '')

    def test_repair_rejects_stale_loaded_or_symlink_unit(self):
        UNIT.unlink()
        self.state(properties={'FragmentPath': str(UNIT), 'LoadState': 'loaded'})
        self.assertNotEqual(self.run_action('repair').returncode, 0)
        self.state(properties={})
        UNIT.symlink_to('/missing')
        self.assertNotEqual(self.run_action('repair').returncode, 0)
        self.assertEqual((FIXTURE / 'calls').read_text(), '')

    def test_configure_rejects_multiple_objects_before_stopping(self):
        CONFIG.write_text('{"token":"x"}\n{"token":"y"}')
        result = self.run_action('configure')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((FIXTURE / 'calls').read_text(), '')
        self.assert_clean()

    def test_health_ignores_curl_config_and_proxy_environment(self):
        address = CONFIG.parent / '.ddnsto_http_addr.json'
        address.write_text('{"addr":"127.0.0.1:12345","pid":123,"startedAt":"fixture"}')
        curl = FIXTURE / 'bin/curl'
        curl.write_text('''#!/bin/sh
[ "$1" = -q ] || exit 90
[ "$2" = --noproxy ] && [ "$3" = '*' ] || exit 91
[ -z "${http_proxy:-}${HTTP_PROXY:-}${ALL_PROXY:-}" ] || exit 92
printf ok
''')
        curl.chmod(0o755)
        try:
            result = self.run_action('status', '''
SERVICE_CONFIG=/etc/ddnsto/ddnsto-config.json
SERVICE_EXEC=/opt/linkease/ddnsto/versions/4.2.8/bin/ddnsto
transaction_dir=/ddnsto-lifecycle-sandbox
readlink() { printf '%s\\n' "$SERVICE_EXEC"; }
http_proxy=http://invalid; HTTP_PROXY=http://invalid; ALL_PROXY=http://invalid
export http_proxy HTTP_PROXY ALL_PROXY
ddnsto_managed_health_probe
exit $?
''')
            self.assertEqual(result.returncode, 0, result.stderr)
        finally:
            curl.unlink(); address.unlink()

    def test_install_lock_rejects_effective_hooks_before_activation(self):
        Path('/run/systemd/system').mkdir(parents=True, exist_ok=True)
        self.state(properties={'ExecStop': '/foreign'})
        result = self.run_action('update', '''
installer_storage_check() { :; }
installer_service_prepare ddnsto
installer_transaction_finish
exit 0
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((FIXTURE / 'calls').read_text(), '')

    def test_owner_marker_requires_exact_receipt(self):
        (PREFIX / '.managed').write_text('ddnsto\nforeign\n')
        result = self.run_action('stop')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((FIXTURE / 'calls').read_text(), '')

    def test_nonroot_requires_explicit_root_shell(self):
        result = self.run_action('start', '''
native() { case "$*" in 'storage / get effective_uid') echo 1000;; *) "$REAL_NATIVE" "$@";; esac; }
REAL_NATIVE=$ZSETUP_BIN; ZSETUP_BIN=native
''')
        self.assertEqual(result.returncode, 2)
        self.assertIn('root shell', result.stderr)
        self.assertNotIn('sudo -v', result.stderr)
        self.assertEqual((FIXTURE / 'calls').read_text(), '')


if __name__ == '__main__':
    unittest.main()
