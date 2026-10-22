"""Isolated policy tests; optionally supply released bytes via DDNSTO_TEST_NATIVE.

No core source, service changes, or public network access is used by this suite.
"""
import hashlib
import http.server
import os
import runpy
from pathlib import Path
import shlex
import shutil
import ssl
import subprocess
import tempfile
import threading
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
POLICY = ROOT / 'ddnsto/bootstrap-policy.sh'
PINS = {
    'x86_64': '9563b8442a75957792bb82a2d98a736142fc52be57dd2dc42005490096897617',
    'aarch64': '70cc54fcfdc6c6516965485879f0929e7dc9aabc1bd0fe09cbab099dd4619020',
    'armv7': '16eca14c00167ef45dac13e536c5ef2880f682ec48c70661044ee453724a66aa',
    'mipsel': '4821bbeae11fdcdfa9eb5e0b46b63e9751e069c21b1e0e598c5658eb73383a7b',
}


class BootstrapEmbeddingTest(unittest.TestCase):
    def test_generator_embeds_policy_only_for_ddnsto_without_writing_entries(self):
        generated = {}
        read_text = Path.read_text
        run = subprocess.run

        class CheckedContent(str):
            def __new__(cls, path):
                value = super().__new__(cls, '')
                value.path = path
                return value

            def __ne__(self, expected):
                # Capture --check's expected content in memory. Never generate
                # or rewrite an entry, including in a temporary checkout.
                generated[self.path] = expected
                return False

        def read(path, *args, **kwargs):
            if path in (ROOT / 'ddnsto/install.sh', ROOT / 'fastnet/install.sh'):
                return CheckedContent(path)
            return read_text(path, *args, **kwargs)

        def check_syntax(args, **kwargs):
            self.assertEqual(args[:2], ['sh', '-n'])
            return run(['sh', '-n'], input=generated[Path(args[2])], text=True, check=True)

        generator = runpy.run_path(str(ROOT / 'scripts/build-entrypoints.py'))
        with mock.patch('sys.argv', ['build-entrypoints.py', '--check']), \
                mock.patch.object(Path, 'read_text', read), \
                mock.patch.object(subprocess, 'run', check_syntax), \
                mock.patch.object(tempfile, 'NamedTemporaryFile', side_effect=AssertionError('entry write forbidden')):
            generator['main']()
        ddnsto = generated[ROOT / 'ddnsto/install.sh']
        common = read_text(ROOT / 'lib/bootstrap.sh').rstrip()
        policy = read_text(POLICY).rstrip()
        business = read_text(ROOT / 'ddnsto/business.sh').rstrip()
        self.assertIn(policy, ddnsto)
        self.assertLess(ddnsto.index(common), ddnsto.index(policy))
        self.assertLess(ddnsto.index(policy), ddnsto.index(business))
        wrapper = ddnsto.split('\nbootstrap_and_run() {', 1)[1].split('\n}', 1)[0]
        self.assertIn('    ddnsto_bootstrap_zsetup || return $?\n', wrapper)
        self.assertNotIn('\n    bootstrap_zsetup\n', wrapper)
        for name in ('docker-probe.sh', 'product-pins.sh', 'linux-service.sh',
                     'linux-lifecycle.sh', 'service-management.sh'):
            self.assertIn(read_text(ROOT / 'ddnsto' / name).rstrip(), ddnsto)
        self.assertEqual(generated[ROOT / 'fastnet/install.sh'], read_text(ROOT / 'fastnet/install.sh'))


class BootstrapPolicyTest(unittest.TestCase):
    def setUp(self):
        self.assertTrue(POLICY.is_file(), 'DDNSTO fixed bootstrap policy is missing')
        self.tmp = tempfile.TemporaryDirectory(prefix='ddnsto-policy-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.cache = self.root / 'cache'
        self.env = dict(os.environ, ZSETUP_ROOT=str(self.cache),
                        ZSETUP_BIN='', ZSETUP_BOOTSTRAP_BASES='https://fixture.invalid/binary',
                        TEST_LOG=str(self.root / 'fetch.log'), MARKER=str(self.root / 'executed'))

    def run_shell(self, body, setup='', real_network=False):
        self.assertTrue(POLICY.is_file(), 'DDNSTO fixed bootstrap policy is missing')
        script = '. ' + shlex.quote(str(ROOT / 'lib/bootstrap.sh')) + '\n'
        script += '. ' + shlex.quote(str(POLICY)) + '\n'
        # Replace only network I/O; architecture, hashing, lookup and shared
        # bootstrap control flow remain real. Never invoke curl on the host.
        if not real_network:
            script += '''bootstrap_fetch_from_base() {
            printf '%s %s\\n' "$1" "$3" >> "$TEST_LOG"
            [ -n "${FIXTURE_NATIVE:-}" ] || return 1
            cp "$FIXTURE_NATIVE" "$4"
        }
'''
        return subprocess.run(['/bin/sh', '-c', script + setup + '\n' + body],
                              env=self.env, text=True, capture_output=True, timeout=20)

    def poison(self, path):
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        path.write_text('#!/bin/sh\ntouch "$MARKER"\necho "zsetup 0.5.0"\n')
        path.chmod(0o700)
        return path

    def test_metadata_is_local_fixed_and_rejects_unknown_arch(self):
        for arch, digest in PINS.items():
            with self.subTest(arch=arch):
                result = self.run_shell(f'ZSETUP_ARCH={arch}; fetch_bootstrap_metadata https ignored ignored; '
                                        'printf "%s %s" "$RESCUE_VERSION" "$EXPECTED_SHA256"')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, '0.5.0 ' + digest)
                self.assertFalse((self.root / 'fetch.log').exists())
        result = self.run_shell('ZSETUP_ARCH=unknown; fetch_bootstrap_metadata https ignored ignored')
        self.assertNotEqual(result.returncode, 0)

    def test_untrusted_existing_binaries_are_never_executed(self):
        for source in ('explicit', 'cached', 'system'):
            with self.subTest(source=source):
                target = self.root / source / 'zsetup'
                if source == 'cached':
                    target = self.cache / 'rescue/0.5.0/zsetup'
                self.poison(target)
                self.env['ZSETUP_BIN'] = str(target) if source == 'explicit' else ''
                self.env['PATH'] = str(target.parent) + ':' + os.environ['PATH']
                result = self.run_shell('ddnsto_bootstrap_zsetup')
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / 'executed').exists())
        self.assertNotIn('stable', (self.root / 'fetch.log').read_text())
        self.assertNotIn('SHA256SUMS', (self.root / 'fetch.log').read_text())
        self.assertNotIn('http ', (self.root / 'fetch.log').read_text())

    def test_hash_tool_is_mandatory_before_network_or_execution(self):
        self.env['ZSETUP_BIN'] = str(self.poison(self.root / 'native'))
        result = self.run_shell('ddnsto_bootstrap_zsetup', 'have_hash_tool() { return 1; }')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'executed').exists())
        self.assertFalse((self.root / 'fetch.log').exists())

    def test_http_is_refused_even_with_yes_file_and_prior_confirmation(self):
        yes = self.root / 'yes'
        yes.write_text('yes\n')
        self.env['ZSETUP_CONFIRM_FILE'] = str(yes)
        result = self.run_shell('INSECURE_CONFIRMED=1; ddnsto_bootstrap_zsetup')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('http ', (self.root / 'fetch.log').read_text())

    def test_unsafe_cache_directories_are_rejected_before_network(self):
        for kind in ('symlink', 'public', 'child-symlink', 'ancestor-symlink', 'foreign'):
            with self.subTest(kind=kind):
                base = self.root / kind
                base.mkdir(mode=0o700)
                cache = base / 'cache'
                if kind == 'symlink':
                    cache.symlink_to(self.root, target_is_directory=True)
                elif kind == 'ancestor-symlink':
                    (base / 'alias').symlink_to(self.root, target_is_directory=True)
                    cache = base / 'alias/cache'
                else:
                    cache.mkdir(mode=0o700)
                    if kind == 'public':
                        cache.chmod(0o755)
                    elif kind == 'child-symlink':
                        (cache / 'rescue').symlink_to(self.root, target_is_directory=True)
                    elif os.geteuid() == 0:
                        os.chown(cache, 12345, 12345)
                    else:
                        continue
                self.env['ZSETUP_ROOT'] = str(cache)
                result = self.run_shell('ddnsto_bootstrap_zsetup')
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / 'fetch.log').exists())

    def test_symlink_binary_is_rejected_even_before_version_check(self):
        target = self.poison(self.root / 'bad')
        link = self.root / 'link'
        link.symlink_to(target)
        result = self.run_shell('ZSETUP_ARCH=x86_64; fetch_bootstrap_metadata https x x; '
                                'is_expected_zsetup ' + shlex.quote(str(link)))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'executed').exists())

    def test_downloaded_wrong_bytes_never_execute_and_lock_is_released(self):
        self.env['FIXTURE_NATIVE'] = str(self.poison(self.root / 'bad'))
        result = self.run_shell('ddnsto_bootstrap_zsetup')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'executed').exists())
        self.assertFalse((self.cache / '.ddnsto-bootstrap-lock').exists())

    @unittest.skipUnless(os.environ.get('DDNSTO_TEST_NATIVE'), 'supply released 0.5.0 native bytes')
    def test_directory_at_cached_binary_path_fails_closed(self):
        self.env['FIXTURE_NATIVE'] = os.environ['DDNSTO_TEST_NATIVE']
        (self.cache / 'rescue/0.5.0/zsetup').mkdir(parents=True, mode=0o700)
        # pathlib's intermediate directories use default permissions.
        for directory in (self.cache, self.cache / 'rescue', self.cache / 'rescue/0.5.0'):
            directory.chmod(0o700)
        result = self.run_shell('ddnsto_bootstrap_zsetup')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'fetch.log').exists())

    def test_existing_lock_is_not_stolen(self):
        self.cache.mkdir(mode=0o700)
        lock = self.cache / '.ddnsto-bootstrap-lock'
        lock.mkdir(mode=0o700)
        result = self.run_shell('if ddnsto_bootstrap_zsetup; then exit 0; else exit $?; fi')
        self.assertEqual(result.returncode, 16, result.stderr)
        self.assertTrue(lock.is_dir())
        self.assertFalse((self.root / 'fetch.log').exists())

    @unittest.skipUnless(os.environ.get('DDNSTO_TEST_NATIVE'), 'supply released 0.5.0 native bytes')
    def test_failed_cache_publication_cannot_report_success(self):
        self.env['FIXTURE_NATIVE'] = os.environ['DDNSTO_TEST_NATIVE']
        result = self.run_shell('if ddnsto_bootstrap_zsetup; then exit 0; else exit $?; fi',
                                'mv() { return 1; }')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.cache / '.ddnsto-bootstrap-lock').exists())

    def test_failure_stays_closed_when_caller_tests_return_status(self):
        self.env['FIXTURE_NATIVE'] = str(self.poison(self.root / 'bad'))
        result = self.run_shell('if ddnsto_bootstrap_zsetup; then exit 0; else exit $?; fi')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'executed').exists())

    @unittest.skipUnless(os.environ.get('DDNSTO_TEST_NATIVE'), 'supply released 0.5.0 native bytes')
    def test_released_native_download_cache_and_explicit_reuse(self):
        native = Path(os.environ['DDNSTO_TEST_NATIVE']).resolve()
        self.assertEqual(hashlib.sha256(native.read_bytes()).hexdigest(), PINS['x86_64'])
        self.env['FIXTURE_NATIVE'] = str(native)
        result = self.run_shell('ddnsto_bootstrap_zsetup; "$ACTIVE_ZSETUP" --version')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'zsetup 0.5.0')
        log = self.root / 'fetch.log'
        self.assertEqual(log.read_text(), 'https zsetup/0.5.0/zsetup-linux-x86_64\n')
        for directory in (self.cache, self.cache / 'bootstrap', self.cache / 'rescue', self.cache / 'rescue/0.5.0'):
            self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
        del self.env['FIXTURE_NATIVE']
        log.unlink()
        result = self.run_shell('ddnsto_bootstrap_zsetup; "$ACTIVE_ZSETUP" --version')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(log.exists())
        explicit = self.root / 'explicit-native'
        shutil.copyfile(native, explicit)
        explicit.chmod(0o700)
        self.env['ZSETUP_BIN'] = str(explicit)
        result = self.run_shell('ddnsto_bootstrap_zsetup; printf "%s" "$ACTIVE_ZSETUP"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, str(explicit))
        self.assertFalse(log.exists())

    def redirect_fixture(self):
        payload = Path(os.environ['DDNSTO_TEST_NATIVE']).read_bytes()
        self.assertEqual(hashlib.sha256(payload).hexdigest(), PINS['x86_64'])
        http_requests = []

        class PlainHandler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                http_requests.append(self.path)
                self.send_response(200)
                self.send_header('Content-Length', str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, *args):
                pass

        plain = http.server.ThreadingHTTPServer(('127.0.0.1', 0), PlainHandler)

        class RedirectHandler(PlainHandler):
            def do_GET(self):
                self.send_response(302)
                self.send_header('Location', f'http://127.0.0.1:{plain.server_port}/released-native')
                self.send_header('Content-Length', '0')
                self.end_headers()

        cert, key = self.root / 'redirect-cert.pem', self.root / 'redirect-key.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                        '-days', '1', '-subj', '/CN=127.0.0.1', '-addext', 'subjectAltName=IP:127.0.0.1',
                        '-keyout', str(key), '-out', str(cert)], check=True, capture_output=True)
        secure = http.server.ThreadingHTTPServer(('127.0.0.1', 0), RedirectHandler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        secure.socket = context.wrap_socket(secure.socket, server_side=True)
        for server in (plain, secure):
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()

            def stop(server=server, thread=thread):
                server.shutdown()
                server.server_close()
                thread.join(timeout=5)

            self.addCleanup(stop)
        self.env['ZSETUP_BOOTSTRAP_BASES'] = f'https://127.0.0.1:{secure.server_port}/binary'
        self.env['CURL_CA_BUNDLE'] = str(cert)
        self.env['TEST_CA_FILE'] = str(cert)
        return http_requests

    @unittest.skipUnless(os.environ.get('DDNSTO_TEST_NATIVE'), 'supply released 0.5.0 native bytes')
    def test_https_to_http_redirect_is_rejected_even_with_correct_pin(self):
        http_requests = self.redirect_fixture()
        result = self.run_shell('ddnsto_bootstrap_zsetup',
            'wget() { command wget --ca-certificate "$TEST_CA_FILE" "$@"; }', real_network=True)
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertEqual(http_requests, [], 'must reject downgrade before contacting HTTP')
        self.assertFalse((self.cache / 'rescue/0.5.0/zsetup').exists())

    @unittest.skipUnless(os.environ.get('DDNSTO_TEST_NATIVE'), 'supply released 0.5.0 native bytes')
    def test_wget_fallback_cannot_follow_https_to_http_redirect(self):
        http_requests = self.redirect_fixture()
        result = self.run_shell('ddnsto_bootstrap_zsetup',
            'curl() { return 127; }; wget() { command wget --ca-certificate "$TEST_CA_FILE" "$@"; }',
            real_network=True)
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertEqual(http_requests, [])
        self.assertFalse((self.cache / 'rescue/0.5.0/zsetup').exists())

    def test_unknown_wget_fails_closed_without_network(self):
        result = self.run_shell('bootstrap_fetch_from_base https https://fixture.invalid binary "$ZSETUP_ROOT"',
            '''curl() { return 127; }
            wget() {
                if [ "$1" = --version ]; then printf 'unknown wget\\n'; return 0; fi
                printf 'unsafe-wget-called' > "$TEST_LOG"
                return 0
            }''', real_network=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'fetch.log').exists())

    @unittest.skipUnless(os.environ.get('DDNSTO_TEST_NATIVE'), 'supply released 0.5.0 native bytes')
    def test_real_https_download_ignores_hostile_remote_metadata(self):
        payload = Path(os.environ['DDNSTO_TEST_NATIVE']).read_bytes()
        self.assertEqual(hashlib.sha256(payload).hexdigest(), PINS['x86_64'])
        requests = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                requests.append(self.path)
                body = {
                    '/binary/zsetup/0.5.0/zsetup-linux-x86_64': payload,
                    '/binary/zsetup/stable': b'99.0.0\n',
                    '/binary/zsetup/0.5.0/SHA256SUMS': b'0' * 64 + b'  zsetup-linux-x86_64\n',
                }.get(self.path)
                if body is None:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        cert, key = self.root / 'cert.pem', self.root / 'key.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                        '-days', '1', '-subj', '/CN=127.0.0.1',
                        '-addext', 'subjectAltName=IP:127.0.0.1',
                        '-keyout', str(key), '-out', str(cert)], check=True, capture_output=True)
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            self.env['ZSETUP_BOOTSTRAP_BASES'] = f'https://127.0.0.1:{server.server_port}/binary'
            self.env['CURL_CA_BUNDLE'] = str(cert)
            result = self.run_shell('ddnsto_bootstrap_zsetup; "$ACTIVE_ZSETUP" --version', real_network=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), 'zsetup 0.5.0')
            self.assertEqual(requests, ['/binary/zsetup/0.5.0/zsetup-linux-x86_64'])
            # GNU Wget remains a usable fallback for direct HTTPS responses;
            # the restriction is not implemented by disabling every download.
            self.env['ZSETUP_ROOT'] = str(self.root / 'wget-cache')
            result = self.run_shell('ddnsto_bootstrap_zsetup; "$ACTIVE_ZSETUP" --version',
                'curl() { return 127; }; wget() { command wget --ca-certificate "$CURL_CA_BUNDLE" "$@"; }',
                real_network=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), 'zsetup 0.5.0')
            self.assertEqual(requests, ['/binary/zsetup/0.5.0/zsetup-linux-x86_64'] * 2)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)


if __name__ == '__main__':
    unittest.main()
