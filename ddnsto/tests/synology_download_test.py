import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HARNESS = r'''
set -eu
[ ! -f "$SOURCE/synology-download.sh" ] || . "$SOURCE/synology-download.sh"
uname() { [ "$1" != -m ] || echo "$ARCH"; }
synopkg() { echo unexpected > "$FIXTURE/synopkg"; return 99; }
ddnsto_download() {
 printf '%s %s\n' "$1" "$3" >> "$FIXTURE/calls"
 [ "$DOWNLOAD_EMPTY" = 1 ] || printf 'verified fixture' > "$2"
 return "$DOWNLOAD_EXIT"
}
OUTPUT_DIR=${TEST_OUTPUT_DIR-"$FIXTURE/output"}
ACTION=$TEST_ACTION
ddnsto_synology_download
'''


class SynologyDownload(unittest.TestCase):
    def invoke(self, arch='x86_64', major='7', build='41890', action='download',
               version_text=None, repeat=False, **options):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            version = root / 'VERSION'
            version.write_text(version_text if version_text is not None else
                               f'majorversion="{major}"\nbuildnumber="{build}"\nevil="$(touch {directory}/executed)"\n')
            env = dict(os.environ, SOURCE=str(ROOT), FIXTURE=directory, ARCH=arch,
                       TEST_ACTION=action, DDNSTO_DSM_VERSION_FILE=str(version),
                       PLAN_ONLY='0', REQUESTED_METHOD='auto', TOKEN='', TOKEN_FILE='',
                       FORCE_VERSION='', VERIFY_STATUS='0', DOWNLOAD_EXIT='0', DOWNLOAD_EMPTY='0')
            env.update(options)
            if repeat:
                previous = subprocess.run(['sh', '-c', HARNESS], text=True, capture_output=True, env=env, cwd=root)
                self.assertEqual(previous.returncode, 0, previous.stderr)
            r = subprocess.run(['sh', '-c', HARNESS], text=True, capture_output=True,
                               env=env, cwd=root)
            self.assertFalse((root / 'executed').exists(), 'sourced vendor config')
            self.assertFalse((root / 'synopkg').exists(), 'called package installer')
            calls = (root / 'calls').read_text() if (root / 'calls').exists() else ''
            output = root / ('ddnsto-downloads' if options.get('TEST_OUTPUT_DIR') == '' else 'output')
            packages = list(output.rglob('*.spk'))
            if env['PLAN_ONLY'] == '1' or r.returncode not in (0, 20):
                self.assertFalse(packages)
            if env['PLAN_ONLY'] == '1':
                self.assertFalse(output.exists())
            if env['DOWNLOAD_EXIT'] != '0':
                self.assertFalse(list(output.rglob('*.part')))
            for package in packages:
                self.assertNotEqual(package.parent, output)
                self.assertEqual(package.read_text(), 'verified fixture')
            return r, calls, len(packages)

    def test_verified_download_and_no_install_claim(self):
        for arch, family in [('x86_64', 'x86'), ('armv7l', 'arm')]:
            for major, build in [('6', '5940'), ('7', '41890')]:
                r, calls, count = self.invoke(arch, major, build)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(count, 1)
                self.assertIn(f'synology/ddnsto_{family}-dsm{major}.spk', calls)
                self.assertRegex(calls, r' [a-f0-9]{64}\n')
                self.assertIn('installation_performed=false', r.stdout)
                self.assertIn('manual-required', r.stdout)
                self.assertIn('Package Center', r.stdout)
                self.assertIn('identity', r.stdout)
                self.assertIn('4.2.7-4', r.stdout)

    def test_pinned_checksums(self):
        expected = {
            ('armv7l', '6'): '0595dd1ae1681213acb35dfc61e15d877bfee19e59d5f4242a366540922b7f89',
            ('armv7l', '7'): 'bde9af2d3ff17f4bc5c609b79af39da7efd7209c59d03935492d1748bb84eba5',
            ('x86_64', '6'): '89d5871b7162edba9e4467a619d5d2eae19744d9cf637692e0695a1a4a701a83',
            ('x86_64', '7'): 'cccf82a0240c235d5eea6465ca9a339a9d92977345418ab72deb79ce2a3c8b59',
        }
        for (arch, major), digest in expected.items():
            r, calls, _ = self.invoke(arch=arch, major=major)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn(' ' + digest + '\n', calls)

    def test_install_handoff_is_not_success(self):
        r, _, count = self.invoke(action='install')
        self.assertEqual(r.returncode, 20, r.stderr)
        self.assertEqual(count, 1)

    def test_unknown_dsm_and_arm64_are_rejected_before_download(self):
        for arch, major, build in [('aarch64', '7', '41890'), ('i686', '7', '41890'), ('x86_64', '8', '1'), ('x86_64', '6', '5939'), ('x86_64', '7', '41889')]:
            r, calls, count = self.invoke(arch, major, build)
            self.assertEqual(r.returncode, 2, r.stderr)
            self.assertEqual((calls, count), ('', 0))

    def test_plan_has_no_download_or_output_directory(self):
        for action in ('download', 'install'):
            r, calls, count = self.invoke(action=action, PLAN_ONLY='1')
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual((calls, count), ('', 0))
            self.assertIn('installation_performed=false', r.stdout)
            self.assertIn('manual-required', r.stdout)

    def test_reject_credentials_install_options_and_wrong_actions(self):
        for option in ({'TOKEN': 'secret'}, {'TOKEN_FILE': '/never/read'},
                       {'FORCE_VERSION': 'standard'}, {'VERIFY_STATUS': '1'},
                       {'REQUESTED_METHOD': 'docker'}):
            r, calls, count = self.invoke(**option)
            self.assertEqual(r.returncode, 2, r.stderr)
            self.assertEqual((calls, count), ('', 0))
            self.assertNotIn('secret', r.stdout + r.stderr)
        for action in ('update', 'repair', 'configure', 'uninstall', 'status'):
            r, calls, count = self.invoke(action=action)
            self.assertEqual(r.returncode, 2, r.stderr)
            self.assertEqual((calls, count), ('', 0))

    def test_malformed_version_is_rejected(self):
        for contents in ('', 'majorversion="7"\n',
                         'majorversion="7"\nbuildnumber="not-a-number"\n',
                         'majorversion="7"\nmajorversion="6"\nbuildnumber="41890"\n',
                         'majorversion="7"\nmajorversion=""\nbuildnumber="41890"\n',
                         'majorversion="7"\nbuildnumber="41890"\nbuildnumber="1"\n',
                         'majorversion="7"\nbuildnumber="41890"\nbuildnumber=""\n',
                         'majorversion="7"\nbuildnumber="99999999999999999999999999"\n'):
            r, calls, _ = self.invoke(version_text=contents)
            self.assertEqual(r.returncode, 2, r.stderr)
            self.assertEqual(calls, '')

    def test_downloader_failure_propagates_without_package_or_handoff(self):
        r, calls, count = self.invoke(DOWNLOAD_EXIT='11', action='install')
        self.assertEqual(r.returncode, 11, r.stderr)
        self.assertTrue(calls)
        self.assertEqual(count, 0)
        self.assertNotIn('package_path=', r.stdout)

    def test_repeat_download_uses_separate_directories(self):
        r, _, count = self.invoke(repeat=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(count, 2)

    def test_no_package_is_not_download_success(self):
        r, _, count = self.invoke(DOWNLOAD_EMPTY='1')
        self.assertEqual(r.returncode, 11, r.stderr)
        self.assertEqual(count, 0)
        self.assertNotIn('package_path=', r.stdout)

    def test_version_shell_expressions_are_never_evaluated(self):
        r, calls, _ = self.invoke(version_text='majorversion="7"\nbuildnumber="$(exit 99)"\n')
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertEqual(calls, '')

    def test_whitespace_unquoted_version_and_armv7_alias(self):
        r, _, count = self.invoke(arch='armv7', version_text=' majorversion = 7\r\n buildnumber = 41890\r\n')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(count, 1)

    def test_native_method_allows_verified_download(self):
        r, calls, count = self.invoke(REQUESTED_METHOD='native')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(calls)
        self.assertEqual(count, 1)

    def test_default_output_directory_for_download_and_install(self):
        for action, expected in (('download', 0), ('install', 20)):
            r, _, count = self.invoke(action=action, TEST_OUTPUT_DIR='')
            self.assertEqual(r.returncode, expected, r.stderr)
            self.assertEqual(count, 1)
            self.assertIn('/ddnsto-downloads/ddnsto-synology.', r.stdout)

    def test_plan_with_native_and_default_output_creates_nothing(self):
        r, calls, count = self.invoke(REQUESTED_METHOD='native', TEST_OUTPUT_DIR='', PLAN_ONLY='1')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((calls, count), ('', 0))


if __name__ == '__main__':
    unittest.main()
