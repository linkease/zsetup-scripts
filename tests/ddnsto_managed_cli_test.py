"""Maintained-source CLI tests; never bootstrap or alter a host service."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def shell(body, *args):
    sources = ['lib/install-storage.sh', 'lib/install-bounds.sh',
               'lib/install-transaction.sh', 'lib/install-service.sh',
               'ddnsto/product-pins.sh', 'ddnsto/docker-probe.sh',
               'ddnsto/business.sh']
    sources += [str(p.relative_to(ROOT)) for p in sorted((ROOT / 'ddnsto').glob('managed-*.sh'))]
    script = 'set -eu\n' + ''.join('. "' + str(ROOT / p) + '"\n' for p in sources)
    return subprocess.run(['sh', '-c', script + body, 'test', *args],
                          text=True, capture_output=True, timeout=10)


class ManagedCLI(unittest.TestCase):
    def test_repeated_install_cannot_replace_token_or_service(self):
        result = shell('''ACTION=install; TOKEN=do-not-log; SERVICE_HAD_UNIT=1
installer_service_manager() { echo MUTATION; return 99; }
installer_exec_native() { echo MUTATION; return 99; }
ddnsto_register
''')
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertNotIn('MUTATION', result.stdout)
        self.assertNotIn('do-not-log', result.stderr)
        self.assertIn('configure', result.stderr)

    def test_update_rejects_token_without_echo(self):
        result = shell('ddnsto_parse_args "$@"', '--action', 'update', '--token', 'secret-value')
        self.assertEqual(result.returncode, 2)
        self.assertIn('preserves', result.stderr)
        self.assertNotIn('secret-value', result.stderr)

    def test_update_without_token(self):
        result = shell('ddnsto_parse_args "$@"; printf "%s:%s" "$ACTION" "$TOKEN"', '--action', 'update')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'update:')

    def test_plan_without_runtime(self):
        result = shell('ddnsto_parse_args --plan; ddnsto_plan')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('client_version=4.2.8', result.stdout)
        self.assertIn('installation_performed=false', result.stdout)

    def test_platform_constraint(self):
        result = shell('ddnsto_parse_args --platform synology; os=linux; package_manager=unknown; ddnsto_detect_platform')
        self.assertEqual(result.returncode, 2)
        self.assertIn('platform mismatch', result.stderr)

    def test_token_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            token = Path(tmp) / 'token'
            token.write_text('a token\n')
            result = shell('ddnsto_parse_args "$@"; printf "%s" "$TOKEN"', '--token-file', str(token))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, 'a token')

    def test_bridge_update_arguments(self):
        result = shell('ACTION=update; TOKEN=; ddnsto_privilege_args; printf "action=%s token=%s" "$DDNSTO_ROOT_ACTION" "$DDNSTO_ROOT_TOKEN"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'action=update token=')

    def test_update_registration_never_sets_token(self):
        result = shell('''ACTION=update; TOKEN=; SERVICE_HAD_UNIT=1; SERVICE_CONFIG_TOUCHED=1
SERVICE_EXEC=/protected/versions/4.2.8/bin/ddnsto
installer_service_manager() { :; }
ddnsto_managed_rewrite_unit() { printf 'rewrite'; }
installer_exec_native() { printf 'UNEXPECTED product execution'; return 99; }
ddnsto_register
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'rewrite')

    def test_help_precedes_native_bootstrap(self):
        result = shell('bootstrap_and_run() { return 99; }; . "' + str(ROOT / 'ddnsto/main.sh') + '"', '--help')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('--action', result.stdout)

    def test_shared_options_reach_readonly_plan(self):
        result = shell('. "' + str(ROOT / 'lib/install-launcher.sh') + '"\n'
                       'bootstrap_and_run() { return 99; }; . "' + str(ROOT / 'ddnsto/main.sh') + '"',
                       '--installer-prefix', '/opt/example-ddnsto', '--plan')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('installation_performed=false', result.stdout)

    def test_offline_missing_native_is_explicit(self):
        result = shell('ZSETUP_BIN=/missing/native; ddnsto_managed_native')
        self.assertEqual(result.returncode, 2)
        self.assertIn('offline', result.stderr)

    def test_health_failure_prevents_commit(self):
        with tempfile.TemporaryDirectory() as tmp:
            prefix = Path(tmp)
            (prefix / 'versions/new/bin').mkdir(parents=True)
            result = shell('''INSTALLER_PREFIX=$1; INSTALLER_RESERVE=0; ZSETUP_BIN=/bin/echo
SERVICE_VERSION_DIR=$1/versions/new; SERVICE_VERSION=new; SERVICE_EXEC=$SERVICE_VERSION_DIR/bin/ddnsto
SERVICE_APP=ddnsto; SERVICE_COMMAND=$1/alias; SERVICE_HAD_UNIT=0; SERVICE_OLD=; SERVICE_GOOD=0; SERVICE_NEW_VERSION=1
installer_storage_check() { :; }
# Return the native protection fact without launching a product/service.
native() { echo true; }; ZSETUP_BIN=native
installer_service_manager() { :; }; ddnsto_register() { :; }
installer_service_definition() { :; }; installer_service_quote_unit() { :; }
installer_service_alias() { echo ALIAS; }
ddnsto_service_health() { echo HEALTH; return 13; }
sleep() { :; }; status() { :; }
rc=0; installer_service_activate || rc=$?
printf 'rc=%s good=%s changed=%s new=%s' "$rc" "$SERVICE_GOOD" "$SERVICE_CHANGED" "$SERVICE_NEW_VERSION"
''', str(prefix))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('rc=13 good=0 changed=1 new=1', result.stdout)
            self.assertNotIn('ALIAS', result.stdout)

    def test_status_does_not_create_missing_prefix(self):
        with tempfile.TemporaryDirectory() as tmp:
            prefix = Path(tmp) / 'absent'
            result = shell('''installer_prefix=$1; detected_platform=linux; ACTION=status
native() { case "$*" in *system_protected) echo true;; *) return 99;; esac; }
ZSETUP_BIN=native; ddnsto_managed_action
''', str(prefix))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('not-installed', result.stdout)
            self.assertFalse(prefix.exists())

    def test_write_action_rejects_unowned_prefix_before_prepare(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = shell('''installer_prefix=$1; detected_platform=linux; ACTION=stop
native() { echo true; }; ZSETUP_BIN=native
installer_service_prepare() { echo MUTATION; return 99; }
ddnsto_managed_action
''', tmp)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertNotIn('MUTATION', result.stdout)

    def test_update_metadata_never_prompts_and_defaults_to_pin(self):
        result = shell('''ACTION=update; TOKEN=; FORCE_VERSION=; VERIFY_STATUS=0; arch=x86_64
transaction_dir=/nonexistent; status() { :; }
ddnsto_download() { echo NETWORK; return 99; }
ddnsto_linux_metadata
printf '%s:%s' "$version_num" "$digest"
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.startswith('4.2.8:3bf7ada1'), result.stdout)

    def test_registration_update_real_unit_preserves_other_lines_and_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            unit = root / 'unit'
            unit.write_text('[Unit]\nConditionFileIsExecutable=/old/ddnsto\n[Service]\nExecStart=/old/ddnsto "run"\nRestart=always\n')
            config = root / 'config'
            config.write_text('retained identity\n')
            result = shell('''ACTION=update; TOKEN=; SERVICE_HAD_UNIT=1; SERVICE_CONFIG_TOUCHED=1
SERVICE_BACKEND=systemd; SERVICE_UNIT=$1/unit; SERVICE_EXEC=/opt/protected/versions/new/bin/ddnsto
transaction_dir=$1; INSTALLER_RESERVE=0; ZSETUP_BIN=native
installer_exec_native() { shift; "$@"; }
capture() { shift; output=$1; shift; while [ "$1" != -- ]; do shift; done; shift; "$@" > "$output"; }
ddnsto_register
printf 'touched=%s' "$SERVICE_CONFIG_TOUCHED"
''', tmp)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, 'touched=0')
            self.assertIn('Restart=always', unit.read_text())
            self.assertIn('/opt/protected/versions/new/bin/.service-run', unit.read_text())
            self.assertEqual(config.read_text(), 'retained identity\n')

    def test_update_refuses_fresh_prefix_before_storage_prepare(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = shell('''ZSETUP_BIN=native; ZSETUP_SOURCE_BASES=https://example.invalid
ZSETUP_OS=linux; ZSETUP_PACKAGE_MANAGER=unknown; ZSETUP_ARCH=x86_64
installer_prefix=$1; native() { echo true; }
installer_service_prepare() { echo MUTATION; return 99; }
ddnsto_install --action update
''', str(Path(tmp) / 'missing'))
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertNotIn('MUTATION', result.stdout)

    def test_linux_health_rejects_missing_address(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = shell('''version_num=4.2.8; SERVICE_CONFIG=$1/config; SERVICE_EXEC=$1/ddnsto
ZSETUP_BIN=/bin/false; transaction_dir=$1; INSTALLER_RESERVE=0
ddnsto_managed_health_probe
''', tmp)
            self.assertEqual(result.returncode, 13, result.stderr)

    def test_installer_mode_uses_native_platform_facts(self):
        result = shell('. "' + str(ROOT / 'lib/install-launcher.sh') + '"\n'
                       'ZSETUP_INSTALLER_MODE=1; ZSETUP_OS=openwrt; ZSETUP_PACKAGE_MANAGER=opkg; ZSETUP_ARCH=mipsel\n'
                       'ddnsto_install() { printf "platform=%s" "$detected_platform"; }; . "' + str(ROOT / 'ddnsto/main.sh') + '"',
                       '--platform', 'openwrt', '--force-version', 'lite')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'platform=openwrt')

    def test_docker_write_uses_separate_locked_adapter(self):
        result = shell('. "' + str(ROOT / 'lib/install-launcher.sh') + '"\n'
                       'ddnsto_docker_locked() { printf DOCKER; };\n'
                       '. "' + str(ROOT / 'ddnsto/main.sh') + '"', '--method', 'docker')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'DOCKER')

    def test_synology_download_dispatches_without_linux_mutation(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / 'absent'
            result = shell('. "' + str(ROOT / 'lib/install-launcher.sh') + '"\n'
                           'ddnsto_local_platform() { detected_platform=synology; };\n'
                           'ddnsto_synology_entry() { printf SYNOLOGY; };\n'
                           '. "' + str(ROOT / 'ddnsto/main.sh') + '"', '--action', 'download', '--output-dir', str(output))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, 'SYNOLOGY')
            self.assertFalse(output.exists())

    def test_token_file_is_bounded(self):
        with tempfile.TemporaryDirectory() as tmp:
            token = Path(tmp) / 'token'
            token.write_text('x' * 16385)
            result = shell('ddnsto_parse_args "$@"', '--token-file', str(token))
            self.assertEqual(result.returncode, 2, result.stderr)

    def test_openwrt_local_actions_fail_closed(self):
        for action in ('status', 'start', 'stop', 'restart', 'repair', 'configure', 'uninstall'):
            with self.subTest(action=action):
                result = shell('detected_platform=openwrt; ACTION=$1; ddnsto_managed_action', action)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn('OpenWrt local lifecycle is not yet ported', result.stderr)

    @unittest.skipUnless(os.environ.get('DDNSTO_TEST_NATIVE'), 'set DDNSTO_TEST_NATIVE to published zsetup')
    def test_published_native_offline_status_without_sources_or_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            prefix = Path(tmp) / 'absent'
            result = shell('''ZSETUP_BIN=$1; installer_prefix=$2; detected_platform=linux; ACTION=status
unset ZSETUP_SOURCE_BASES ZSETUP_SOURCE_FALLBACK
ddnsto_managed_native; ddnsto_managed_action
''', os.environ['DDNSTO_TEST_NATIVE'], str(prefix))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('not-installed', result.stdout)
            self.assertFalse(prefix.exists())


if __name__ == '__main__':
    unittest.main()
