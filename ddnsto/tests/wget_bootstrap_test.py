"""Real local HTTPS with curl absent; never touches services or public sites."""
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import ssl
import tempfile
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tests'))
import ddnsto_recommendation_test as fixture
from tls_fixture import generate_certificate
import macos_behavior_test as mac_fixture


class WgetRecommendation(fixture.Recommendation):
    @classmethod
    def setUpClass(cls):
        cls.tls = tempfile.TemporaryDirectory(prefix='wget-tls-')
        directory = Path(cls.tls.name)
        generate_certificate(directory)
        cls.cert = directory / 'ca.crt'
        cls.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        cls.context.load_cert_chain(directory / 'server.crt', directory / 'server.key')

    def setUp(self):
        super().setUp()
        self.base = 'https://127.0.0.1:%s' % self.server.server_port
        self.bin = self.work / 'wget-bin'
        self.bin.mkdir()
        for tool in ('sh', 'uname', 'stat', 'wc', 'cmp', 'mktemp', 'sha256sum',
                     'id', 'mkdir', 'rmdir', 'rm', 'cp', 'mv', 'chmod', 'sleep', 'cat'):
            (self.bin / tool).symlink_to(shutil.which(tool))
        self.real_wget = shutil.which('wget')
        self.wget = self.bin / 'wget'
        self.wget.write_text('#!/bin/sh\nexec ' + shlex.quote(self.real_wget) +
                             ' --ca-certificate "${CURL_CA_BUNDLE:-/dev/null}" "$@"\n')
        self.wget.chmod(0o700)
        self.env['PATH'] = str(self.bin)
        self.env['HOME'] = str(self.work)
        self.assertIsNone(shutil.which('curl', path=self.env['PATH']))

    def test_hostile_wgetrc_cannot_inject_urls_or_disable_tls(self):
        self.prepare()
        config = self.work / '.wgetrc'
        config.write_text('check_certificate = off\ninput = /does/not/exist\nmax_redirect = 20\n')
        self.env['WGETRC'] = str(config)
        result = self.run_entry()
        self.assertEqual(result.returncode, 0, result.stderr)
        # Remove the fixture trust override: hostile config must not trust TLS.
        self.wget.write_text('#!/bin/sh\nexec ' + shlex.quote(self.real_wget) + ' "$@"\n')
        (self.work / 'args').unlink()
        result = self.run_entry()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.work / 'args').exists())
        self.assertNotIn('离线', result.stderr)

    def test_unsafe_wget_is_explicit_even_with_complete_cache(self):
        self.prepare()
        self.assertEqual(self.run_entry().returncode, 0)
        for version in ('BusyBox v1.36 wget', 'uclient-fetch', 'GNU Wget 1.21 -https'):
            with self.subTest(version=version):
                self.wget.write_text('#!/bin/sh\nprintf "%s\\n" ' + shlex.quote(version) + '\n')
                result = self.run_entry()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('GNU Wget', result.stderr)
                self.assertNotIn('离线', result.stderr)


    def transport(self, source, url, bound=128):
        text = (ROOT / 'ddnsto' / source).read_text()
        start = text.find('ddnsto_https_fetch() (')
        self.assertGreaterEqual(start, 0, source + ' lacks secure wget transport')
        function = text[start:text.index('\n)\n', start) + 3]
        return subprocess.run(['/bin/sh', '-c', function + '\nddnsto_https_fetch "$1" "$2" "$3"',
                               'test', url, str(self.work / 'download'), str(bound)],
                              env=self.env, cwd=self.work, capture_output=True, text=True, timeout=35)

    def test_all_bootstrap_transports_enforce_same_policy(self):
        for source in ('recommended-entry.sh', 'bootstrap-policy.sh', 'install-macos.sh'):
            for status, expected in ((200, 0), (201, 42), (204, 42), (404, 41), (503, 41), (403, 42), (302, 42)):
                with self.subTest(source=source, status=status):
                    self.server.modes['/body'] = (status, self.base.encode() + b'/redirected' if status == 302 else b'ok')
                    result = self.transport(source, self.base + '/body')
                    self.assertEqual(result.returncode, expected, result.stderr)
            self.server.modes['/body'] = (200, b'x' * 200000)
            self.assertEqual(self.transport(source, self.base + '/body').returncode, 42)
            self.assertLessEqual((self.work / 'download').stat().st_size, 131072)
            self.assertFalse((self.work / 'core').exists(), 'size bound must not leave core dumps')
            self.assertEqual(self.transport(source, 'http://localhost/body').returncode, 42)

    def test_linux_native_security_failure_does_not_try_another_mirror(self):
        script = '. "$1/lib/bootstrap.sh"\n. "$1/ddnsto/bootstrap-policy.sh"\n'
        script += 'bootstrap_fetch_from_base() { echo called; return 42; }\n'
        script += 'BOOTSTRAP_BASES="https://first https://second"\nbootstrap_fetch https native unused\n'
        result = subprocess.run(['/bin/sh', '-c', script, 'test', str(ROOT)],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 42)
        self.assertEqual(result.stdout.splitlines(), ['called'])

    def test_tls_handshake_failure_is_not_an_availability_failure(self):
        self.wget.write_text('''#!/bin/sh
case "$*" in *--version*) echo 'GNU Wget 1.21 +https'; exit 0 ;; esac
echo 'Unable to establish SSL connection.' >&2
exit 4
''')
        for source in ('recommended-entry.sh', 'bootstrap-policy.sh', 'install-macos.sh'):
            with self.subTest(source=source):
                self.assertEqual(self.transport(source, self.base + '/body').returncode, 42)

    def test_real_wget_accepts_benign_tls_headers(self):
        original = fixture.Handler.end_headers

        def headers(handler):
            handler.send_header('X-SSL-Protocol', 'TLSv1.3')
            handler.send_header('X-Certificate', 'certificate valid')
            original(handler)

        with mock.patch.object(fixture.Handler, 'end_headers', headers):
            for source in ('recommended-entry.sh', 'bootstrap-policy.sh', 'install-macos.sh'):
                for status, expected in ((200, 0), (503, 41)):
                    with self.subTest(source=source, status=status):
                        self.server.modes['/body'] = (status, b'ok')
                        self.assertEqual(self.transport(source, self.base + '/body').returncode, expected)
            self.prepare()
            result = self.run_entry()
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_real_curl_oversized_503_never_uses_cache(self):
        (self.bin / 'curl').symlink_to(shutil.which('curl'))
        self.prepare()
        self.assertEqual(self.run_entry().returncode, 0)
        (self.work / 'args').unlink()

        def oversized(handler):
            handler.send_response(503)
            handler.send_header('Content-Length', '4096')
            handler.end_headers()
            try:
                handler.wfile.write(b'x' * 4096)
            except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
                pass

        with mock.patch.object(fixture.Handler, 'do_GET', oversized):
            for source in ('recommended-entry.sh', 'bootstrap-policy.sh', 'install-macos.sh'):
                with self.subTest(source=source):
                    self.assertEqual(self.transport(source, self.base + '/body').returncode, 42)
            result = self.run_entry()
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('离线', result.stderr)
            self.assertFalse((self.work / 'args').exists())

    def test_curl_error_precedes_http_availability(self):
        curl = self.bin / 'curl'
        for code, expected in ((0, 41), (6, 41), (7, 41), (28, 41), (63, 42), (60, 42)):
            curl.write_text('#!/bin/sh\nprintf 503\nexit %s\n' % code)
            curl.chmod(0o700)
            for source in ('recommended-entry.sh', 'bootstrap-policy.sh', 'install-macos.sh'):
                with self.subTest(code=code, source=source):
                    self.assertEqual(self.transport(source, self.base + '/body').returncode, expected)

    def test_connection_refused_can_reuse_verified_cache(self):
        self.prepare()
        self.assertEqual(self.run_entry().returncode, 0)
        self.close_server()
        result = self.run_entry()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('离线', result.stderr)

    def test_curl_tls_error_never_falls_through_to_wget(self):
        curl = self.bin / 'curl'
        curl.write_text('#!/bin/sh\nexit 60\n')
        curl.chmod(0o700)
        self.wget.write_text('#!/bin/sh\necho called > "$HOME/wget-called"\nexit 0\n')
        for source in ('recommended-entry.sh', 'bootstrap-policy.sh', 'install-macos.sh'):
            self.assertEqual(self.transport(source, self.base + '/body').returncode, 42)
        self.assertFalse((self.work / 'wget-called').exists())

    def test_slow_continuous_body_has_total_deadline(self):
        def trickle(handler):
            handler.send_response(200)
            handler.send_header('Content-Length', '300')
            handler.end_headers()
            try:
                for _ in range(300):
                    handler.wfile.write(b'x')
                    handler.wfile.flush()
                    time.sleep(0.1)
            except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
                pass

        started = time.monotonic()
        with mock.patch.object(fixture.Handler, 'do_GET', trickle):
            result = self.transport('recommended-entry.sh', self.base + '/slow', 512)
        self.assertEqual(result.returncode, 41, result.stderr)
        self.assertGreater(time.monotonic() - started, 18)
        self.assertLess(time.monotonic() - started, 25)
        self.assertFalse((self.work / 'download.wget-response').exists())

    def test_interrupt_reaps_wget_and_watchdog(self):
        text = (ROOT / 'ddnsto/recommended-entry.sh').read_text()
        start = text.index('ddnsto_https_fetch() (')
        function = text[start:text.index('\n)\n', start) + 3]
        self.server.modes['/slow'] = (200, b'STALL_BODY')
        process = subprocess.Popen(['/bin/sh', '-c', function + '\nddnsto_https_fetch "$1" "$2" 128',
                                    'test', self.base + '/slow', str(self.work / 'cancelled')],
                                   env=self.env, cwd=self.work, start_new_session=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            time.sleep(0.3)
            os.killpg(process.pid, signal.SIGTERM)
            process.communicate(timeout=3)
            self.assertNotEqual(process.returncode, 0)
            time.sleep(0.2)
            self.assertFalse((self.work / 'cancelled.wget-response').exists())
            with self.assertRaises(ProcessLookupError):
                os.killpg(process.pid, 0)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate()

    def test_standalone_transport_copies_stay_identical(self):
        copies = []
        for source in ('recommended-entry.sh', 'bootstrap-policy.sh', 'install-macos.sh'):
            text = (ROOT / 'ddnsto' / source).read_text()
            start = text.index('ddnsto_https_fetch() (')
            copies.append(text[start:text.index('\n)\n', start) + 3])
        self.assertEqual(copies[0], copies[1])
        self.assertEqual(copies[0], copies[2])

    def test_macos_cold_bootstrap_with_real_wget_and_no_curl(self):
        case = mac_fixture.MacInstaller()
        case.setUp()
        self.addCleanup(case.doCleanups)
        case.prepare_cold_bootstrap()
        (case.bin / 'curl').unlink()
        (self.site / 'native-fixture').write_bytes((case.root / 'native-fixture').read_bytes())
        for tool in ('sed', 'grep', 'awk', 'tar', 'gzip', 'tr', 'dirname', 'basename', 'head', 'touch'):
            (self.bin / tool).symlink_to(shutil.which(tool))
        case.env['PATH'] = str(case.bin) + ':' + str(self.bin)
        case.env['FIXTURE_CA'] = str(self.cert)
        case.env['FIXTURE_NATIVE_URL'] = self.base + '/native-fixture'
        # Only rewrite the fixed public native URL to our local TLS server;
        # GNU Wget still parses every production option and validates TLS.
        case.tool('wget', '''
for argument do
    shift
    case "$argument" in https://*) set -- "$@" "$FIXTURE_NATIVE_URL" ;;
        *) set -- "$@" "$argument" ;; esac
done
exec ''' + shlex.quote(self.real_wget) + ''' --ca-certificate "$FIXTURE_CA" "$@"
''')
        sleeper = (case.bin / 'sleep').read_text()
        (case.bin / 'sleep').write_text('#!/bin/sh\n[ "$1" != 20 ] || exec ' +
                                       shlex.quote(shutil.which('sleep')) + ' "$@"\n' + sleeper)
        self.assertIsNone(shutil.which('curl', path=case.env['PATH']))
        result = case.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((case.install / 'ddnsto').exists())

    @unittest.skipUnless(os.environ.get('DDNSTO_TEST_NATIVE'), 'supply pinned Linux 0.5.0 binary')
    def test_wrapper_to_canonical_bootstrap_to_real_native_download_without_curl(self):
        native = Path(os.environ['DDNSTO_TEST_NATIVE']).read_bytes()
        self.assertEqual(fixture.sha(native), '9563b8442a75957792bb82a2d98a736142fc52be57dd2dc42005490096897617')
        native_dir = self.site / 'binary/zsetup/0.5.0'
        native_dir.mkdir(parents=True)
        (native_dir / 'zsetup-linux-x86_64').write_bytes(native)
        payload = b'fixture product downloaded by native zsetup only\n'
        (self.site / 'product').write_bytes(payload)
        # Use the real canonical bootstrap function with maintained source
        # overrides in a private fixture; repository generated entries stay put.
        canonical = (ROOT / 'ddnsto/ddnsto-install.sh').read_text()
        canonical = canonical[:canonical.rindex((ROOT / 'ddnsto/main.sh').read_text())]
        canonical += '\n' + (ROOT / 'ddnsto/bootstrap-policy.sh').read_text()
        canonical += '''
installer_dispatch() {
    "$ZSETUP_BIN" download --quiet --ca-file "$CURL_CA_BUNDLE" \\
      --sha256 "$PRODUCT_SHA" --size "$PRODUCT_SIZE" --max-bytes "$PRODUCT_SIZE" \\
      -o "$PRODUCT_OUT" "$PRODUCT_URL"
}
bootstrap_and_run "$@"
'''
        self.shell = canonical.encode()
        (self.source / 'ddnsto/ddnsto-install.sh').write_bytes(self.shell)
        self.env.update(ZSETUP_ROOT=str(self.work / 'native-cache'), ZSETUP_BIN='',
                        ZSETUP_BOOTSTRAP_BASES=self.base + '/binary',
                        PRODUCT_SHA=fixture.sha(payload), PRODUCT_SIZE=str(len(payload)),
                        PRODUCT_URL=self.base + '/product', PRODUCT_OUT=str(self.work / 'product'))
        self.prepare()
        result = self.run_entry()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.work / 'product').read_bytes(), payload)
        self.assertEqual((self.work / 'native-cache/rescue/0.5.0/zsetup').read_bytes(), native)


if __name__ == '__main__':
    unittest.main()
