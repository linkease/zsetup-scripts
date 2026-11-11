"""Isolated file/argv fixtures: never use host dbus, /proc or daemons."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'asus-service.sh'


class AsusServiceTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.jffs = self.root / 'jffs'
        self.state = self.jffs / '.ddnsto-installer'
        self.attempt = self.state / 'attempt'
        self.payload = self.attempt / 'payload'
        self.payload.mkdir(parents=True)
        self.ks = self.jffs / '.koolshare'
        for directory in ('bin', 'scripts', 'init.d', 'webs', 'res'):
            (self.ks / directory).mkdir(parents=True)
        for name in ('ddnsto', 'Module_ddnsto.asp', 'icon-ddnsto.png'):
            (self.payload / name).write_text('verified-' + name)
        (self.ks / 'bin/ddnsto').write_text('verified-ddnsto')
        self.db = self.root / 'db'
        self.db.mkdir()
        for key, value in {'ddnsto_token': 'same-token', 'ddnsto_enable': '1',
                           'ddnsto_version': '4.2.8', 'ddnsto_feat_enabled': '1',
                           'ddnsto_feat_username': 'a b;$(touch INJECTED)',
                           'ddnsto_feat_password': 'x " \\ $HOME',
                           'ddnsto_feat_port': '3303'}.items():
            (self.db / key).write_text(value)
        self.dbus = self.root / 'dbus'
        self.dbus.write_text('#!/usr/bin/python3\nimport os,sys\nfrom pathlib import Path\n'
                             'p=Path(os.environ["DB"])\n'
                             'if sys.argv[1]=="get":\n'
                             ' f=p/sys.argv[2]; print(f.read_text() if f.exists() else "")\n'
                             'elif sys.argv[1]=="set":\n'
                             ' k,v=sys.argv[2].split("=",1); (p/k).write_text(v)\n'
                             'elif sys.argv[1]=="remove":\n'
                             ' (p/sys.argv[2]).unlink(missing_ok=True)\n')
        self.dbus.chmod(0o700)
        self.script = self.root / 'service-source'
        text = SOURCE.read_text() if SOURCE.exists() else ''
        text = text.replace('/jffs', str(self.jffs)).replace('/usr/bin/dbus', str(self.dbus))
        text = text.replace('/proc/', str(self.root / 'proc') + '/')
        # No process enumeration, signal, HTTP or sleep can reach the host.
        fake_pidof = self.root / 'pidof'
        fake_pidof.write_text('#!/usr/bin/python3\nimport os\nfrom pathlib import Path\n'
                              f'p=Path({str(self.root / "proc")!r})\n'
                              'print(" ".join(x.name for x in sorted(p.glob("*"), reverse=bool(os.environ.get("REVERSE_PIDS"))) '
                              'if (x/"exe").is_symlink()))\n')
        fake_pidof.chmod(0o700)
        text = text.replace('$(pidof ddnsto', f'$("{fake_pidof}" ddnsto')
        self.curl = self.root / 'curl'
        self.curl.write_text('#!/usr/bin/python3\nimport os,sys,json\n'
                             'open(os.environ["HTTPLOG"],"w").write(json.dumps(sys.argv[1:]))\n')
        self.curl.chmod(0o700)
        text = text.replace('    curl --noproxy', f'    "{self.curl}" --noproxy')
        self.script.write_text(text)
        self.env = dict(os.environ, DB=str(self.db), ARGLOG=str(self.root / 'argv'),
                        HTTPLOG=str(self.root / 'http'))

    def run_sh(self, body):
        setup = f'''
        . '{self.script}'
        ASUS_STATE='{self.state}'; ASUS_ATTEMPT='{self.attempt}'
        ASUS_CHANNEL=rogsoft; ASUS_ARCH=aarch64
        TOKEN=same-token; asus_existing_token=same-token; asus_version=4.2.8
        ddnsto_asus_private_dir() {{ mkdir -p "$1"; }}
        ddnsto_asus_mktemp() {{ mktemp -d "$1/run.XXXXXXXX"; }}
        ddnsto_asus_safe_file() {{ [ -f "$1" ] && [ ! -L "$1" ]; }}
        ddnsto_asus_hash() {{ sha256sum "$1" | cut -d ' ' -f 1; }}
        ddnsto_asus_package() {{ printf '%s\\n' "https://fixture/$1.tar.gz 4.2.8 hnd 123 pin"; }}
        ddnsto_asus_get() {{ '{self.dbus}' get "$1"; }}
        ddnsto_asus_set() {{ '{self.dbus}' set "$1=$2"; }}
        '''
        return subprocess.run(['sh', '-c', setup + body], env=self.env, cwd=self.root,
                              text=True, capture_output=True, timeout=15)

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_exact_backup_restore_and_unrelated_config(self):
        original = self.ks / 'scripts/ddnsto_config.sh'
        original.write_text('DO NOT EXECUTE original\n')
        original.chmod(0o751)
        link = self.ks / 'init.d/S70ddnsto.sh'
        link.symlink_to('../scripts/ddnsto_config.sh')
        (self.ks / 'scripts/uninstall_ddnsto.sh').write_text('keep uninstall')
        result = self.run_sh('''
        ddnsto_asus_backup_plugin && ddnsto_asus_install_plugin || exit $?
        ddnsto_asus_set ddnsto_feat_username concurrent
        printf 0 > "$ASUS_ATTEMPT/changed/ddnsto_enable"
        ddnsto_asus_set ddnsto_enable 0
        ddnsto_asus_stop() { :; }; ddnsto_asus_start() { :; }; ddnsto_asus_running() { :; }
        ddnsto_asus_restore_plugin
        ''')
        self.assert_ok(result)
        self.assertEqual(original.read_text(), 'DO NOT EXECUTE original\n')
        self.assertEqual(original.stat().st_mode & 0o777, 0o751)
        self.assertEqual(os.readlink(link), '../scripts/ddnsto_config.sh')
        self.assertEqual((self.ks / 'bin/ddnsto').read_text(), 'verified-ddnsto')
        self.assertEqual((self.db / 'ddnsto_feat_username').read_text(), 'concurrent')
        self.assertEqual((self.db / 'ddnsto_enable').read_text(), '1')
        self.assertEqual((self.ks / 'scripts/uninstall_ddnsto.sh').read_text(), 'keep uninstall')
        self.assertTrue((self.attempt / 'backup').is_dir())

    def test_launch_preserves_quoted_features_and_default_disk(self):
        client = self.payload / 'ddnsto'
        client.write_text('#!/usr/bin/python3\nimport os,sys,json\n'
                          'open(os.environ["ARGLOG"],"w").write(json.dumps(sys.argv[1:]))\n')
        (self.ks / 'bin/ddnsto').write_bytes(client.read_bytes())
        result = self.run_sh('''
        ddnsto_asus_backup_plugin && ddnsto_asus_install_plugin && ddnsto_asus_start
        ''')
        self.assert_ok(result)
        self.assertEqual(json.loads((self.root / 'argv').read_text()),
                         ['-u', 'same-token', '-d', '-n', 'a b;$(touch INJECTED)',
                          '-k', 'x " \\ $HOME', '-p', '3303', '-s', '/'])
        self.assertFalse((self.root / 'INJECTED').exists())
        self.assertTrue((self.ks / 'bin/ddnsto').is_symlink())

    def test_symlink_parent_fails_before_write(self):
        outside = self.root / 'outside'
        outside.mkdir()
        (self.ks / 'scripts').rmdir()
        (self.ks / 'scripts').symlink_to(outside)
        self.assertNotEqual(self.run_sh('ddnsto_asus_backup_plugin').returncode, 0)
        self.assertEqual(list(outside.iterdir()), [])

    def test_generated_service_has_no_token_and_no_native_script_execution(self):
        self.assert_ok(self.run_sh('ddnsto_asus_backup_plugin && ddnsto_asus_install_plugin'))
        service = (self.state / 'current/service.sh').read_text()
        self.assertNotIn('same-token', service)
        self.assertNotIn('base.sh', service)
        self.assertNotIn('eval ', service)
        self.assertNotIn('\n    killall ', service)
        for leaf in ('scripts/ddnsto_config.sh', 'scripts/ddnsto_status.sh', 'init.d/S70ddnsto.sh'):
            self.assertIn(str(self.state), (self.ks / leaf).read_text())

    def runtime(self, body):
        return self.run_sh('''
        _ddnsto_asus_runtime > "$ASUS_ATTEMPT/test-runtime"
        set -- library
        . "$ASUS_ATTEMPT/test-runtime"
        sleep() { :; }
        ''' + body)

    def process(self, pid, exe, parent=1, uid=0, birth=100):
        proc = self.root / 'proc' / str(pid)
        proc.mkdir(parents=True, exist_ok=True)
        link = proc / 'exe'
        if link.is_symlink():
            link.unlink()
        link.symlink_to(exe)
        (proc / 'status').write_text(f'Uid:\t{uid}\t{uid}\t{uid}\t{uid}\nPPid:\t{parent}\n')
        fields = ['S', str(parent)] + ['0'] * 17 + [str(birth)]
        (proc / 'stat').write_text(f'{pid} (ddnsto) ' + ' '.join(fields))

    def protected_processes(self):
        runtime = self.attempt / 'runtime'
        runtime.mkdir()
        (runtime / 'ddnsto').write_text('fake process executable')
        (self.state / 'current').symlink_to(runtime)
        self.process(211, runtime / 'ddnsto')
        self.process(212, runtime / 'ddnsto', parent=211)

    def test_migration_stop_without_installed_current(self):
        self.process(211, '/.koolshare/bin/ddnsto')
        self.process(212, '/.koolshare/bin/ddnsto', parent=211)
        self.process(213, '/unrelated/ddnsto')
        self.process(214, '/.koolshare/bin/ddnsto', uid=1000)
        result = self.runtime('''
        kill() { printf '%s\\n' "$2" >> "$ASUS_ATTEMPT/signals";
                 rm -f "''' + str(self.root) + '''/proc/$2/exe"; }
        asus_service_stop legacy
        ''')
        self.assertNotEqual(result.returncode, 0)
        signals = self.attempt / 'signals'
        self.assertEqual(signals.read_text() if signals.exists() else '', '211\n212\n')

    def test_first_migration_stops_verified_main_and_child(self):
        self.process(211, '/.koolshare/bin/ddnsto')
        self.process(212, '/.koolshare/bin/ddnsto', parent=211)
        self.assert_ok(self.runtime('''
        kill() { rm -f "''' + str(self.root) + '''/proc/$2/exe"; }
        asus_service_stop legacy
        '''))

    def test_stop_signals_main_before_webdav_child(self):
        self.protected_processes()
        self.env['REVERSE_PIDS'] = '1'
        self.assert_ok(self.runtime('''
        kill() { printf '%s\\n' "$2" >> "$ASUS_ATTEMPT/signals";
                 rm -f "''' + str(self.root) + '''/proc/$2/exe"; }
        asus_service_stop
        '''))
        self.assertEqual((self.attempt / 'signals').read_text(), '211\n212\n')

    def test_unknown_pid_blocks_start(self):
        self.protected_processes()
        self.process(213, '/unrelated/ddnsto')
        result = self.runtime('asus_service_start')
        self.assertEqual(result.returncode, 1)
        self.assertFalse((self.root / 'argv').exists())

    def test_stable_main_and_child_then_changed_birth_rejected(self):
        self.protected_processes()
        self.assert_ok(self.runtime('asus_service_running'))
        result = self.runtime('''
        sleep() { printf '%s\\n' changed > "''' + str(self.root) + '''/proc/211/stat"; }
        asus_service_running
        ''')
        self.assertNotEqual(result.returncode, 0)

    def test_child_alone_and_duplicate_main_are_not_success(self):
        self.protected_processes()
        self.process(211, self.attempt / 'runtime/ddnsto', parent=99)
        self.assertNotEqual(self.runtime('asus_service_running').returncode, 0)
        self.process(211, self.attempt / 'runtime/ddnsto')
        self.process(212, self.attempt / 'runtime/ddnsto')
        self.assertNotEqual(self.runtime('asus_service_running').returncode, 0)

    def test_status_json_and_request_id(self):
        self.protected_processes()
        self.query_client('4.2.8 aabbccddeeff\n')
        username = 'name"\\\n\tend'
        (self.db / 'ddnsto_feat_username').write_text(username)
        result = self.runtime('sleep() { /bin/sleep "$@"; }; asus_service_status 123')
        self.assert_ok(result)
        argv = json.loads((self.root / 'http').read_text())
        payload = json.loads(argv[argv.index('--data-binary') + 1])
        self.assertEqual(payload['status'], 1)
        self.assertEqual(payload['router_id'], 'aabbccddeeff')
        self.assertEqual(payload['feat']['status'], '1')
        self.assertEqual(payload['feat']['username'], username)
        self.assertEqual(argv[-1], 'http://127.0.0.1:3030/_resp/123')
        self.assertNotIn('password', json.dumps(payload))
        self.assertNotEqual(self.runtime("asus_service_status '../bad'").returncode, 0)

    def query_client(self, output='', hang=False):
        runtime = self.attempt / 'runtime'
        runtime.mkdir(exist_ok=True)
        current = self.state / 'current'
        if not current.is_symlink():
            current.symlink_to(runtime)
        client = runtime / 'ddnsto'
        client.write_text('#!/usr/bin/python3\nimport sys,time,os,json\n'
                          'open(os.environ["ARGLOG"],"w").write(json.dumps(sys.argv[1:]))\n'
                          + ('time.sleep(20)\n' if hang else '')
                          + f'sys.stdout.write({output!r})\n')
        client.chmod(0o700)

    def test_router_id_query_only_uses_w_and_rejects_invalid_output(self):
        for output in ('', '4.2.8 $(touch_INJECTED)\n',
                       '4.2.8 aabbccddeeff extra\n',
                       '4.2.8 aabbccddeeff\n4.2.8 aabbccddeeff\n',
                       '4.2.8 abcd\n', '4.2.8 aabbccddeeff' + ' ' * 2048):
            with self.subTest(output=output[:60]):
                self.query_client(output)
                result = self.runtime('sleep() { /bin/sleep "$@"; }; asus_service_router_id')
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')
                self.assertTrue((self.root / 'argv').exists(), result.stderr)
                self.assertEqual(json.loads((self.root / 'argv').read_text()), ['-w'])
        self.assertFalse((self.root / 'INJECTED').exists())

    def test_router_id_hung_query_is_bounded_and_cleaned(self):
        import time
        self.query_client(hang=True)
        start = time.monotonic()
        result = self.run_sh('''
        _ddnsto_asus_runtime > "$ASUS_ATTEMPT/test-runtime"
        set -- library; . "$ASUS_ATTEMPT/test-runtime"
        asus_service_router_id
        ''')
        self.assertNotEqual(result.returncode, 0)
        self.assertLess(time.monotonic() - start, 7)
        self.assertEqual(result.stdout, '')
        self.assertFalse((self.state / 'router-query.lock').exists())

    def test_controlled_uninstall_removes_exact_owned_files_keeps_backups(self):
        (self.ks / 'scripts/uninstall_ddnsto.sh').write_text('unsafe native uninstall')
        (self.ks / 'bin/ddnsto-other').write_text('unrelated')
        (self.db / 'unrelated_setting').write_text('keep')
        result = self.run_sh('''
        ddnsto_asus_backup_plugin && ddnsto_asus_install_plugin || exit $?
        /bin/sh "''' + str(self.ks) + '''/scripts/uninstall_ddnsto.sh"
        ''')
        self.assert_ok(result)
        self.assertEqual(list((self.ks / 'scripts').iterdir()), [])
        self.assertEqual(list((self.ks / 'init.d').iterdir()), [])
        self.assertEqual(list((self.ks / 'webs').iterdir()), [])
        self.assertEqual((self.ks / 'bin/ddnsto-other').read_text(), 'unrelated')
        self.assertEqual((self.db / 'unrelated_setting').read_text(), 'keep')
        self.assertFalse((self.db / 'ddnsto_token').exists())
        self.assertFalse((self.db / 'softcenter_module_ddnsto_install').exists())
        self.assertEqual((self.attempt / 'backup/files/uninstall_ddnsto.sh').read_text(),
                         'unsafe native uninstall')

    def test_uninstall_refuses_changed_file_and_unknown_process(self):
        self.assert_ok(self.run_sh('ddnsto_asus_backup_plugin && ddnsto_asus_install_plugin'))
        path = self.ks / 'webs/Module_ddnsto.asp'
        path.write_text('concurrently replaced')
        result = subprocess.run(['sh', str(self.ks / 'scripts/uninstall_ddnsto.sh')],
                                env=self.env, text=True, capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(path.read_text(), 'concurrently replaced')
        self.assertTrue((self.ks / 'bin/ddnsto').is_symlink())
        path.write_bytes((self.payload / 'Module_ddnsto.asp').read_bytes())
        self.process(213, '/unknown/ddnsto')
        result = subprocess.run(['sh', str(self.ks / 'scripts/uninstall_ddnsto.sh')],
                                env=self.env, text=True, capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.ks / 'bin/ddnsto').is_symlink())

    def test_unreviewed_enabled_binary_rejected_before_stop(self):
        (self.ks / 'bin/ddnsto').write_text('untrusted executable')
        result = self.run_sh('ddnsto_asus_backup_plugin')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('reviewed recovery', result.stderr)
        self.assertEqual((self.ks / 'bin/ddnsto').read_text(), 'untrusted executable')

    def test_partial_install_restores_only_marked_files(self):
        result = self.run_sh('''
        ddnsto_asus_backup_plugin || exit $?
        ddnsto_asus_stop() { :; }; ddnsto_asus_start() { :; }; ddnsto_asus_running() { :; }
        printf changed > "''' + str(self.ks) + '''/scripts/ddnsto_config.sh"
        : > "$ASUS_ATTEMPT/changed/ddnsto_config.sh"
        printf concurrent > "''' + str(self.ks) + '''/webs/Module_ddnsto.asp"
        ddnsto_asus_restore_plugin
        ''')
        self.assert_ok(result)
        self.assertFalse((self.ks / 'scripts/ddnsto_config.sh').exists())
        self.assertEqual((self.ks / 'webs/Module_ddnsto.asp').read_text(), 'concurrent')

    def test_restore_does_not_write_unmarked_account_fields(self):
        result = self.run_sh('''
        ddnsto_asus_backup_plugin && ddnsto_asus_install_plugin || exit $?
        ddnsto_asus_set ddnsto_token external-account
        ddnsto_asus_set ddnsto_enable 0
        ddnsto_asus_stop() { :; }; ddnsto_asus_start() { :; }; ddnsto_asus_running() { :; }
        ddnsto_asus_restore_plugin
        ''')
        self.assert_ok(result)
        self.assertEqual((self.db / 'ddnsto_token').read_text(), 'external-account')
        self.assertEqual((self.db / 'ddnsto_enable').read_text(), '0')

    def test_restore_preserves_external_account_write_and_reports_failure(self):
        result = self.run_sh('''
        ddnsto_asus_backup_plugin && ddnsto_asus_install_plugin || exit $?
        printf same-token > "$ASUS_ATTEMPT/changed/ddnsto_token"
        printf 1 > "$ASUS_ATTEMPT/changed/ddnsto_enable"
        ddnsto_asus_set ddnsto_token external-account
        ddnsto_asus_set ddnsto_enable 0
        ddnsto_asus_stop() { :; }
        ddnsto_asus_start() { printf started > "$ASUS_ATTEMPT/restarted"; }
        ddnsto_asus_restore_plugin
        ''')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('concurrent account/enable change', result.stderr)
        self.assertEqual((self.db / 'ddnsto_token').read_text(), 'external-account')
        self.assertEqual((self.db / 'ddnsto_enable').read_text(), '0')
        self.assertFalse((self.attempt / 'restarted').exists())

    def test_config_bridge_numeric_request_uses_dbus_and_posts_ack(self):
        client = self.payload / 'ddnsto'
        client.write_text('#!/usr/bin/python3\nimport os,sys,json\n'
                          'open(os.environ["ARGLOG"],"w").write(json.dumps(sys.argv[1:]))\n')
        (self.ks / 'bin/ddnsto').write_bytes(client.read_bytes())
        self.assert_ok(self.run_sh('ddnsto_asus_backup_plugin && ddnsto_asus_install_plugin'))
        result = subprocess.run(['sh', str(self.ks / 'scripts/ddnsto_config.sh'), '123'],
                                env=self.env, text=True, capture_output=True, timeout=10)
        self.assert_ok(result)
        argv = json.loads((self.root / 'argv').read_text())
        self.assertEqual(argv[1], 'same-token')
        http = json.loads((self.root / 'http').read_text())
        self.assertEqual(http[http.index('--data-binary') + 1], '123')
        self.assertEqual(http[-1], 'http://127.0.0.1:3030/_resp/123')
        before = (self.root / 'argv').read_bytes()
        result = subprocess.run(['sh', str(self.ks / 'scripts/ddnsto_config.sh'), 'bad;id'],
                                env=self.env, text=True, capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root / 'argv').read_bytes(), before)

    def test_config_bridge_respects_installer_lock(self):
        client = self.payload / 'ddnsto'
        client.write_text('#!/bin/sh\nprintf called > "$ARGLOG"\n')
        (self.ks / 'bin/ddnsto').write_bytes(client.read_bytes())
        self.assert_ok(self.run_sh('ddnsto_asus_backup_plugin && ddnsto_asus_install_plugin'))
        (self.state / 'install.lock').mkdir()
        result = subprocess.run(['sh', str(self.ks / 'scripts/ddnsto_config.sh'), '123'],
                                env=self.env, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 16)
        self.assertFalse((self.root / 'argv').exists())
        self.assertTrue((self.state / 'install.lock').is_dir())

    def test_missing_originals_removed_on_disabled_fresh_rollback(self):
        (self.ks / 'bin/ddnsto').unlink()
        (self.db / 'ddnsto_enable').write_text('0')
        result = self.run_sh('''
        ddnsto_asus_backup_plugin && ddnsto_asus_install_plugin || exit $?
        ddnsto_asus_stop() { :; }
        ddnsto_asus_restore_plugin
        ''')
        self.assert_ok(result)
        self.assertFalse((self.state / 'current').is_symlink())
        for directory in ('bin', 'scripts', 'init.d', 'webs', 'res'):
            self.assertEqual(list((self.ks / directory).iterdir()), [])

    def test_parent_swap_during_publish_does_not_write_outside(self):
        outside = self.root / 'outside'
        outside.mkdir()
        result = self.run_sh('''
        ddnsto_asus_backup_plugin || exit $?
        rmdir "''' + str(self.ks) + '''/webs"
        ln -s "''' + str(outside) + '''" "''' + str(self.ks) + '''/webs"
        ddnsto_asus_install_plugin
        ''')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(outside.iterdir()), [])

    def test_publish_leaf_symlink_to_directory_is_replaced_not_followed(self):
        outside = self.root / 'outside'
        outside.mkdir()
        (self.ks / 'scripts/ddnsto_config.sh').symlink_to(outside)
        result = self.run_sh('''
        mv() { for arg do [ "$arg" != -fT ] && [ "$arg" != -T ] || return 90; done
               /bin/mv "$@"; }
        ddnsto_asus_backup_plugin && ddnsto_asus_install_plugin
        ''')
        self.assert_ok(result)
        self.assertEqual(list(outside.iterdir()), [])
        self.assertIn(str(self.state), os.readlink(self.ks / 'scripts/ddnsto_config.sh'))

    def test_publish_leaf_directory_fails_without_nested_write(self):
        result = self.run_sh('''
        ddnsto_asus_backup_plugin || exit $?
        mkdir "''' + str(self.ks) + '''/scripts/ddnsto_config.sh"
        ddnsto_asus_install_plugin
        ''')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list((self.ks / 'scripts/ddnsto_config.sh').iterdir()), [])

    def test_managed_runtime_reuse_and_binary_tampering(self):
        result = self.run_sh('''
        ddnsto_asus_backup_plugin && ddnsto_asus_install_plugin || exit $?
        ddnsto_asus_reusable
        ''')
        self.assert_ok(result)
        runtime = self.attempt / 'runtime'
        self.assertTrue((runtime / 'binary.sha256').is_file())
        self.assertTrue((runtime / 'source-pin').is_file())
        before = sorted(str(p.relative_to(self.root)) for p in self.root.rglob('*'))
        self.assert_ok(self.run_sh('ddnsto_asus_reusable'))
        self.assertEqual(before, sorted(str(p.relative_to(self.root)) for p in self.root.rglob('*')))
        (runtime / 'ddnsto').write_text('tampered')
        self.assertNotEqual(self.run_sh('ddnsto_asus_reusable').returncode, 0)

    def test_reuse_rejects_changed_pin_service_or_unmanaged_current(self):
        self.assert_ok(self.run_sh('ddnsto_asus_backup_plugin && ddnsto_asus_install_plugin'))
        runtime = self.attempt / 'runtime'
        for name in ('source-pin', 'binary.sha256', 'service.sh'):
            with self.subTest(name=name):
                original = (runtime / name).read_bytes()
                (runtime / name).write_bytes(original + b'changed\n')
                self.assertNotEqual(self.run_sh('ddnsto_asus_reusable').returncode, 0)
                (runtime / name).write_bytes(original)
        self.assertNotEqual(self.run_sh('ASUS_CHANNEL=mtksoft; ddnsto_asus_reusable').returncode, 0)
        (self.db / 'ddnsto_version').write_text('4.2.7')
        self.assertNotEqual(self.run_sh('ddnsto_asus_reusable').returncode, 0)
        (self.db / 'ddnsto_version').write_text('4.2.8')
        (self.state / 'current').unlink()
        (self.state / 'current').symlink_to(self.ks)
        self.assertNotEqual(self.run_sh('ddnsto_asus_reusable').returncode, 0)


if __name__ == '__main__':
    unittest.main()
