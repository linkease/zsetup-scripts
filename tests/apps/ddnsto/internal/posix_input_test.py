#!/usr/bin/env python3
"""Execute maintained POSIX argument parsing, including private token files."""
import os
import pty
import select
import time
from pathlib import Path
import subprocess
import tempfile
import unittest

BUSINESS = Path(__file__).resolve().parents[4] / 'apps/ddnsto/source' / 'business.sh'
CLI = Path(__file__).resolve().parents[4] / 'apps/ddnsto/source' / 'managed-cli.sh'


class InputContract(unittest.TestCase):
    def parse(self, *args):
        script = 'ddnsto_error() { printf "%s\\n" "$1" >&2; }; . "$1"; shift; ddnsto_parse_args "$@"; printf "%s" "$TOKEN"'
        return subprocess.run(['sh', '-eu', '-c', script, 'test', str(CLI), *args],
                              capture_output=True, text=True)

    def test_file_input_and_conflicts(self):
        with tempfile.TemporaryDirectory() as directory:
            token = Path(directory) / 'token'
            token.write_text('placeholder-token\n')
            token.chmod(0o600)
            result = self.parse('--token-file', str(token))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, 'placeholder-token')
            conflict = self.parse('--token', 'other', '--token-file', str(token))
            self.assertEqual(conflict.returncode, 2)
            token.write_text('one\ntwo\n')
            self.assertEqual(self.parse('--token-file', str(token)).returncode, 2)

    def test_invalid_inputs_not_echoed(self):
        for args in [('--token', 'one\ntwo'), ('--secret=private-value',)]:
            result = self.parse(*args)
            self.assertEqual(result.returncode, 2)
            self.assertNotIn('private-value', result.stderr)

    def test_explicit_openwrt_install_allows_missing_token(self):
        result = self.parse('--action', 'install', '--platform', 'openwrt')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '')

    @staticmethod
    def linux_metadata_script(command):
        return f'''
ddnsto_error() {{ printf '%s\n' "$1" >&2; }}
status() {{ :; }}
ddnsto_pinned_sha() {{ printf '%064d\n' 0; }}
. "$1"
. "$2"
TOKEN= ACTION=install BUSINESS_ENV=production arch=x86_64 FORCE_VERSION= VERIFY_STATUS=0
{command}
'''

    def test_noninteractive_linux_requires_token_without_mutation(self):
        script = self.linux_metadata_script('ddnsto_linux_metadata')
        result = subprocess.run(['sh', '-eu', '-c', script, 'test', str(CLI), str(BUSINESS)],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn('token', result.stderr.lower())

    def test_interactive_first_install_reads_visible_token(self):
        script = self.linux_metadata_script(
            'ddnsto_linux_metadata; [ "$TOKEN" = private-fixture-token ]')
        pid, terminal = pty.fork()
        if pid == 0:
            os.execv('/bin/sh', ['sh', '-eu', '-c', script, 'test', str(CLI), str(BUSINESS)])
        output = b''
        sent = False
        deadline = time.monotonic() + 10
        try:
            while time.monotonic() < deadline:
                if not select.select([terminal], [], [], 0.1)[0]:
                    continue
                try:
                    part = os.read(terminal, 4096)
                except OSError:
                    break
                if not part:
                    break
                output += part
                if b'DDNSTO token:' in output and not sent:
                    os.write(terminal, b'private-fixture-token\n')
                    sent = True
            else:
                os.kill(pid, 15)
                self.fail('token prompt timed out')
        finally:
            os.close(terminal)
            _, status = os.waitpid(pid, 0)
        self.assertEqual(os.waitstatus_to_exitcode(status), 0, output.decode())
        self.assertTrue(sent)
        self.assertIn(b'private-fixture-token', output)


if __name__ == '__main__':
    unittest.main()
