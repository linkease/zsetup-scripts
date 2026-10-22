#!/usr/bin/env python3
"""Default rerun must not download products, prompt for Token, or stop services."""
import os
import pty
import select
import time
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class RerunTest(unittest.TestCase):
    def invoke(self, args=(), complete=True, installed=True, platform='linux', direct=False):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'config').mkdir()
            tools = root / 'tools'
            tools.mkdir()
            for name in ('curl', 'wget'):
                tool = tools / name
                tool.write_text('#!/bin/sh\necho UNEXPECTED_DOWNLOAD >&2\nexit 99\n')
                tool.chmod(0o755)
            binary = root / 'ddnsto'
            if installed:
                binary.write_text('old binary')
                if complete:
                    (root / 'config/ddnsto-config.json').write_text('existing-private-config')
            env = os.environ | dict(ZSETUP_INSTALLER_MODE='0' if direct else '1', ZSETUP_BIN='/bin/false',
                PATH=str(tools) + ':/usr/bin:/bin', ZSETUP_ROOT=str(root / 'bootstrap'),
                ZSETUP_SOURCE_BASES='https://example.invalid', ZSETUP_OS=platform,
                ZSETUP_PACKAGE_MANAGER='opkg' if platform == 'openwrt' else 'unknown', ZSETUP_ARCH='x86_64',
                DDNSTO_BIN_PATH=str(binary), DDNSTO_LINUX_CONFIG_DIR=str(root / 'config'),
                DDNSTO_OPENWRT_BIN_PATH=str(binary), DDNSTO_CONFIG_PATH=str(root / 'config/ddnsto-config.json'),
                ZSETUP_WORK_DIR=str(root / 'work'))
            r = subprocess.run(['sh', str(ROOT / 'ddnsto/install.sh'), *args], env=env,
                               capture_output=True, text=True, timeout=5)
            self.assertFalse((root / 'work').exists(), 'created transaction on no-op or rejected request')
            if direct:
                self.assertFalse((root / 'bootstrap').exists(), 'no-op must not bootstrap')
                self.assertNotIn('UNEXPECTED_DOWNLOAD', r.stderr)
            if installed:
                self.assertEqual(binary.read_text(), 'old binary')
            return r

    def test_default_existing_install_is_noop_without_token(self):
        r = self.invoke()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('operation=none', r.stdout)
        self.assertIn('--action update', r.stdout)

    def test_openwrt_existing_install_is_noop(self):
        r = self.invoke(platform='openwrt')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('operation=none', r.stdout)

    def test_direct_existing_install_exits_without_bootstrap_even_offline(self):
        r = self.invoke(direct=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('operation=none', r.stdout)

    def test_docker_request_does_not_offer_native_update(self):
        r = self.invoke(('--method', 'docker'), direct=True)
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertNotIn('--action update', r.stdout)

    def test_interactive_menu_defaults_to_exit_and_requires_explicit_update(self):
        for answer, expected in [(b'\n', b'RESULT=exit'), (b'1\n', b'RESULT=update'),
                                 (b'2\n', b'RESULT=repair'), (b'3\n', b'RESULT=configure'),
                                 (b'4\n', b'RESULT=status'), (b'5\n', b'RESULT=stop'),
                                 (b'6\n', b'RESULT=start'), (b'7\n', b'RESULT=uninstall')]:
            with self.subTest(answer=answer):
                pid, terminal = pty.fork()
                if pid == 0:
                    os.execv('/bin/sh', ['sh', '-eu', '-c', '. "$1"; choice=$(ddnsto_choose_existing_action); printf "RESULT=%s" "$choice"',
                                        'test', str(ROOT / 'ddnsto/business.sh')])
                output = b''
                sent = False
                deadline = time.monotonic() + 5
                try:
                    while time.monotonic() < deadline:
                        if not select.select([terminal], [], [], .1)[0]:
                            continue
                        try:
                            part = os.read(terminal, 4096)
                        except OSError:
                            break
                        if not part:
                            break
                        output += part
                        if b'Choose [0]:' in output and not sent:
                            os.write(terminal, answer)
                            sent = True
                    else:
                        os.kill(pid, 15)
                        self.fail('menu timed out')
                finally:
                    os.close(terminal)
                    _, status = os.waitpid(pid, 0)
                self.assertEqual(os.waitstatus_to_exitcode(status), 0, output)
                self.assertIn(expected, output)

    def test_update_cannot_change_token(self):
        r = self.invoke(('--action', 'update', '--token', 'secret-value'))
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn('preserves', r.stderr)
        self.assertNotIn('secret-value', r.stdout + r.stderr)

    def test_existing_linux_cannot_ignore_platform_options(self):
        for args in [('--output-dir', '/tmp/unused'), ('--force-version', 'lite'), ('--verify-status',)]:
            r = self.invoke(args, direct=True)
            self.assertEqual(r.returncode, 2, r.stderr)
            self.assertNotIn('operation=none', r.stdout)

    def test_update_requires_existing_install(self):
        r = self.invoke(('--action', 'update'), installed=False)
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn('no existing installation', r.stderr)

    def test_incomplete_install_not_silently_reinstalled(self):
        r = self.invoke(complete=False)
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn('incomplete', r.stderr)

    def test_update_and_plan_cannot_be_mixed(self):
        r = self.invoke(('--plan', '--action', 'update'))
        self.assertEqual(r.returncode, 2, r.stderr)


if __name__ == '__main__':
    unittest.main()
