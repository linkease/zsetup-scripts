"""Public jq installer contracts; platform plans do not imply native execution."""
import os
import hashlib
import http.server
import json
from pathlib import Path
import shutil
import ssl
import subprocess
import sys
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[2]
NATIVE = sys.argv.pop(1) if len(sys.argv) > 1 and not sys.argv[1].startswith('-') else None
sys.path.insert(0, str(ROOT/'tests'))
from tls_fixture import generate_certificate


class Handler(http.server.BaseHTTPRequestHandler):
    body = b''
    def do_GET(self):
        self.send_response(200); self.send_header('Content-Length', str(len(self.body)))
        self.end_headers(); self.wfile.write(self.body)
    def log_message(self, *_):
        pass


class JqInstallerTests(unittest.TestCase):
    def test_catalog_registers_windows_native_entry_and_unix_shell_entry(self):
        rows=[x for x in json.loads((ROOT/'catalog.json').read_text())['installers'] if x['application']=='jq']
        self.assertTrue(rows)
        for platform in ['linux','ubuntu','debian','istoreos','macos','windows']:
            selected=[x for x in rows if x['os']==platform and x['arch']=='x86_64']
            self.assertEqual(len(selected),1,(platform,selected))
            self.assertTrue(selected[0]['script'].endswith('.ps1' if platform=='windows' else '.sh'))

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='jq installer 中文 ')
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)

    def fixture(self, platform='linux', complete=True):
        self.assertTrue(NATIVE, 'pass the native zsetup executable as the first argument')
        generate_certificate(self.work)
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(self.work/'server.crt',self.work/'server.key')
        server.socket = tls.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever); thread.start()
        self.addCleanup(lambda: (server.shutdown(), server.server_close(), thread.join()))
        Handler.body = ('#!/bin/sh\nif [ "$1" = --version ]; then echo jq-1.8.2; exit 0; fi\nexec '+shutil.which('jq')+' "$@"\n').encode()
        if not complete:
            Handler.body=b'#!/bin/sh\nif [ "$1" = --version ]; then echo jq-1.8.2; exit 0; fi\necho "no ONIGURUMA" >&2\nexit 5\n'
        lock = json.loads((ROOT/'jq/artifacts.lock.json').read_text())
        a = lock['artifacts'][platform+':amd64']; a['sha256']=hashlib.sha256(Handler.body).hexdigest(); a['size']=len(Handler.body)
        (self.work/'lock.json').write_text(json.dumps(lock))
        subprocess.run(['python3',str(ROOT/'jq/build.py'),'--lock',str(self.work/'lock.json'),'--output-dir',str(self.work/'entry')],check=True)
        self.home=self.work/'home';self.home.mkdir()
        self.env={**os.environ,'HOME':str(self.home),'ZSETUP_ROOT':str(self.work/'core'),
            'ZSETUP_INSTALLER_MODE':'1','ZSETUP_BIN':NATIVE,'ZSETUP_OS':platform,'ZSETUP_ARCH':'x86_64',
            'ZSETUP_CA_FILE':str(self.work/'ca.crt'),'JQ_DOWNLOAD_BASE':f'https://127.0.0.1:{server.server_port}'}

    def install(self, *args):
        return subprocess.run(['sh',str(self.work/'entry/jq-install.sh'),*args],env=self.env,text=True,capture_output=True,timeout=15)

    def test_plan_has_pinned_native_artifact_without_requiring_jq_or_writing_home(self):
        cases = [('linux', 'x86_64', 'jq-linux-amd64'),
                 ('istoreos', 'aarch64', 'jq-linux-arm64'),
                 ('macos', 'arm64', 'jq-macos-arm64'),
                 ('windows', 'x86_64', 'jq-windows-amd64.exe')]
        with tempfile.TemporaryDirectory() as folder:
            for platform, arch, artifact in cases:
                result = subprocess.run(['sh', str(ROOT / 'jq/jq-install.sh'), '--plan'],
                    env={**os.environ, 'HOME': folder, 'ZSETUP_INSTALLER_MODE': '1',
                         'ZSETUP_OS': platform, 'ZSETUP_ARCH': arch},
                    text=True, capture_output=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('artifact=' + artifact, result.stdout)
                self.assertIn('version=1.8.2', result.stdout)
                self.assertRegex(result.stdout, r'sha256=[a-f0-9]{64}')
                self.assertEqual(list(Path(folder).iterdir()), [])

    def test_install_uses_native_verified_download_and_reuses_owned_command(self):
        self.fixture()
        p=self.install()
        self.assertEqual(p.returncode,0,p.stderr)
        binary=self.home/'.local/bin/jq'
        actual=subprocess.check_output([str(binary),'-nc','{unicode:"中文",regex:("abc"|test("^a"))}'],text=True)
        self.assertEqual(json.loads(actual),{'unicode':'中文','regex':True})
        self.assertEqual(self.install().returncode,0)
        self.assertEqual((self.home/'.local/lib/linkease/jq/current').read_text().strip(),'1.8.2')

    def test_explicit_command_path_keeps_binary_and_entry_on_selected_data_volume(self):
        self.fixture()
        prefix = self.work / 'data' / 'jq'
        command = self.work / 'data' / 'commands' / 'jq'
        result = self.install('--installer-prefix', str(prefix), '--installer-command', str(command))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(command.is_file())
        self.assertFalse((self.home / '.local/bin/jq').exists())
        self.assertIn('command=' + str(command), result.stdout)
        self.assertEqual(self.install('--installer-prefix', str(prefix), '--installer-command', str(command), '--remove').returncode, 0)
        self.assertFalse(command.exists())

    def test_explicit_foreign_command_is_preserved(self):
        self.fixture()
        command = self.work / 'foreign-jq'
        command.write_text('foreign bytes')
        result = self.install('--installer-prefix', str(self.work / 'data-jq'), '--installer-command', str(command))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(command.read_text(), 'foreign bytes')

    def test_explicit_prepared_artifact_is_verified_by_native_core_before_activation(self):
        self.fixture()
        cache = self.work / 'prepared-jq'
        cache.write_bytes(Handler.body)
        self.env['JQ_ARTIFACT_CACHE'] = str(cache)
        # A fresh native request would receive corrupted bytes. Only reuse of
        # the exact locked prepared artifact can produce a working installation.
        Handler.body = b'X' * len(Handler.body)
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        binary = self.home / '.local/bin/jq'
        self.assertEqual(subprocess.check_output([str(binary), '--version'], text=True).strip(), 'jq-1.8.2')
        self.assertEqual(cache.read_bytes()[:9], b'#!/bin/sh')

    def test_changed_or_symlink_prepared_artifact_never_activates(self):
        self.fixture()
        cache = self.work / 'prepared-jq'
        cache.write_bytes(b'X' * len(Handler.body))
        self.env['JQ_ARTIFACT_CACHE'] = str(cache)
        Handler.body = cache.read_bytes()
        self.assertEqual(self.install().returncode, 11)
        self.assertFalse((self.home / '.local/bin/jq').exists())
        cache.unlink()
        cache.symlink_to(self.work / 'lock.json')
        self.assertEqual(self.install().returncode, 2)
        self.assertFalse((self.home / '.local/bin/jq').exists())

    def test_foreign_command_and_corrupted_download_are_preserved(self):
        self.fixture()
        command=self.home/'.local/bin/jq';command.parent.mkdir(parents=True);command.write_text('foreign')
        self.assertNotEqual(self.install().returncode,0)
        self.assertEqual(command.read_text(),'foreign')
        command.unlink();Handler.body=b'X'*len(Handler.body)
        self.assertEqual(self.install().returncode,11)
        self.assertFalse(command.exists())

    def test_correct_version_without_regex_is_not_activated(self):
        self.fixture(complete=False)
        p=self.install();self.assertEqual(p.returncode,11,p.stderr)
        self.assertIn('ONIGURUMA',p.stderr)
        self.assertFalse((self.home/'.local/bin/jq').exists())

    def test_external_prefix_link_is_preserved(self):
        self.fixture();outside=self.work/'outside';outside.mkdir();(outside/'keep').write_text('keep')
        link=self.work/'link';link.symlink_to(outside,target_is_directory=True)
        self.assertEqual(self.install('--installer-prefix',str(link)).returncode,2)
        self.assertEqual(sorted(x.name for x in outside.iterdir()),['keep'])

    def test_remove_checks_all_owned_programs_and_preserves_configuration(self):
        self.fixture();self.assertEqual(self.install().returncode,0)
        prefix=self.home/'.local/lib/linkease/jq';keep=prefix/'config.json';keep.write_text('keep')
        command=self.home/'.local/bin/jq'
        original=command.read_bytes();command.write_bytes(b'X'*len(original))
        self.assertEqual(self.install('--remove').returncode,11)
        self.assertTrue((prefix/'versions/1.8.2/bin/jq').exists())
        command.write_bytes(original)
        p=self.install('--remove');self.assertEqual(p.returncode,0,p.stderr)
        self.assertFalse(command.exists());self.assertFalse((prefix/'versions').exists())
        self.assertEqual(keep.read_text(),'keep')
        self.assertEqual(self.install('--remove').returncode,0)
        reinstall=self.install()
        self.assertEqual(reinstall.returncode,0,reinstall.stderr)
        self.assertEqual(keep.read_text(),'keep')
        self.assertTrue(command.exists())

    def test_windows_executable_layout_is_exercised_offline(self):
        self.fixture('windows')
        p=self.install();self.assertEqual(p.returncode,0,p.stderr)
        self.assertTrue((self.home/'.local/bin/jq.exe').is_file())
        self.assertEqual(self.install().returncode,0)
        self.assertEqual(self.install('--remove').returncode,0)

    def test_macos_installer_branch_is_exercised_offline(self):
        self.fixture('macos')
        p=self.install();self.assertEqual(p.returncode,0,p.stderr)
        self.assertEqual(subprocess.check_output([str(self.home/'.local/bin/jq'),'--version'],text=True).strip(),'jq-1.8.2')
        self.assertEqual(self.install('--remove').returncode,0)


if __name__ == '__main__':
    unittest.main()
