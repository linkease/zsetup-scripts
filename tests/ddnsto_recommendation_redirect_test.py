"""Loopback-only TLS transport tests; no installers or host services run."""
import subprocess
import unittest

import ddnsto_recommendation_test as fixtures

ROOT, PWSH = fixtures.ROOT, fixtures.PWSH


class Redirects(unittest.TestCase):
    setUpClass = classmethod(fixtures.Recommendation.setUpClass.__func__)
    tearDownClass = classmethod(fixtures.Recommendation.tearDownClass.__func__)
    setUp = fixtures.Recommendation.setUp
    close_server = fixtures.Recommendation.close_server
    package = fixtures.Recommendation.package
    prepare = fixtures.Recommendation.prepare
    run_entry = fixtures.Recommendation.run_entry

    def test_https_redirects_preserve_integrity_and_argument_forwarding(self):
        self.prepare()
        self.server.modes['/release/recommended-shell.txt'] = (301, b'manifest')
        self.server.modes['/release/manifest'] = (200, self.manifest.read_bytes())
        installer_path = '/release/immutable/' + fixtures.sha(self.shell) + '/install.sh'
        self.server.modes[installer_path] = (302, (self.base + '/payload').encode())
        self.server.modes['/payload'] = (200, self.shell)
        args = ['--token', fixtures.SECRET, '--env', 'test', '--switch-environment']
        result = self.run_entry(args)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.work / 'args').read_text().splitlines(), args)
        (self.work / 'args').unlink()
        self.server.modes['/payload'] = (200, b'x' * len(self.shell))
        self.assertNotEqual(self.run_entry(args).returncode, 0)
        self.assertFalse((self.work / 'args').exists())

    def fetch(self, path, wget=False, trust=True):
        source = (ROOT / 'apps/ddnsto/source/recommended-entry.sh').read_text()
        function = source[source.index('ddnsto_https_fetch() ('):source.index('\nfetch() (')]
        prefix = ''
        if wget:
            # Only hide curl. Actual GNU wget performs TLS/status handling.
            prefix = ('command() { if [ "$2" = curl ]; then return 1; fi; '
                      'command "$@"; }\n'
                      'wget() { /usr/bin/wget --ca-certificate="$CURL_CA_BUNDLE" "$@"; }\n')
        env = dict(self.env)
        if not trust:
            env.pop('CURL_CA_BUNDLE', None)
        return subprocess.run(['sh', '-c', prefix + function + '\nddnsto_https_fetch "$1" "$2" 128',
                               'fixture', self.base + path, str(self.work / 'body')],
                              env=env, capture_output=True, text=True, timeout=25)

    def chain(self, count):
        for n in range(count):
            self.server.modes['/hop%s' % n] = (301 if n % 2 else 302, ('hop%s' % (n + 1)).encode())
        self.server.modes['/hop%s' % count] = (200, b'verified-body')

    def test_curl_follows_five_relative_https_redirects(self):
        self.chain(5)
        result = self.fetch('/hop0')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.work / 'body').read_bytes(), b'verified-body')
        self.assertEqual(len(self.server.requests), 6)

    def test_curl_refuses_sixth_redirect(self):
        self.chain(6)
        self.assertEqual(self.fetch('/hop0').returncode, 42)
        self.assertNotIn('/hop6', self.server.requests)

    def test_curl_rejects_http_and_file_redirects(self):
        for target in ['http://localhost:1/never', 'file:///etc/passwd']:
            with self.subTest(target=target):
                self.server.modes['/start'] = (302, target.encode())
                self.assertEqual(self.fetch('/start').returncode, 42)

    def test_redirected_body_still_bounded(self):
        self.server.modes['/start'] = (301, b'/large')
        self.server.modes['/large'] = (200, b'x' * 256)
        self.assertEqual(self.fetch('/start').returncode, 42)

    def test_untrusted_certificate_is_security_failure(self):
        self.server.modes['/ok'] = (200, b'ok')
        self.assertEqual(self.fetch('/ok', trust=False).returncode, 42)

    def test_wget_safely_refuses_redirect_and_explains_curl_requirement(self):
        self.server.modes['/ok'] = (200, b'ok')
        self.assertEqual(self.fetch('/ok', wget=True).returncode, 0)
        for target in [b'/ok', b'http://localhost:1/never']:
            self.server.requests.clear()
            self.server.modes['/start'] = (302, target)
            result = self.fetch('/start', wget=True)
            self.assertEqual(result.returncode, 42)
            self.assertEqual(self.server.requests, ['/start'])
            self.assertIn('请安装 curl 后重试', result.stderr)

    def test_powershell_parameters_are_validated_and_forwarded(self):
        source = (ROOT / 'apps/ddnsto/source/recommended-entry.ps1').read_text()
        self.assertIn("[ValidateSet('test', 'production')][string]$Environment", source)
        self.assertIn('[switch]$SwitchEnvironment', source)
        self.assertIn('$forward = @{} + $PSBoundParameters', source)

    def test_powershell_redirect_guards_exist_without_runtime(self):
        source = (ROOT / 'apps/ddnsto/source/recommended-entry.ps1').read_text()
        self.assertIn('$request.AllowAutoRedirect = $false', source)
        self.assertIn('$redirects -ge 5', source)
        self.assertIn("$target.Scheme -ne 'https'", source)
        self.assertIn('[Uri]::new($target, $location)', source)


@unittest.skipUnless(PWSH, 'PowerShell runtime unavailable')
class PowerShellRedirects(Redirects):
    ps_run = fixtures.PowerShellReview.ps_run

    def receive(self, path):
        return self.ps_run('try { Receive-Bounded ($env:TEST_BASE + "' + path + '") '
                           '(Join-Path $env:TEST_WORK "body") 128 } catch { "security-failure" }')

    def test_ps_follows_relative_and_absolute_https(self):
        self.server.modes['/release/start'] = (301, b'next')
        self.server.modes['/release/next'] = (302, (self.base + '/ok').encode())
        self.server.modes['/ok'] = (200, b'ok')
        result = self.receive('/start')
        self.assertEqual(result.stdout.strip(), 'True', result.stderr)

    def test_ps_five_hops_then_security_failure(self):
        for n in range(5):
            self.server.modes['/release/hop%s' % n] = (302, ('hop%s' % (n + 1)).encode())
        self.server.modes['/release/hop5'] = (200, b'ok')
        result = self.receive('/hop0')
        self.assertEqual(result.stdout.strip(), 'True', result.stderr)
        self.server.requests.clear()
        for n in range(6):
            self.server.modes['/release/hop%s' % n] = (302, ('hop%s' % (n + 1)).encode())
        self.server.modes['/release/hop6'] = (200, b'ok')
        result = self.receive('/hop0')
        self.assertEqual(result.stdout.strip(), 'security-failure', result.stderr)
        self.assertNotIn('/release/hop6', self.server.requests)

    def test_ps_downgrade_is_not_availability_fallback(self):
        self.server.modes['/release/start'] = (302, b'http://localhost:1/never')
        result = self.receive('/start')
        self.assertEqual(result.stdout.strip(), 'security-failure', result.stderr)

    def test_ps_environment_named_forwarding_and_validation(self):
        result = self.ps_run('$forward | ConvertTo-Json -Compress',
                             args=['-Environment', 'test', '-SwitchEnvironment'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('"Environment":"test"', result.stdout)
        self.assertIn('"SwitchEnvironment"', result.stdout)
        invalid = self.ps_run("'must-not-run'", args=['-Environment', 'custom'])
        self.assertNotEqual(invalid.returncode, 0)
        self.assertNotIn('must-not-run', invalid.stdout)


# Avoid inheriting shell tests into the optional PowerShell group.
for name in vars(Redirects):
    if name.startswith('test_'):
        setattr(PowerShellRedirects, name, None)

if __name__ == '__main__':
    unittest.main()
