"""Zig service protocol prerequisites; no host service or live account is used."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / 'sources/ddnsto/linux-zig-config.sh'


class ZigProtocol(unittest.TestCase):
    def render(self, value, state='/etc/ddnsto', raw=False):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / 'config.json'
            config.write_text(value if raw else json.dumps(value))
            return subprocess.run(['sh', '-c', '. "$1"; ddnsto_zig_config_render "$2" "$3"',
                                   'test', str(MODULE), str(config), state],
                                  capture_output=True, text=True)

    def test_identity_fields_are_preserved(self):
        r = self.render(dict(token='fixture-token', routeridx='7', supplierCode='supplier'))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('userToken: "fixture-token"', r.stdout)
        self.assertIn('routerIdx: 7', r.stdout)
        self.assertIn('supplierCode: "supplier"', r.stdout)
        self.assertIn('enabled: false', r.stdout)
        self.assertIn('bootConfigPath: "/etc/ddnsto/.ddnsto_boot.cfg"', r.stdout)

    def test_defaults_and_quoting(self):
        r = self.render(dict(token='quote"\\token'), state="/path with 'quote/$literal")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('routerIdx: 0', r.stdout)
        self.assertIn('userToken: "quote\\"\\\\token"', r.stdout)

    def test_unsupported_configuration_is_not_silently_lost(self):
        for value in ({'token': ''}, {'token': 123}, {'token': 'x', 'routeridx': -1},
                      {'token': 'x', 'routeridx': 1.5}, {'token': 'x', 'routeridx': 'bad'},
                      {'token': 'x', 'routeridx': 2147483648}, {'token': 'x', 'routeridx': False},
                      {'token': 'x', 'supplierCode': []}, {'token': 'x', 'remoteAddr': 'custom'},
                      {'token': 'x', 'webdav': {}}, [{'token': 'x'}]):
            with self.subTest(value=value):
                r = self.render(value)
                self.assertNotEqual(r.returncode, 0)
                self.assertEqual(r.stdout, '')

    def test_multiple_documents_and_unsafe_paths_rejected(self):
        self.assertNotEqual(self.render('{"token":"a"}\n{"token":"b"}', raw=True).returncode, 0)
        for path in ('relative', '/', '/tmp/new\nline', '/tmp/../etc'):
            self.assertNotEqual(self.render({'token': 'x'}, state=path).returncode, 0)

    def test_wrapper_passes_literal_config_path_without_token_arguments(self):
        with tempfile.TemporaryDirectory(prefix="zig 'quote-$-") as directory:
            binary = Path(directory) / 'client'
            binary.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
            binary.chmod(0o700)
            config = Path(directory) / 'config.yaml'
            r = subprocess.run(['sh', '-c', '. "$4"; . "$1"; ddnsto_zig_service_wrapper "$2" "$3"',
                                'test', str(MODULE), str(binary), str(config), str(ROOT / 'lib/install-service.sh')], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            run = subprocess.run(['sh', '-c', r.stdout], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertEqual(run.stdout.splitlines(), ['--config', str(config), 'run'])

    @unittest.skipUnless(os.environ.get('DDNSTO_TEST_ZIG'), 'requires reviewed Zig and offline namespace')
    def test_real_zig_accepts_service_configuration(self):
        interfaces = [line.split(':', 1)[0].strip() for line in Path('/proc/net/dev').read_text().splitlines()[2:]]
        self.assertEqual(interfaces, ['lo'], 'requires isolated offline networking')
        self.assertLessEqual(len(Path('/proc/net/route').read_text().splitlines()), 1)
        binary = Path(os.environ['DDNSTO_TEST_ZIG'])
        pins = json.loads((ROOT / 'sources/ddnsto/platform-releases.json').read_text())['platforms']['linux']
        self.assertEqual(hashlib.sha256(binary.read_bytes()).hexdigest(), pins['zig_x86_64_sha256'])
        with tempfile.TemporaryDirectory(prefix='zig-service-protocol-') as directory:
            r = self.render({'token': 'offline-fixture-token', 'routeridx': 7}, state=directory)
            self.assertEqual(r.returncode, 0, r.stderr)
            config = Path(directory) / 'config.yaml'
            config.write_text(r.stdout)
            config.chmod(0o600)
            (Path(directory) / 'logs').mkdir()
            with (Path(directory) / 'startup.log').open('w+') as log:
                process = subprocess.Popen([str(binary), '--config', str(config), 'run'],
                                           cwd=directory, stdout=log, stderr=log)
                try:
                    time.sleep(2)
                    log.seek(0)
                    self.assertIsNone(process.poll(), log.read())
                finally:
                    if process.poll() is None:
                        process.terminate()
                        try:
                            process.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait(timeout=5)


if __name__ == '__main__':
    unittest.main()
