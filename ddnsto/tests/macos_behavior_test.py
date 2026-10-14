#!/usr/bin/env python3
"""Execute the installer with isolated native-download/launchd boundaries."""
import os
from pathlib import Path
import plistlib
import pty
import select
import time
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'install-macos.sh'


class MacInstaller(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.install = self.root / 'install'
        self.config = self.root / 'config & data'
        self.agents = self.root / 'agents'
        self.env = os.environ | {
            'PATH': str(self.bin) + ':' + os.environ['PATH'],
            'DDNSTO_INSTALL_DIR': str(self.install), 'DDNSTO_CONFIG_DIR': str(self.config),
            'DDNSTO_LAUNCH_AGENTS_DIR': str(self.agents), 'TEST_ROOT': str(self.root),
            'ZSETUP_BIN': str(self.bin / 'zsetup'),
        }
        self.tool('uname', 'echo "${TEST_OS:-Darwin}"\n')
        # uname -m needs its architecture; all other native platform probes are isolated.
        self.tool('uname', '[ "$1" != -m ] || { echo "${TEST_ARCH:-arm64}"; exit; }; echo "${TEST_OS:-Darwin}"\n')
        self.tool('zsetup', '''
[ "$1" != --version ] || { echo 'zsetup 0.3.0'; exit; }
[ "${FAIL_DOWNLOAD:-0}" = 0 ] || exit 11
while [ "$#" -gt 0 ]; do
 if [ "$1" = -o ]; then shift; dest=$1; fi
 shift
done
mkdir -p "$TEST_ROOT/payload"
printf 'new binary' > "$TEST_ROOT/payload/ddnsto_cli.arm64"
cp "$TEST_ROOT/payload/ddnsto_cli.arm64" "$TEST_ROOT/payload/ddnsto_cli.amd64"
tar -czf "$dest" -C "$TEST_ROOT/payload" ddnsto_cli.arm64 ddnsto_cli.amd64
''')
        self.tool('launchctl', '''
printf '%s\n' "$1" >> "$TEST_ROOT/service.log"
case "$1" in
print) [ -f "$TEST_ROOT/running" ] && echo 'pid = 123' ;;
bootout) rm -f "$TEST_ROOT/running" ;;
bootstrap)
 if [ "${FAIL_START:-0}" = 1 ] && [ ! -f "$TEST_ROOT/failed-once" ]; then
  touch "$TEST_ROOT/failed-once"; exit 9
 fi
 touch "$TEST_ROOT/running" ;;
kickstart) : ;;
esac
''')

    def tool(self, name, body):
        p = self.bin / name
        p.write_text('#!/bin/sh\nset -eu\n' + body)
        p.chmod(0o755)

    def run_script(self, args=('--token', 'test-token'), **env):
        return subprocess.run(['sh', str(SCRIPT), *args], env=self.env | env,
                              capture_output=True, text=True, timeout=20)

    def test_install_and_repeat_preserves_config_and_identity(self):
        first = self.run_script()
        self.assertEqual(first.returncode, 0, first.stderr)
        cfg = self.config / 'ddnsto.yaml'
        content = cfg.read_text() + 'routerName: custom-name\n'
        cfg.write_text(content)
        identity = self.config / '.ddnsto_boot.cfg'
        identity.write_text('identity-fixture')
        repeat = self.run_script(())
        self.assertEqual(repeat.returncode, 0, repeat.stderr)
        self.assertEqual(cfg.read_text(), content)
        self.assertEqual(identity.read_text(), 'identity-fixture')
        self.assertEqual(cfg.stat().st_mode & 0o777, 0o600)
        plist = plistlib.loads((self.agents / 'com.ddnsto.client.plist').read_bytes())
        self.assertEqual(plist['WorkingDirectory'], str(self.config))
        self.assertIn('cloud_status=unverified', repeat.stdout)

    def test_start_failure_restores_binary_config_and_service(self):
        first = self.run_script()
        self.assertEqual(first.returncode, 0, first.stderr)
        binary = self.install / 'ddnsto'
        binary.write_text('old binary')
        cfg = self.config / 'ddnsto.yaml'
        old = cfg.read_bytes()
        failed = self.run_script((), FAIL_START='1')
        self.assertNotEqual(failed.returncode, 0)
        self.assertEqual(binary.read_text(), 'old binary')
        self.assertEqual(cfg.read_bytes(), old)
        self.assertTrue((self.root / 'running').exists())

    def test_download_failure_does_not_mutate(self):
        result = self.run_script(FAIL_DOWNLOAD='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.install / 'ddnsto').exists())
        self.assertFalse((self.root / 'service.log').exists())

    def test_wrong_os_rejected_before_download(self):
        result = self.run_script(TEST_OS='Linux')
        self.assertEqual(result.returncode, 2)
        self.assertIn('macOS', result.stderr)
        self.assertFalse((self.root / 'payload').exists())

    def test_multiline_token_rejected(self):
        result = self.run_script(('--token', 'first\nsecond'))
        self.assertEqual(result.returncode, 2)
        self.assertFalse((self.root / 'payload').exists())

    def prepare_cold_bootstrap(self):
        (self.bin / 'zsetup').rename(self.root / 'native-fixture')
        self.env['ZSETUP_BIN'] = ''
        self.tool('curl', '''
while [ "$#" -gt 0 ]; do
 case "$1" in
  -o) shift; output=$1 ;;
  https://*) printf '%s\\n' "$1" >> "$TEST_ROOT/bootstrap.log" ;;
 esac
 shift
done
cp "$TEST_ROOT/native-fixture" "$output"
''')
        # The fixture cannot run Mach-O on Linux; isolate ONLY native-byte hash.
        self.tool('shasum', '''
case "${TEST_ARCH:-arm64}" in
 arm64) digest=06ec453f851bd0395cf9ea8539de168f80a9628d1a25597dd598c85f9dc633b0 ;;
 *) digest=608323145bcd8f083c0845b4bd0481eabccf0d74b99aa2aa6a88e59b34ce5b31 ;;
esac
printf '%s  %s\\n' "${BAD_DIGEST:-$digest}" "$3"
''')

    def test_cold_bootstrap_downloads_native_without_preinstall(self):
        self.prepare_cold_bootstrap()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('/0.3.0/zsetup-macos-aarch64', (self.root / 'bootstrap.log').read_text())
        self.assertTrue((self.install / 'ddnsto').exists())

    def test_bootstrap_hash_mismatch_never_executes_or_installs(self):
        self.prepare_cold_bootstrap()
        result = self.run_script(BAD_DIGEST='0' * 64)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('checksum', result.stderr.lower())
        self.assertFalse((self.root / 'payload').exists())
        self.assertFalse((self.install / 'ddnsto').exists())

    def test_unified_entry_bootstraps_intel_mac(self):
        self.prepare_cold_bootstrap()
        result = subprocess.run(['sh', str(SCRIPT.with_name('install.sh')), '--token', 'test-token'],
                                env=self.env | {'TEST_ARCH': 'x86_64'}, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('/0.3.0/zsetup-macos-x86_64', (self.root / 'bootstrap.log').read_text())
        self.assertTrue((self.install / 'ddnsto').exists())

    def test_first_install_prompts_without_echoing_token(self):
        pid, terminal = pty.fork()
        if pid == 0:
            os.execve('/bin/sh', ['sh', str(SCRIPT)], self.env)
        output = b''
        sent = False
        deadline = time.monotonic() + 10
        try:
            while time.monotonic() < deadline:
                ready, _, _ = select.select([terminal], [], [], 0.1)
                if not ready:
                    continue
                try:
                    part = os.read(terminal, 8192)
                except OSError:
                    break
                if not part:
                    break
                output += part
                if b'DDNSTO token:' in output and not sent:
                    os.write(terminal, b'hidden-fixture-token\n')
                    sent = True
            else:
                os.kill(pid, 15)
                self.fail('interactive installer timed out')
        finally:
            os.close(terminal)
            _, status = os.waitpid(pid, 0)
        self.assertEqual(os.waitstatus_to_exitcode(status), 0, output.decode())
        self.assertTrue(sent)
        self.assertNotIn(b'hidden-fixture-token', output)
        self.assertIn('hidden-fixture-token', (self.config / 'ddnsto.yaml').read_text())

    def test_first_start_failure_removes_only_owned_files(self):
        self.config.mkdir()
        identity = self.config / '.ddnsto_boot.cfg'
        identity.write_text('preexisting identity')
        result = self.run_script(FAIL_START='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.install / 'ddnsto').exists())
        self.assertFalse((self.config / 'ddnsto.yaml').exists())
        self.assertFalse((self.agents / 'com.ddnsto.client.plist').exists())
        self.assertEqual(identity.read_text(), 'preexisting identity')

    def test_unmanaged_job_is_not_stopped(self):
        (self.root / 'running').touch()
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.root / 'running').exists())
        self.assertNotIn('bootout', (self.root / 'service.log').read_text())

    def test_lock_is_not_removed_by_competing_installer(self):
        lock = self.config / '.install-lock'
        lock.mkdir(parents=True)
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(lock.is_dir())
        self.assertFalse((self.install / 'ddnsto').exists())


if __name__ == '__main__':
    unittest.main()
