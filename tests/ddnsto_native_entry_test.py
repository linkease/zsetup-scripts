"""Actual generated public entry -> HTTPS config/index -> native -> --help.

No package manager/service mutations. Set DDNSTO_TEST_NATIVE to the published
Linux binary. Unlike a fake-native contract, this catches coordinator ABI drift.
"""
import hashlib
import http.server
import json
import os
from pathlib import Path
import shutil
import ssl
import subprocess
import sys
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import build
from tls_fixture import generate_certificate


@unittest.skipUnless(os.environ.get('DDNSTO_TEST_NATIVE'), 'published native required')
class NativeEntry(unittest.TestCase):
    def test_public_chain_with_actual_coordinator(self):
        native = Path(os.environ['DDNSTO_TEST_NATIVE']).resolve()
        version = subprocess.check_output([str(native), '--version'], text=True).strip().split()[1]
        with tempfile.TemporaryDirectory() as name:
            work = Path(name)
            generate_certificate(work)
            requests = []
            bodies = {}

            class Handler(http.server.BaseHTTPRequestHandler):
                def do_GET(self):
                    path = self.path.removeprefix('/fallback')
                    requests.append(path)
                    if path not in bodies:
                        self.send_error(404)
                        return
                    data = bodies[path]
                    self.send_response(200)
                    self.send_header('Content-Length', str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)

                def log_message(self, *_):
                    pass

            server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
            tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            tls.load_cert_chain(work / 'server.crt', work / 'server.key')
            server.socket = tls.wrap_socket(server.socket, server_side=True)
            thread = threading.Thread(target=server.serve_forever)
            thread.start()
            try:
                base_url = f'https://127.0.0.1:{server.server_port}'
                apps = work / 'apps'
                shutil.copytree(ROOT / 'apps/ddnsto', apps / 'ddnsto')
                (apps / 'zsetup').mkdir()
                base = json.loads((ROOT / 'apps/zsetup/base.json').read_text())
                group = base['source_groups'][0]
                group['primary_bases'] = [base_url + '/binary']
                group['fallback_base'] = base_url + '/fallback/binary'
                (apps / 'zsetup/base.json').write_text(json.dumps(base))
                application = build.read_application(apps / 'ddnsto')
                build.generate_config(apps, [application], check=False)
                entry = build.posix_entry(ROOT, application)
                entry_path = work / 'entry.sh'
                entry_path.write_text(entry)
                for path in apps.rglob('*'):
                    if path.is_file():
                        bodies['/binary/zsetup-scripts/apps/' + path.relative_to(apps).as_posix()] = path.read_bytes()
                bodies['/binary/zsetup/stable'] = (version + '\n').encode()
                digest = hashlib.sha256(native.read_bytes()).hexdigest()
                bodies[f'/binary/zsetup/{version}/SHA256SUMS'] = (digest + '  zsetup-linux-x86_64\n').encode()
                env = {k: v for k, v in os.environ.items() if not k.startswith(('ZSETUP_', 'DDNSTO_'))}
                env.update(ZSETUP_BIN=str(native), ZSETUP_ROOT=str(work / 'bootstrap'),
                    ZSETUP_CACHE_DIR=str(work / 'cache'), ZSETUP_MANAGED_ROOT=str(work / 'managed'),
                    ZSETUP_CONFIG_CACHE=str(work / 'lkg.json'), ZSETUP_BOOTSTRAP_BASES=base_url + '/binary',
                    ZSETUP_CA_FILE=str(work / 'ca.crt'), CURL_CA_BUNDLE=str(work / 'ca.crt'))
                result = subprocess.run(['sh', str(entry_path), '--help'], env=env,
                    capture_output=True, text=True, timeout=40)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('Usage: ddnsto-install.sh', result.stdout)
                self.assertIn('/binary/zsetup-scripts/apps/zsetup/ddnsto-index.json', requests)
                payload_path = application.payload_path('sh').relative_to(apps).as_posix()
                self.assertIn('/binary/zsetup-scripts/apps/' + payload_path, requests)

                # Appliance dispatch must verify the same immutable bytes, not
                # turn a failed native index lookup into unverified execution.
                payload = application.payload_path('sh').read_bytes()
                adapter = (ROOT / 'sources/ddnsto/entry-appliance.sh.in').read_text()
                for marker, value in {'SHA256': hashlib.sha256(payload).hexdigest(),
                        'SIZE': str(len(payload)), 'VERSION': application.manifest['version']}.items():
                    adapter = adapter.replace(f'@@{marker}@@', value)
                appliance_work = work / 'appliance'
                appliance_work.mkdir(mode=0o700)
                appliance_env = dict(env, WORK_ROOT=str(appliance_work),
                    DDNSTO_ENTRY_APPLIANCE='synology', DDNSTO_ENTRY_LEGACY='0',
                    ACTIVE_ZSETUP=str(native),
                    CONFIG_PRIMARY_URLS=base_url + '/binary/zsetup-scripts/apps/zsetup/config.json',
                    CONFIG_FALLBACK_URL=base_url + '/fallback/binary/zsetup-scripts/apps/zsetup/config.json')
                for corrupt in (False, True):
                    bodies['/binary/zsetup-scripts/apps/' + payload_path] = (
                        b'!' + payload[1:] if corrupt else payload)
                    probe = subprocess.run(['sh', '-c', adapter + '\nddnsto_entry_appliance --help'],
                        env=appliance_env, capture_output=True, text=True, timeout=40)
                    if corrupt:
                        self.assertNotEqual(probe.returncode, 0)
                        self.assertNotIn('Usage: ddnsto-install.sh', probe.stdout)
                    else:
                        self.assertEqual(probe.returncode, 0, probe.stderr)
                        self.assertIn('Usage: ddnsto-install.sh', probe.stdout)
                    self.assertEqual(list(appliance_work.iterdir()), [])
            finally:
                server.shutdown()
                server.server_close()
                thread.join()


if __name__ == '__main__':
    unittest.main()
