"""Local TLS integration; executes inert installers, never host services.

Run: python3 -B tests/ddnsto_recommendation_test.py
Windows runtime cases require Windows PowerShell; absence is reported as a skip.
"""
import functools
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
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
PACKAGER = ROOT / 'scripts/package-ddnsto-recommendation.py'
SECRET = 'fixture-token-$() space'
PIN = '1' * 64
PWSH = os.environ.get('DDNSTO_TEST_PWSH') or shutil.which('pwsh')


def sha(data):
    return hashlib.sha256(data).hexdigest()


class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send_error(self, code, message=None, explain=None):
        if code == 404:
            # Cache-availability fixtures need an in-budget error response.
            # SimpleHTTPRequestHandler's HTML exceeds the 128-byte manifest
            # cap and correctly becomes a security failure with curl.
            self.send_response(404)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        super().send_error(code, message, explain)

    def do_GET(self):
        mode = self.server.modes.get(self.path)
        if mode:
            status, body = mode
            self.send_response(status)
            if body == b'STALL_BODY':
                self.send_header('Content-Length', '100')
                self.end_headers()
                self.wfile.write(b'x')
                self.wfile.flush()
                time.sleep(7)  # Exceeds the production 5s body-read timeout.
                return
            if status == 302:
                self.send_header('Location', body.decode())
            self.end_headers()
            if status != 302:
                self.wfile.write(body)
            return
        super().do_GET()


class Recommendation(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tls = tempfile.TemporaryDirectory(prefix='recommendation-tls-')
        cls.cert = Path(cls.tls.name) / 'cert.pem'
        key = Path(cls.tls.name) / 'key.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                        '-keyout', str(key), '-out', str(cls.cert), '-days', '1',
                        '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost'],
                       check=True, capture_output=True)
        cls.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        cls.context.load_cert_chain(cls.cert, key)

    @classmethod
    def tearDownClass(cls):
        cls.tls.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='recommendation-test-')
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.site = self.work / 'site'
        self.site.mkdir()
        self.server = http.server.ThreadingHTTPServer(
            ('127.0.0.1', 0), functools.partial(Handler, directory=str(self.site)))
        self.server.socket = self.context.wrap_socket(self.server.socket, server_side=True)
        self.server.modes = {}
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.close_server)
        self.base = 'https://localhost:%s' % self.server.server_port
        self.source = self.work / 'source'
        (self.source / 'ddnsto').mkdir(parents=True)
        self.shell = ("#!/bin/sh\n# reviewed product sha256 " + PIN + "\n"
                      "printf '%s\\n' \"$@\" > \"$FIXTURE_ARGS\"\n"
                      "exit \"${FIXTURE_EXIT:-0}\"\n").encode()
        self.ps = ("param([string]$Token, [string]$Action, [string]$InstallDir)\n"
                   "# reviewed product sha256 " + PIN + "\n"
                   "[IO.File]::WriteAllLines($env:FIXTURE_ARGS, [string[]]@($Token, $Action, $InstallDir))\n"
                   "if ($env:FIXTURE_EXIT) { exit ([int]$env:FIXTURE_EXIT) }\n"
                   "exit 0\n").encode()
        (self.source / 'ddnsto/ddnsto-install.sh').write_bytes(self.shell)
        (self.source / 'ddnsto/install.ps1').write_bytes(self.ps)
        self.env = dict(os.environ, CURL_CA_BUNDLE=str(self.cert),
                        DDNSTO_RECOMMEND_CACHE=str(self.work / 'cache'),
                        FIXTURE_ARGS=str(self.work / 'args'))
        self.env.pop('SHELLOPTS', None)

    def close_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def package(self, output=None, base=None, approved=None):
        return subprocess.run([
            sys.executable, '-B', str(PACKAGER), '--source-root', str(self.source),
            '--output', str(output or self.site / 'release'), '--source-url', base or self.base + '/release',
            '--reviewed-shell-sha256', approved or sha(self.shell),
            '--reviewed-powershell-sha256', sha(self.ps)], capture_output=True, text=True)

    def prepare(self):
        result = self.package()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.release = self.site / 'release'
        self.manifest = self.release / 'recommended-shell.txt'
        self.installer = self.release / 'immutable' / sha(self.shell) / 'install.sh'

    def run_entry(self, args=None):
        result = subprocess.run(['sh', str(self.release / 'recommended-entry.sh'),
                                 *(args if args is not None else ['--token', SECRET])],
                                env=self.env, capture_output=True, text=True, timeout=15)
        self.assertNotIn(SECRET, result.stdout + result.stderr)
        return result

    def test_package_exact_bytes_review_and_stable_entry(self):
        self.prepare()
        self.assertEqual(self.installer.read_bytes(), self.shell)
        self.assertEqual(self.manifest.read_text(), 'ddnsto-recommendation-v1-shell\n%s\n%s\n' % (sha(self.shell), len(self.shell)))
        review = json.loads((self.release / 'review.json').read_text())
        self.assertFalse(review['published'])
        self.assertEqual(review.get('candidate_version'), '0.2.4')
        self.assertIn(PIN, review['installers']['shell']['embedded_sha256'])
        first = (self.release / 'recommended-entry.sh').read_bytes()
        self.shell += b'# newer approved installer\n'
        (self.source / 'ddnsto/ddnsto-install.sh').write_bytes(self.shell)
        self.assertEqual(self.package(self.work / 'next').returncode, 0)
        self.assertEqual(first, (self.work / 'next/recommended-entry.sh').read_bytes())

    def test_asus_storage_helper_is_embedded_in_recommendation(self):
        self.prepare()
        entry = (self.release / 'recommended-entry.sh').read_text()
        self.assertIn('ddnsto_asus_storage()', entry)
        self.assertNotIn('@@ASUS_STORAGE@@', entry)
        self.assertEqual(subprocess.run(['sh', '-n', str(self.release / 'recommended-entry.sh')]).returncode, 0)

    def synology_entry(self):
        self.prepare()
        template = (self.release / 'recommended-entry.sh').read_text()
        template = template.replace('[ -f /etc/synoinfo.conf ] || [ -d /usr/syno ]', 'true')
        template = template.replace('/tmp/ddnsto-recommendation-$uid', str(self.work / 'dsm-cache'))
        entry = self.work / 'synology-entry.sh'
        entry.write_text(template)
        home = self.work / 'dsm-home'
        home.mkdir(mode=0o777)
        home.chmod(0o777)
        link = self.work / 'home-link'
        link.symlink_to(home, target_is_directory=True)
        env = self.env | {'HOME': str(link)}
        env.pop('DDNSTO_RECOMMEND_CACHE', None)
        return entry, env

    def test_synology_default_cache_avoids_acl_home_and_reuses_private_cache(self):
        entry, env = self.synology_entry()
        for _ in range(2):
            result = subprocess.run(['sh', str(entry), '--help'], env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.work / 'dsm-cache').stat().st_mode & 0o777, 0o700)
        self.assertFalse((self.work / 'dsm-home/.ddnsto-recommendation').exists())

    def test_synology_explicit_unsafe_cache_is_not_silently_replaced(self):
        entry, env = self.synology_entry()
        env['DDNSTO_RECOMMEND_CACHE'] = str(self.work / 'home-link/cache')
        result = subprocess.run(['sh', str(entry), '--help'], env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 12)
        self.assertFalse((self.work / 'dsm-cache').exists())

    def test_synology_default_cache_rejects_symlink_collision(self):
        entry, env = self.synology_entry()
        (self.work / 'dsm-cache').symlink_to(self.work / 'dsm-home', target_is_directory=True)
        result = subprocess.run(['sh', str(entry), '--help'], env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 12)
        self.assertFalse((self.work / 'args').exists())

    def test_asus_recommendation_does_not_require_id_stat_mktemp(self):
        self.prepare()
        template = (ROOT / 'ddnsto/recommended-entry.sh').read_text()
        self.assertIn('@@ASUS_STORAGE@@', template)
        fixtures = '''
ddnsto_asus_storage() { ASUS_STATE="$ASUS_FIXTURE"; mkdir -m 700 "$ASUS_STATE"; }
ddnsto_asus_fields() { /usr/bin/stat -c '0 %a %h' "$1"; }
ddnsto_asus_safe_ancestors() { [ -d "${1%/*}" ]; }
ddnsto_asus_mktemp() { /usr/bin/mktemp -d "$1/attempt.XXXXXXXX"; }
id() { return 99; }
stat() { return 99; }
mktemp() { return 99; }
'''
        template = template.replace('@@ASUS_STORAGE@@', fixtures)
        template = template.replace('[ -d /koolshare ] && [ -x /usr/bin/dbus ] && [ -x /bin/nvram ]', 'true')
        template = template.replace('@@SOURCE_URL@@', self.base + '/release').replace('@@CACHE_KEY@@', 'fixture')
        path = self.work / 'asus-entry.sh'
        path.write_text(template)
        env = self.env | {'ASUS_FIXTURE': str(self.work / 'asus')}
        env.pop('DDNSTO_RECOMMEND_CACHE', None)
        result = subprocess.run(['sh', str(path), '--token', SECRET], env=env,
                                text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.work / 'args').exists())
        self.assertNotIn(SECRET, result.stdout + result.stderr)

    def test_reject_unreviewed_bytes_and_existing_output(self):
        self.assertNotEqual(self.package(approved='0' * 64).returncode, 0)
        self.assertFalse((self.site / 'release').exists())
        self.prepare()
        self.assertNotEqual(self.package().returncode, 0)

    def test_reject_unsafe_source_urls(self):
        for base in ['http://localhost/x', 'https://user@localhost/x',
                     "https://localhost/a';exit 0;#", 'https://localhost/x?x=y',
                     'https://localhost/../x', 'https://localhost/%2e%2e/x']:
            with self.subTest(base=base):
                self.assertNotEqual(self.package(base=base).returncode, 0)
                self.assertFalse((self.site / 'release').exists())

    def test_success_argument_forwarding_and_exit_code(self):
        self.prepare()
        args = ['--token', SECRET, '--action', 'repair', '--installer-prefix', '/a b', '', '*']
        self.env['FIXTURE_EXIT'] = '23'
        result = self.run_entry(args)
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertEqual((self.work / 'args').read_text().splitlines(), args)

    def test_default_omits_action_for_core_ensure(self):
        self.prepare()
        self.assertEqual(self.run_entry().returncode, 0)
        self.assertEqual((self.work / 'args').read_text().splitlines(), ['--token', SECRET])

    def test_bsd_wc_padding_online_and_offline(self):
        self.prepare()
        bin_dir = self.work / 'bin'
        bin_dir.mkdir()
        wc = bin_dir / 'wc'
        wc.write_text('#!/bin/sh\nn=$("' + shutil.which('wc') + '" "$@") || exit $?\nprintf "%8s\\n" "$n"\n')
        wc.chmod(0o700)
        self.env['PATH'] = str(bin_dir) + os.pathsep + self.env['PATH']
        self.assertEqual(self.run_entry().returncode, 0)
        self.manifest.unlink()
        result = self.run_entry()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('离线', result.stderr)

    def test_powershell_entry_preserves_chinese_on_windows_51(self):
        self.prepare()
        entry = (self.release / 'recommended-entry.ps1').read_bytes()
        self.assertTrue(entry.startswith(b'\xef\xbb\xbf'), 'PowerShell 5.1 needs UTF-8 BOM for Chinese errors')

    def test_old_entry_reads_new_recommendation(self):
        self.prepare()
        self.shell += b'# second approved revision\n'
        (self.source / 'ddnsto/ddnsto-install.sh').write_bytes(self.shell)
        self.assertEqual(self.package(self.work / 'next').returncode, 0)
        shutil.copytree(self.work / 'next/immutable', self.release / 'immutable', dirs_exist_ok=True)
        shutil.copyfile(self.work / 'next/recommended-shell.txt', self.manifest)
        self.assertEqual(self.run_entry().returncode, 0)
        self.assertEqual((self.work / 'cache' / sha((self.base + '/release').encode()) / 'recommended.txt').read_bytes(), self.manifest.read_bytes())

    def test_missing_without_cache_fails(self):
        self.prepare()
        self.manifest.unlink()
        result = self.run_entry()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('code=', result.stderr)
        self.assertFalse((self.work / 'args').exists())

    def test_complete_cache_offline_warning(self):
        self.prepare()
        self.assertEqual(self.run_entry().returncode, 0)
        self.manifest.unlink()
        self.installer.unlink()
        result = self.run_entry()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('离线', result.stderr)

    def test_incomplete_or_tampered_cache_never_executes(self):
        for mode in ['missing', 'tampered']:
            with self.subTest(mode=mode):
                if not hasattr(self, 'release'):
                    self.prepare()
                self.assertEqual(self.run_entry().returncode, 0)
                saved = self.manifest.read_bytes()
                self.manifest.unlink()
                cached = self.work / 'cache' / sha((self.base + '/release').encode()) / (sha(self.shell) + '.sh')
                if mode == 'missing':
                    cached.unlink()
                else:
                    cached.write_bytes(b'x' * len(self.shell))
                (self.work / 'args').unlink()
                self.assertNotEqual(self.run_entry().returncode, 0)
                self.assertFalse((self.work / 'args').exists())
                self.manifest.write_bytes(saved)

    def test_remote_tamper_does_not_fall_back(self):
        self.prepare()
        self.assertEqual(self.run_entry().returncode, 0)
        (self.work / 'args').unlink()
        self.installer.write_bytes(b'x' * len(self.shell))
        self.assertNotEqual(self.run_entry().returncode, 0)
        self.assertFalse((self.work / 'args').exists())

    def test_invalid_manifest_strict_bounded_data_only(self):
        self.prepare()
        valid = self.manifest.read_bytes()
        for data in [valid + b'extra\n', valid.replace(b'\n', b'\r\n'),
                     valid.replace(b'\n', b'\x00\n', 1), b'x' * 4096,
                     b'$(touch BAD)\n', valid.replace(str(len(self.shell)).encode(), b'0001'),
                     valid.replace(str(len(self.shell)).encode(), b'99999999')]:
            with self.subTest(data=data[:50]):
                self.manifest.write_bytes(data)
                self.assertNotEqual(self.run_entry().returncode, 0)
                self.assertFalse((self.work / 'args').exists())

    def test_redirects_rejected_even_with_cache(self):
        self.prepare()
        self.assertEqual(self.run_entry().returncode, 0)
        (self.work / 'args').unlink()
        for location in ['http://localhost/evil', self.base + '/release/recommended-shell.txt', 'file:///etc/passwd']:
            self.server.modes['/release/recommended-shell.txt'] = (302, location.encode())
            self.assertNotEqual(self.run_entry().returncode, 0)
            self.assertFalse((self.work / 'args').exists())

    def test_unsafe_cache_and_symlink_rejected(self):
        self.prepare()
        cache = self.work / 'cache'
        cache.mkdir(mode=0o777)
        cache.chmod(0o777)
        self.assertNotEqual(self.run_entry().returncode, 0)
        cache.rmdir()
        cache.symlink_to(self.site, target_is_directory=True)
        self.assertNotEqual(self.run_entry().returncode, 0)
        self.assertFalse((self.work / 'args').exists())

    def test_unsupported_os_no_execution(self):
        self.prepare()
        bin_dir = self.work / 'bin'
        bin_dir.mkdir()
        uname = bin_dir / 'uname'
        uname.write_text('#!/bin/sh\nprintf "FreeBSD\\n"\n')
        uname.chmod(0o700)
        self.env['PATH'] = str(bin_dir) + os.pathsep + self.env['PATH']
        self.assertEqual(self.run_entry().returncode, 2)
        self.assertFalse((self.work / 'args').exists())

    def test_installer_missing_reuses_only_matching_cached_script(self):
        self.prepare()
        self.assertEqual(self.run_entry().returncode, 0)
        self.installer.unlink()
        result = self.run_entry()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('离线', result.stderr)
        self.manifest.write_text('ddnsto-recommendation-v1-shell\n' + '0' * 64 + '\n100\n')
        self.assertNotEqual(self.run_entry().returncode, 0)

    def test_bad_tls_never_uses_cache(self):
        self.prepare()
        self.assertEqual(self.run_entry().returncode, 0)
        self.env.pop('CURL_CA_BUNDLE')
        self.assertNotEqual(self.run_entry().returncode, 0)

    def test_hostile_native_is_not_run_for_version_discovery(self):
        self.prepare()
        hostile = self.work / 'zsetup'
        hostile.write_text('#!/bin/sh\ntouch "' + str(self.work / 'native-ran') + '"\n')
        hostile.chmod(0o700)
        self.env['ZSETUP_BIN'] = str(hostile)
        self.assertEqual(self.run_entry().returncode, 0)
        self.assertFalse((self.work / 'native-ran').exists())

    def test_canonical_sources_package_without_regeneration(self):
        before = {name: (ROOT / 'ddnsto' / name).read_bytes()
                  for name in ['ddnsto-install.sh', 'install.ps1']}
        self.source = ROOT
        self.shell, self.ps = before['ddnsto-install.sh'], before['install.ps1']
        self.prepare()
        self.assertEqual(self.installer.read_bytes(), self.shell)
        self.assertEqual((self.release / 'immutable' / sha(self.ps) / 'install.ps1').read_bytes(), self.ps)
        for name, data in before.items():
            self.assertEqual((ROOT / 'ddnsto' / name).read_bytes(), data)


@unittest.skipUnless(PWSH, 'set DDNSTO_TEST_PWSH to a PowerShell runtime')
class PowerShellReview(Recommendation):
    """Execute actual PS functions; mock only unavailable Windows ACL APIs.

    TLS, streaming reads, manifest parsing and SHA verification are real .NET.
    These tests do not claim Windows filesystem ACL enforcement coverage.
    """
    def ps_run(self, body, *, acl=False):
        source = (ROOT / 'ddnsto/recommended-entry.ps1').read_text()
        # Definitions only: never enter the Windows installer main function.
        definitions = source.split('\ntry {\n', 1)[0]
        if acl:
            definitions = definitions.replace(
                '[Security.Principal.WindowsIdentity]::GetCurrent().User.Value', "'S-1-5-21-1000'")
        script = self.work / 'review.ps1'
        script.write_text(definitions + '\n' + body, encoding='utf-8-sig')
        return subprocess.run([PWSH, '-NoProfile', '-NonInteractive', '-File', str(script)],
                              env=dict(self.env, SSL_CERT_FILE=str(self.cert),
                                       TEST_BASE=self.base + '/release', TEST_WORK=str(self.work)),
                              capture_output=True, text=True, timeout=25)

    def acl_run(self, owner, flags, private=False, identity='S-1-1-0'):
        return self.ps_run(r'''
function Get-Item { [pscustomobject]@{ Attributes = [IO.FileAttributes]::Directory } }
function Get-Acl {
    $acl = [pscustomobject]@{}
    $acl | Add-Member ScriptMethod GetOwner { param($type) [pscustomobject]@{ Value = 'OWNER' } }
    $acl | Add-Member ScriptMethod GetAccessRules { param($explicit, $inherited, $type)
        if ('FLAGS' -eq 'no-rule') { return @() }
        [pscustomobject]@{
            AccessControlType = [Security.AccessControl.AccessControlType]::Allow
            IdentityReference = [pscustomobject]@{Value = 'RULE_IDENTITY'}
            PropagationFlags = [Security.AccessControl.PropagationFlags]'FLAGS'
            FileSystemRights = [Security.AccessControl.FileSystemRights]::FullControl
        }
    }
    return $acl
}
try { Assert-SafePath '/fixture' PRIVATE; 'accepted' }
catch { 'rejected' }
'''.replace('OWNER', owner).replace('FLAGS', flags).replace('RULE_IDENTITY', identity).replace('PRIVATE', '-Private' if private else ''), acl=True)

    def test_ps_trustedinstaller_is_trusted_only_for_ancestors(self):
        owner = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
        for flags, identity, private, expected in [
            ('no-rule', 'S-1-1-0', False, 'accepted'),
            ('None', owner, False, 'accepted'),
            ('None', 'S-1-1-0', False, 'rejected'),
            ('no-rule', 'S-1-1-0', True, 'rejected'),
            ('None', owner, True, 'rejected'),
        ]:
            with self.subTest(flags=flags, identity=identity, private=private):
                result = self.acl_run(owner, flags, private, identity)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), expected)

    def test_ps_reject_foreign_ancestor_owner_without_writable_ace(self):
        result = self.acl_run('S-1-5-21-9999', 'no-rule')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'rejected')

    def test_ps_trusted_owners_and_inherit_only_ace(self):
        for owner in ['S-1-5-21-1000', 'S-1-5-18', 'S-1-5-32-544']:
            for private in [False, True]:
                with self.subTest(owner=owner, private=private):
                    result = self.acl_run(owner, 'InheritOnly', private)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.strip(), 'accepted')

    def test_ps_effective_foreign_write_ace_still_rejected(self):
        result = self.acl_run('S-1-5-21-1000', 'None')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'rejected')

    def test_ps_body_timeout_requires_complete_verified_cache(self):
        self.prepare()
        cache = self.work / 'ps-cache'
        cache.mkdir()
        shutil.copyfile(self.release / 'recommended-powershell.txt', cache / 'recommended.txt')
        cached = cache / (sha(self.ps) + '.ps1')
        cached.write_bytes(self.ps)
        source = (ROOT / 'ddnsto/recommended-entry.ps1').read_text()
        # Exercise the real fallback control flow, stopping before cache commit
        # and installer execution. Only ACL checks are unavailable on Linux.
        fallback = source[source.index('    $online = Receive-Bounded'):source.index('    # File.Replace')]
        harness = r'''
function Assert-SafePath { param($Path, [switch]$Private) }
$base = $env:TEST_BASE
$work = $env:TEST_WORK
$cache = Join-Path $work 'ps-cache'
$cachedManifest = Join-Path $cache 'recommended.txt'
$manifest = Join-Path $work 'download.txt'
$scriptPath = Join-Path $work 'download.ps1'
try {
FALLBACK
    'verified-cache'
} catch { 'rejected' }
'''.replace('FALLBACK', fallback)
        # First prove the fixture CA and HTTPS path work without disabling TLS.
        result = self.ps_run(harness)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'verified-cache', result.stderr)
        self.assertNotIn('离线', result.stderr)
        self.server.modes['/release/recommended-powershell.txt'] = (200, b'STALL_BODY')
        result = self.ps_run(harness)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'verified-cache', result.stderr)
        self.assertIn('离线', result.stderr)
        cached.write_bytes(b'x' * len(self.ps))
        result = self.ps_run(harness)
        self.assertEqual(result.stdout.strip(), 'rejected', result.stderr)
        cached.unlink()
        result = self.ps_run(harness)
        self.assertEqual(result.stdout.strip(), 'rejected', result.stderr)
        cached.write_bytes(self.ps)
        self.server.modes.clear()
        self.server.modes['/release/immutable/' + sha(self.ps) + '/install.ps1'] = (200, b'STALL_BODY')
        result = self.ps_run(harness)
        self.assertEqual(result.stdout.strip(), 'verified-cache', result.stderr)
        self.assertIn('离线', result.stderr)


@unittest.skipUnless(os.name == 'nt' and shutil.which('powershell'), 'requires native Windows PowerShell 5.1 / Windows ACLs')
class WindowsRecommendation(Recommendation):
    """Opt-in Windows fixtures: ephemeral CA added/removed in CurrentUser Root.

    Run on an isolated Windows test account with OpenSSL and
    DDNSTO_RECOMMEND_WINDOWS_TLS=1. Certificate checking is never disabled.
    """
    @classmethod
    def setUpClass(cls):
        if os.environ.get('DDNSTO_RECOMMEND_WINDOWS_TLS') != '1':
            raise unittest.SkipTest('set DDNSTO_RECOMMEND_WINDOWS_TLS=1 in an isolated Windows account')
        super().setUpClass()
        env = dict(os.environ, FIXTURE_CERT=str(cls.cert))
        result = subprocess.run(['powershell', '-NoProfile', '-NonInteractive', '-Command',
                                 "(Import-Certificate -FilePath $env:FIXTURE_CERT -CertStoreLocation Cert:\\CurrentUser\\Root).Thumbprint"],
                                env=env, capture_output=True, text=True, check=True)
        cls.thumbprint = result.stdout.strip()

    @classmethod
    def tearDownClass(cls):
        subprocess.run(['powershell', '-NoProfile', '-NonInteractive', '-Command',
                        "Remove-Item -LiteralPath ('Cert:\\CurrentUser\\Root\\' + $env:FIXTURE_THUMBPRINT)"],
                       env=dict(os.environ, FIXTURE_THUMBPRINT=cls.thumbprint), check=True, capture_output=True)
        super().tearDownClass()

    def prepare(self):
        super().prepare()
        self.manifest = self.release / 'recommended-powershell.txt'
        self.installer = self.release / 'immutable' / sha(self.ps) / 'install.ps1'

    def run_entry(self, args=None):
        result = subprocess.run(['powershell', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File',
                                 str(self.release / 'recommended-entry.ps1'),
                                 *(args if args is not None else ['-Token', SECRET])],
                                env=self.env, capture_output=True, text=True, timeout=30)
        self.assertNotIn(SECRET, result.stdout + result.stderr)
        return result

    def test_windows_exit_and_named_arguments(self):
        self.prepare()
        self.env['FIXTURE_EXIT'] = '23'
        result = self.run_entry(['-Token', SECRET, '-Action', 'repair', '-InstallDir', 'C:\\a b'])
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertEqual((self.work / 'args').read_text().splitlines(), [SECRET, 'repair', 'C:\\a b'])

    def test_windows_redirects(self):
        self.prepare()
        self.assertEqual(self.run_entry().returncode, 0)
        for target in ['http://localhost/evil', self.base + '/anything', 'file:///C:/Windows']:
            self.server.modes['/release/recommended-powershell.txt'] = (302, target.encode())
            self.assertNotEqual(self.run_entry().returncode, 0)

    def test_windows_invalid_manifest(self):
        self.prepare()
        data = self.manifest.read_bytes()
        for invalid in [data + b'junk', data.replace(b'\n', b'\r\n'), b'x' * 4096, b'$(Write-Host BAD)']:
            self.manifest.write_bytes(invalid)
            self.assertNotEqual(self.run_entry().returncode, 0)


# Share only platform-independent integration cases. POSIX permission/PATH/TLS
# environment tests must not masquerade as Windows runtime coverage.
for _name in list(vars(Recommendation)):
    if _name.startswith('test_'):
        setattr(PowerShellReview, _name, None)
    if _name.startswith('test_') and _name not in {
        'test_complete_cache_offline_warning', 'test_missing_without_cache_fails',
        'test_remote_tamper_does_not_fall_back',
    }:
        setattr(WindowsRecommendation, _name, None)


if __name__ == '__main__':
    unittest.main()
