"""Default workflow contracts, with no host service or package mutation."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def run(body, *args, env=None):
    sources = ['ddnsto/business.sh', 'ddnsto/managed-cli.sh', 'ddnsto/product-pins.sh']
    source = ROOT / 'ddnsto/auto-install.sh'
    script = 'set -eu\n' + ''.join(f'. "{ROOT / p}"\n' for p in sources)
    if source.exists():
        script += f'. "{source}"\n'
    return subprocess.run(['sh', '-c', script + body, 'test', *args],
                          env=os.environ | (env or {}), text=True, capture_output=True, timeout=10)


class AutoInstall(unittest.TestCase):
    def test_default_is_ensure_explicit_actions_remain_available(self):
        result = run('ddnsto_parse_args --token account; printf "%s" "$ACTION"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'ensure')
        result = run('ddnsto_parse_args --action install --token account; printf "%s" "$ACTION"')
        self.assertEqual(result.stdout, 'install')

    def test_legacy_alias_does_not_request_cloud_checks(self):
        source = (ROOT / 'ddnsto/main.sh').read_text()
        result = subprocess.run(['sh', '-c', source.replace('main "$@"', '') +
            '\ninstaller_dispatch() { printf "%s\\n" "$@"; }; main account',
            'setup_ddnsto.sh'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('--token\naccount', result.stdout)
        self.assertNotIn('--verify-status', result.stdout)

    def test_authorization_checks_controlling_terminal_not_background_stdin(self):
        source = (ROOT / 'ddnsto/auto-linux.sh').read_text()
        self.assertNotIn('[ -t 0 ]', source)
        result = subprocess.run(['sh', '-c', source + '\nddnsto_ensure_tty_available'],
            capture_output=True, text=True, start_new_session=True)
        self.assertNotEqual(result.returncode, 0)

    def test_numeric_versions_never_downgrade(self):
        for installed, wanted, order in [('4.2.8', '4.2.8', '0'), ('4.2.9', '4.2.8', '1'),
                                          ('4.2.10', '4.2.9', '1'), ('4.1.8', '4.2.8', '-1')]:
            with self.subTest(installed=installed):
                result = run('ddnsto_version_order "$1" "$2"', installed, wanted)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), order)
        for version in ['4.2.8-beta', '4.2', '999999999999999999999.2.3', '04.2.8', '$(touch bad)']:
            result = run('ddnsto_version_order "$1" 4.2.8', version)
            self.assertEqual(result.returncode, 2, result.stderr)

    def test_repeated_install_same_or_newer_only_starts(self):
        for current, expected in [('', 'install'), ('4.2.7', 'update'), ('4.2.8', 'start'), ('4.2.10', 'start')]:
            result = run('ddnsto_ensure_decision "$1" 4.2.8; printf "%s" "$ENSURE_ACTION"', current)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, expected)

    def test_no_token_prompt_or_unsupported_platform_download(self):
        for platform, token, error in [('linux', '', 'TOKEN'), ('qnap', 'secret', 'PLATFORM'),
                                       ('qnap', 'secret', 'PLATFORM'), ('unraid', 'secret', 'PLATFORM')]:
            result = run('''TOKEN=$2; detected_platform=$1; REQUESTED_METHOD=auto; FORCE_VERSION=; VERIFY_STATUS=0
ddnsto_ensure_preflight
''', platform, token)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn('E_' + error, result.stderr)
            self.assertNotIn('secret', result.stderr)

    def test_direct_native_business_dispatch_also_requires_token(self):
        result = run('''ZSETUP_BIN=/bin/true; ZSETUP_OS=linux; ZSETUP_PACKAGE_MANAGER=unknown
ZSETUP_ARCH=x86_64; ZSETUP_SOURCE_BASES=https://example.invalid
ddnsto_install
''')
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn('E_TOKEN', result.stderr)

    def test_flow_output_is_local_only_and_failure_is_nonzero(self):
        with tempfile.TemporaryDirectory() as tmp:
            body = '''
TOKEN=not-for-log; detected_platform=linux; REQUESTED_METHOD=auto; FORCE_VERSION=; VERIFY_STATUS=0
ddnsto_ensure_preflight() { :; }
ddnsto_ensure_execute() { ddnsto_flow_note installed; return "$1"; }
ddnsto_ensure_entry "$1"
'''
            result = run(body, '13', env={'TMPDIR': tmp})
            self.assertEqual(result.returncode, 13, result.stderr)
            self.assertIn('安装成功', result.stderr)
            self.assertIn('启动失败', result.stderr)
            self.assertNotIn('not-for-log', result.stdout + result.stderr)
            self.assertNotIn('设备已上线', result.stdout + result.stderr)
            logs = list(Path(tmp).glob('ddnsto-result.*/events.log'))
            self.assertEqual(len(logs), 1)
            self.assertNotIn('not-for-log', logs[0].read_text())

    def test_zero_exit_without_local_verification_is_not_success(self):
        result = run('''TOKEN=secret; ddnsto_ensure_preflight() { :; }
ddnsto_ensure_execute() { ddnsto_flow_note installed; }
ddnsto_ensure_entry
''')
        self.assertEqual(result.returncode, 13, result.stderr)
        self.assertNotIn('安装成功，启动成功', result.stdout + result.stderr)

    def test_linux_account_is_data_only_and_must_match(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / 'config.json'
            secret = 'account-secret'
            script = '''
. "$1"
SERVICE_CONFIG=$2; ENSURE_TOKEN=$3
ZSETUP_BIN=/bin/true
ddnsto_ensure_protected_config() { [ -f "$SERVICE_CONFIG" ]; }
ddnsto_ensure_linux_account
'''
            for data, expected in [(' {"token":"account-secret","id":7}', 0),
                                    ('{"token":"other"}', 2), ('{}', 2),
                                    ('{"token":"account-secret"}\n{}', 2), ('not json', 2)]:
                config.write_text(data)
                result = run(script, str(ROOT / 'ddnsto/auto-linux.sh'), str(config), secret)
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertEqual(config.read_text(), data)
                self.assertNotIn(secret, result.stdout + result.stderr)

    def test_linux_stability_rejects_restarting_pid(self):
        body = '''
. "$1"
DDNSTO_FLOW_DIR=$2
ddnsto_managed_property() {
    case "$1" in ActiveState) echo active ;; MainPID) cat "$DDNSTO_FLOW_DIR/pid" ;; esac
}
sleep() { printf 20 > "$DDNSTO_FLOW_DIR/pid"; }
ddnsto_ensure_linux_running
'''
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / 'pid').write_text('10')
            result = run(body, str(ROOT / 'ddnsto/auto-linux.sh'), tmp)
            self.assertEqual(result.returncode, 13, result.stderr)


if __name__ == '__main__':
    unittest.main()
