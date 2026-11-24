"""Published x86_64 native contracts; inert HTTPS bodies, no host services.

ZSETUP_TEST_NATIVE must point to one of the reviewed release bytes below.
The downloaded program is verified before --version or any other execution.
"""
import hashlib
import http.server
import io
import json
import os
from pathlib import Path
import shlex
import ssl
import subprocess
import sys
import tarfile
import tempfile
import threading
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[4] / 'tests'))
from tls_fixture import generate_certificate
from asus_package_test import members, elf

PINS = {
    '9563b8442a75957792bb82a2d98a736142fc52be57dd2dc42005490096897617': '0.5.0',
    '9e87c8bf447cc14eb1a8d2ebfc5cfc2377bed4fcb99539c9175b644f5f10a237': '0.6.4',
}
BODY = b'inert native contract fixture\n'


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Length', str(len(BODY)))
        self.end_headers()
        self.wfile.write(BODY)

    def log_message(self, *_):
        pass


class NativeReuseContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        native = os.environ.get('ZSETUP_TEST_NATIVE')
        if not native:
            raise unittest.SkipTest('set ZSETUP_TEST_NATIVE to a reviewed release')
        cls.native = str(Path(native).resolve())
        digest = hashlib.sha256(Path(cls.native).read_bytes()).hexdigest()
        if digest not in PINS:
            raise RuntimeError('unreviewed native bytes; refusing execution')
        cls.version = PINS[digest]
        cls.tls_dir = tempfile.TemporaryDirectory(prefix='ddnsto-native-tls-')
        cls.addClassCleanup(cls.tls_dir.cleanup)
        root = Path(cls.tls_dir.name)
        generate_certificate(root)
        cls.ca = str(root / 'ca.crt')
        cls.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(root / 'server.crt', root / 'server.key')
        cls.server.socket = context.wrap_socket(cls.server.socket, server_side=True)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.addClassCleanup(cls.server.server_close)
        cls.addClassCleanup(cls.thread.join, 3)
        cls.addClassCleanup(cls.server.shutdown)
        cls.url = f'https://127.0.0.1:{cls.server.server_port}/fixture'

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='ddnsto-native-case-')
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)

    def run_native(self, *args):
        return subprocess.run([self.native, *map(str, args)], cwd=self.work,
                              text=True, capture_output=True, timeout=20)

    def download(self, *, digest=None, size=None, ceiling=None, trust=True):
        args = ['download', '-o', self.work / 'payload', '--sha256',
                digest or hashlib.sha256(BODY).hexdigest(), '--size',
                len(BODY) if size is None else size, '--max-bytes',
                len(BODY) if ceiling is None else ceiling,
                '--min-free-bytes', 8388608, '--overall-timeout', '5s']
        if trust:
            args += ['--ca-file', self.ca]
        return self.run_native(*args, self.url)

    def test_download_checks_digest_and_exact_size(self):
        result = self.download()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.work / 'payload').read_bytes(), BODY)

    def test_download_rejects_wrong_digest_without_publication(self):
        result = self.download(digest='0' * 64)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.work / 'payload').exists())

    def test_download_rejects_wrong_size_without_publication(self):
        result = self.download(size=len(BODY) + 1, ceiling=len(BODY) + 1)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.work / 'payload').exists())

    def test_download_rejects_untrusted_tls_without_publication(self):
        result = self.download(trust=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.work / 'payload').exists())

    def test_download_rechecks_existing_same_size_changed_bytes(self):
        first = self.download()
        self.assertEqual(first.returncode, 0, first.stderr)
        (self.work / 'payload').write_bytes(b'x' * len(BODY))
        result = self.download()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.work / 'payload').read_bytes(), BODY)

    def test_storage_private_directory_contract(self):
        result = self.run_native('storage', self.work, '--json')
        self.assertEqual(result.returncode, 0, result.stderr)
        facts = json.loads(result.stdout)
        self.assertTrue(facts['private_directory'])
        self.assertEqual(facts['effective_uid'], os.geteuid())
        self.assertGreater(facts['available_bytes'], 0)

    def test_private_directory_does_not_prove_single_link_file(self):
        original = self.work / 'original'
        original.write_bytes(BODY)
        os.link(original, self.work / 'second-name')
        result = self.run_native('storage', self.work, '--json')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads(result.stdout)['private_directory'])
        self.assertEqual(original.stat().st_nlink, 2)
        # A true private_directory result cannot replace the file's link check.
        source = Path(__file__).resolve().parents[4] / 'sources/ddnsto' / 'portable-files.sh'
        fields = subprocess.run(['sh', '-c', '. "$1"; ddnsto_file_fields "$2"',
            'test', str(source), str(original)], text=True, capture_output=True)
        self.assertEqual(fields.returncode, 0, fields.stderr)
        self.assertEqual(fields.stdout.split()[2], '2')

    def test_capture_rejects_impossible_space_reserve(self):
        result = self.run_native('capture', '-o', self.work / 'captured',
            '--max-bytes', 64, '--min-free-bytes', 9223372036854775807,
            '--timeout', '1s', '--', 'printf', 'payload')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.work / 'captured').exists())

    def test_capture_timeout_does_not_publish_partial_output(self):
        result = self.run_native('capture', '-o', self.work / 'captured',
            '--max-bytes', 64, '--min-free-bytes', 8388608,
            '--timeout', '1s', '--', 'sh', '-c', 'printf partial; exec sleep 3')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.work / 'captured').exists())

    def test_asus_fetch_uses_real_native_without_shell_rehash(self):
        source = Path(__file__).resolve().parents[4] / 'sources/ddnsto' / 'auto-asus.sh'
        script = f'''
set -eu
. {shlex.quote(str(source))}
ASUS_CHANNEL=rogsoft
ddnsto_asus_native() {{ ASUS_ZSETUP=fixture_native; }}
fixture_native() {{ "$NATIVE" "$@" --ca-file "$CA" --overall-timeout 5s; }}
ddnsto_asus_package() {{ printf '%s\\n' "$URL 4.2.8 arm384 $SIZE $DIGEST"; }}
ddnsto_asus_hash() {{ echo unexpected-shell-rehash >&2; return 99; }}
ddnsto_asus_transport() {{ echo unexpected-legacy-fallback >&2; return 99; }}
ddnsto_asus_fetch "$OUTPUT"
'''
        for digest, size, success in (
            (hashlib.sha256(BODY).hexdigest(), len(BODY), True),
            ('0' * 64, len(BODY), False),
            (hashlib.sha256(BODY).hexdigest(), len(BODY) + 1, False),
        ):
            with self.subTest(digest=digest, size=size):
                output = self.work / f'payload-{size}-{digest}'
                result = subprocess.run(['sh', '-c', script], capture_output=True,
                                        text=True, timeout=20, cwd=self.work,
                                        env=os.environ | {'NATIVE': self.native, 'CA': self.ca,
                                            'URL': self.url, 'SIZE': str(size), 'DIGEST': digest,
                                            'OUTPUT': str(output)})
                self.assertEqual(result.returncode, 0 if success else 11, result.stderr)
                self.assertNotIn('unexpected-', result.stderr)
                self.assertEqual(output.exists(), success)
                if success:
                    self.assertEqual(output.read_bytes(), BODY)

    def require_archive(self):
        if self.version != '0.6.4':
            self.skipTest('archive/checksum not required of pinned 0.5.0')

    def test_asus_capture_delegates_bounds_to_trusted_native(self):
        source = Path(__file__).resolve().parents[4] / 'sources/ddnsto' / 'asus-package.sh'
        archive = self.work / 'fixture.tar.gz'
        with tarfile.open(archive, 'w:gz') as output:
            member = tarfile.TarInfo('payload')
            member.size = len(BODY)
            output.addfile(member, io.BytesIO(BODY))
        for limit, member, success in ((len(BODY), 'payload', True),
                                       (1, 'payload', False),
                                       (len(BODY), 'missing', False)):
            with self.subTest(limit=limit, member=member):
                output = self.work / f'capture-{limit}-{member}'
                script = f'''
set -eu
. {shlex.quote(str(source))}
channel=rogsoft
ASUS_ZSETUP=fixture_native
fixture_native() {{ echo native-capture >&2; "$NATIVE" "$@"; }}
_ddnsto_asus_package_tar() {{ echo unexpected-legacy-capture >&2; return 99; }}
_ddnsto_asus_package_capture "$LIMIT" "$OUTPUT" -xOzf "$ARCHIVE" "$MEMBER"
'''
                result = subprocess.run(['sh', '-c', script], text=True,
                    capture_output=True, timeout=20, cwd=self.work,
                    env=os.environ | {'NATIVE': self.native, 'LIMIT': str(limit),
                        'OUTPUT': str(output), 'ARCHIVE': str(archive), 'MEMBER': member})
                self.assertIn('native-capture', result.stderr)
                self.assertNotIn('unexpected-legacy-capture', result.stderr)
                self.assertEqual(result.returncode == 0, success, result.stderr)
                if success:
                    self.assertEqual(output.read_bytes(), BODY)
                else:
                    self.assertFalse(output.exists())

    def test_asus_armsoft_capture_does_not_invoke_native(self):
        source = Path(__file__).resolve().parents[4] / 'sources/ddnsto' / 'asus-package.sh'
        result = subprocess.run(['sh', '-eu', '-c', f'''
. {shlex.quote(str(source))}
channel=armsoft
ASUS_ZSETUP=unexpected_native
unexpected_native() {{ echo unexpected-native >&2; return 99; }}
_ddnsto_asus_package_tar() {{ printf payload; }}
_ddnsto_asus_package_capture 7 "$1"
''', 'test', str(self.work / 'legacy')], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('unexpected-native', result.stderr)
        self.assertEqual((self.work / 'legacy').read_bytes(), b'payload')

    def test_asus_extractor_keeps_business_checks_with_native_capture(self):
        app = Path(__file__).resolve().parents[4] / 'sources/ddnsto'
        for variant in ('valid', 'duplicate', 'wrong-channel', 'wrong-version'):
            with self.subTest(variant=variant):
                entries = members()
                if variant == 'duplicate':
                    entries.append(entries[-1])
                if variant == 'wrong-version':
                    entries = [(info, b'9.9.9\n' if info.name == 'ddnsto/version' else data)
                               for info, data in entries]
                archive = self.work / f'{variant}.tar.gz'
                with tarfile.open(archive, 'w:gz', format=tarfile.USTAR_FORMAT) as output:
                    for info, data in entries:
                        output.addfile(info, io.BytesIO(data))
                dest = self.work / variant
                script = f'''
set -eu
. {shlex.quote(str(app / 'asus-platform.sh'))}
. {shlex.quote(str(app / 'asus-package.sh'))}
ASUS_ZSETUP=$NATIVE
ddnsto_asus_extract "$ARCHIVE" "$DEST" "$CHANNEL" aarch64
'''
                result = subprocess.run(['sh', '-c', script], text=True,
                    capture_output=True, timeout=20, cwd=self.work,
                    env=os.environ | {'NATIVE': self.native, 'ARCHIVE': str(archive),
                        'DEST': str(dest), 'CHANNEL': 'mtksoft' if variant == 'wrong-channel' else 'rogsoft'})
                if variant == 'valid':
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual({p.name for p in dest.iterdir()},
                                     {'ddnsto', 'Module_ddnsto.asp', 'icon-ddnsto.png'})
                    self.assertEqual((dest / 'ddnsto').read_bytes(), elf('aarch64'))
                    self.assertEqual((dest / 'ddnsto').stat().st_mode & 0o777, 0o700)
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(dest.exists(), result.stderr)

    def test_checksum_output_is_plain_sha256(self):
        self.require_archive()
        path = self.work / 'input'
        path.write_bytes(BODY)
        result = self.run_native('checksum', path)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, hashlib.sha256(BODY).hexdigest() + '\n')

    def archive(self, names=('package/payload',), kind=None, max_bytes=4096, max_files=8,
                mode=0o644):
        archive = self.work / 'fixture.tar.gz'
        with tarfile.open(archive, 'w:gz', format=tarfile.USTAR_FORMAT) as output:
            for name in names:
                member = tarfile.TarInfo(name)
                member.mode = mode
                if kind:
                    member.type = kind
                    member.linkname = '../../escaped'
                    output.addfile(member)
                else:
                    member.size = len(BODY)
                    output.addfile(member, io.BytesIO(BODY))
        return self.run_native('archive', 'extract', '-i', archive, '-o', self.work / 'out',
                               '--root', 'package', '--max-bytes', max_bytes,
                               '--max-files', max_files, '--min-free-bytes', 8388608)

    def test_archive_extracts_inert_regular_member(self):
        self.require_archive()
        result = self.archive()
        self.assertEqual(result.returncode, 0, result.stderr)
        files = list((self.work / 'out').rglob('payload'))
        self.assertEqual(len(files), 1)
        self.assertEqual(files[0].read_bytes(), BODY)

    def test_archive_rejects_traversal(self):
        self.require_archive()
        result = self.archive(names=('package/../escaped',))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.work / 'escaped').exists())

    def test_archive_rejects_symlink(self):
        self.require_archive()
        self.assertNotEqual(self.archive(kind=tarfile.SYMTYPE).returncode, 0)

    def test_archive_rejects_hardlink(self):
        self.require_archive()
        self.assertNotEqual(self.archive(kind=tarfile.LNKTYPE).returncode, 0)

    def test_archive_rejects_duplicate_member(self):
        self.require_archive()
        self.assertNotEqual(self.archive(names=('package/payload',) * 2).returncode, 0)

    def test_archive_rejects_special_files(self):
        self.require_archive()
        for kind in (tarfile.CHRTYPE, tarfile.BLKTYPE, tarfile.FIFOTYPE):
            with self.subTest(kind=kind):
                self.assertNotEqual(self.archive(kind=kind).returncode, 0)
                self.assertFalse((self.work / 'out' / 'payload').exists())

    def test_archive_rejects_absolute_member(self):
        self.require_archive()
        escaped = self.work / 'escaped'
        self.assertNotEqual(self.archive(names=(str(escaped),)).returncode, 0)
        self.assertFalse(escaped.exists())

    def test_archive_rejects_wrong_business_root(self):
        self.require_archive()
        self.assertNotEqual(self.archive(names=('other/payload',)).returncode, 0)

    def test_archive_rejects_file_directory_collision(self):
        self.require_archive()
        self.assertNotEqual(self.archive(names=('package/a', 'package/a/b')).returncode, 0)

    def test_archive_does_not_publish_privileged_mode(self):
        self.require_archive()
        result = self.archive(mode=0o6755)
        if result.returncode == 0:
            files = list((self.work / 'out').rglob('payload'))
            self.assertEqual(len(files), 1)
            self.assertEqual(files[0].stat().st_mode & 0o6000, 0)

    def test_storage_world_writable_directory_is_not_private(self):
        self.work.chmod(0o777)
        result = self.run_native('storage', self.work, '--json')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(json.loads(result.stdout)['private_directory'])

    def test_archive_rejects_expansion_over_budget(self):
        self.require_archive()
        self.assertNotEqual(self.archive(max_bytes=1).returncode, 0)

    def test_archive_rejects_entry_count_over_budget(self):
        self.require_archive()
        self.assertNotEqual(self.archive(names=('package/a', 'package/b'), max_files=1).returncode, 0)


if __name__ == '__main__':
    unittest.main()
