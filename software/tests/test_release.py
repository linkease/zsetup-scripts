import hashlib
import http.server
import json
import os
from pathlib import Path
import platform
import shutil
import ssl
import subprocess
import sys
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tests'))
from tls_fixture import generate_certificate


@unittest.skipUnless(os.environ.get('ZSETUP_TEST_NATIVE'), 'requires explicit verified native zsetup')
class ReleaseOwner(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.owner = self.root / 'owner'
        self.owner.mkdir()
        for folder in ['software', 'jq']:
            shutil.copytree(ROOT / folder, self.owner / folder, ignore=shutil.ignore_patterns('tests', '__pycache__'))
        self.base = self.root / 'apps'
        self.base.mkdir()
        generate_certificate(self.root)
        cert = self.root / 'server.crt'
        key = self.root / 'server.key'
        self.payload = b'#!/bin/sh\ntest "$1" = --self-test || exit 9\nprintf "release-ready\\n"\n#' + b'x' * 512 + b'\n'
        self.body = self.payload
        self.hits = 0
        outer = self
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass
            def do_GET(self):
                outer.hits += 1
                self.send_response(200)
                self.send_header('Content-Length', str(len(outer.body)))
                self.end_headers()
                self.wfile.write(outer.body)
        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        self.server.socket = context.wrap_socket(self.server.socket, server_side=True)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop_server)
        target = 'linux-' + {'x86_64': 'amd64', 'aarch64': 'arm64'}[platform.machine()]
        self.url = f'https://127.0.0.1:{self.server.server_port}/artifact'
        recipe = {'schemaVersion': 1, 'software': {'sim-release-app': {
            'version': '1.0.0', 'sourceCommit': 'a' * 40, 'features': [],
            'verifyArgs': ['--self-test'], 'expectedOutput': 'release-ready',
            'artifacts': {target: {'url': self.url, 'sha256': hashlib.sha256(self.payload).hexdigest(), 'size': len(self.payload)}}}}}
        (self.owner / 'software/releases.lock.json').write_text(json.dumps(recipe))
        self.request = {'software': 'sim-release-app', 'targetId': 'release-test',
                        'method': 'release', 'version': '1.0.0', 'prefixBase': str(self.base)}
        self.env = {**os.environ, 'ZSETUP_TASK_TARGET_ID': 'release-test',
                    'ZSETUP_BIN': os.environ['ZSETUP_TEST_NATIVE'], 'ZSETUP_CA_FILE': str(self.root / 'ca.crt')}

    def stop_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)

    def call(self, operation):
        file = self.root / 'request.json'
        file.write_text(json.dumps(self.request))
        result = subprocess.run(['bash', str(self.owner / 'software/task.sh'), operation, str(file)],
                                env=self.env, text=True, capture_output=True, timeout=20)
        return result, json.loads(result.stdout)

    def test_plan_is_read_only_and_apply_reuses_native_verified_download(self):
        result, planned = self.call('plan')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(planned['details']['method'], 'release')
        self.assertEqual(planned['details']['url'], self.url)
        self.assertEqual(self.hits, 0)
        self.assertEqual(list(self.base.iterdir()), [])
        self.request['plan'] = planned['details']
        result, installed = self.call('apply')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(installed['details']['functionalValidation'], 'passed')
        self.assertGreater(self.hits, 0)
        command = Path(installed['details']['command'])
        self.assertEqual(command.read_bytes(), self.payload)
        receipt = json.loads((self.base / 'sim-release-app/current.json').read_text())
        self.assertEqual(receipt['provenance']['sourceCommit'], 'a' * 40)

    def test_corrupted_release_never_executes_or_creates_program_prefix(self):
        marker = self.root / 'unwanted'
        malicious = ('#!/bin/sh\ntouch "' + str(marker) + '"\n#').encode()
        self.body = malicious + b'x' * (len(self.payload) - len(malicious))
        result, planned = self.call('plan')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.request['plan'] = planned['details']
        result, failed = self.call('apply')
        self.assertEqual(result.returncode, 22, result.stdout + result.stderr)
        self.assertEqual(failed['reason'], 'release-download-failed')
        self.assertNotEqual(failed['nativeExitCode'], 0)
        self.assertFalse(marker.exists())
        self.assertFalse((self.base / 'sim-release-app').exists())

    def test_unknown_release_version_does_not_guess_a_download(self):
        self.request['version'] = '9.0.0'
        result, body = self.call('plan')
        self.assertEqual(result.returncode, 20, result.stdout + result.stderr)
        self.assertEqual(body['reason'], 'no-compatible-release-version')
        self.assertEqual(self.hits, 0)


if __name__ == '__main__':
    unittest.main()
