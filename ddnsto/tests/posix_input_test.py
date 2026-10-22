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

BUSINESS = Path(__file__).resolve().parents[1] / 'business.sh'


class InputContract(unittest.TestCase):
    def parse(self, *args):
        return subprocess.run(['sh', '-eu', '-c', '. "$1"; shift; ddnsto_parse_args "$@"; printf "%s" "$TOKEN"',
                               'test', str(BUSINESS), *args], capture_output=True, text=True)

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

    def test_openwrt_reuses_existing_token_before_package_changes(self):
        script = '. "$1"; TOKEN=; business_platform=openwrt; uci() { printf saved-token; }; ddnsto_prepare_token; printf "%s" "$TOKEN"'
        result = subprocess.run(['sh', '-eu', '-c', script, 'test', str(BUSINESS)], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'saved-token')

    def test_noninteractive_linux_requires_token_without_mutation(self):
        script = '. "$1"; TOKEN=; business_platform=linux; ddnsto_prepare_token'
        result = subprocess.run(['sh', '-eu', '-c', script, 'test', str(BUSINESS)], text=True, capture_output=True)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn('token', result.stderr.lower())

    def test_interactive_first_install_reads_visible_token(self):
        script = '. "$1"; TOKEN=; business_platform=linux; ddnsto_prepare_token; [ "$TOKEN" = private-fixture-token ]'
        pid, terminal = pty.fork()
        if pid == 0:
            os.execv('/bin/sh', ['sh', '-eu', '-c', script, 'test', str(BUSINESS)])
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
