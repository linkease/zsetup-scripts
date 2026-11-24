"""Missing Linux environment records default to production; explicit conflicts do not."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[4] / 'sources/ddnsto'


class BusinessEnvironment(unittest.TestCase):
    def shell(self, body):
        return subprocess.run(['sh', '-c', '. "$1"; ddnsto_error() { echo "$*" >&2; }; ' + body,
                               'test', str(ROOT / 'managed-cli.sh')], text=True, capture_output=True)

    def test_parse_environment(self):
        result = self.shell('ddnsto_parse_args --env test --switch-environment || exit $?; echo "$BUSINESS_ENV:$SWITCH_ENVIRONMENT"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'test:1')

    def test_invalid_environment(self):
        self.assertNotEqual(self.shell('ddnsto_parse_args --env arbitrary').returncode, 0)

    def test_native_appliance_does_not_silently_use_production(self):
        for platform in ('openwrt', 'asus', 'synology', 'qnap', 'unraid'):
            with self.subTest(platform=platform):
                result = self.shell(f'BUSINESS_ENV=test; REQUESTED_METHOD=native; detected_platform={platform}; ddnsto_business_environment_preflight')
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn('E_ENV_UNSUPPORTED', result.stderr)

    def test_assignment_is_existing_test_profile(self):
        result = self.shell('ddnsto_business_assignment test')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('wss://web.toany.net:9445/ws/control', result.stdout)

    def test_switch_protection(self):
        for current, requested, confirmation, expected in [
            ('test', 'production', 0, 2), ('production', 'test', 0, 2),
            ('unknown', 'test', 1, 2), ('test', 'test', 0, 0),
            ('production', 'test', 1, 0),
        ]:
            result = self.shell(f'BUSINESS_ENV={requested}; SWITCH_ENVIRONMENT={confirmation}; ddnsto_business_match {current}')
            self.assertEqual(result.returncode, expected, result.stderr)

    def test_linux_registration_does_not_start_before_environment(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / 'config'
            config.touch()
            result = self.shell('. "'+str(ROOT / 'templates/business.sh.in')+'"; '
                f'SERVICE_CONFIG="{config}"; '
                'ACTION=install; BUSINESS_ENV=test; SERVICE_HAD_UNIT=0; SERVICE_EXEC=/fake/ddnsto; TOKEN=fixture; '
                'command() { if [ "$*" = "-v jq" ]; then return 0; fi; command "$@"; }; '
                'ddnsto_linux_register_environment() { echo configure-environment; }; '
                'installer_exec_native() { printf "%s\\n" "$*"; }; '
                'ddnsto_register')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('-daemon', result.stdout)
        self.assertIn('DDNSTO_TEST_SERVER_ASSIGNMENT_JSON={', result.stdout)
        self.assertIn('tunnel.toany.net:4445', result.stdout)
        self.assertIn('configure-environment', result.stdout)

    def test_linux_production_registration_without_jq_overrides_inherited_test(self):
        for selection in ('unset BUSINESS_ENV', 'BUSINESS_ENV=production'):
            with self.subTest(selection=selection), tempfile.TemporaryDirectory() as directory:
                config = Path(directory) / 'config'
                result = self.shell(f'. "{ROOT / "templates/business.sh.in"}"; '
                    f'{selection}; SERVICE_CONFIG="{config}"; '
                    'ACTION=install; SERVICE_HAD_UNIT=0; SERVICE_EXEC=/fake/ddnsto; TOKEN=fixture; '
                    'DDNSTO_TEST_SERVER_ASSIGNMENT_JSON=inherited-test; export DDNSTO_TEST_SERVER_ASSIGNMENT_JSON; '
                    'command() { if [ "$*" = "-v jq" ]; then return 1; fi; command "$@"; }; '
                    'installer_exec_native() { printf "%s\\n" "$*"; }; '
                    'ddnsto_linux_register_environment() { echo configure-environment; }; ddnsto_register')
                self.assertEqual(result.returncode, 0, result.stderr)
                assignment = self.shell('ddnsto_business_assignment production').stdout.strip()
                self.assertIn('env DDNSTO_TEST_SERVER_ASSIGNMENT_JSON=' + assignment, result.stdout)
                self.assertIn('/fake/ddnsto -u fixture -daemon', result.stdout)
                self.assertNotIn('inherited-test', result.stdout)
                self.assertNotIn(' jq ', result.stdout)
                self.assertIn('configure-environment', result.stdout)
                self.assertFalse(config.exists())

    def test_linux_metadata_only_test_install_requires_jq(self):
        for environment in ('production', 'test'):
            for action in ('install', 'update'):
                with self.subTest(environment=environment, action=action):
                    result = self.shell(f'. "{ROOT / "templates/business.sh.in"}"; '
                        f'BUSINESS_ENV={environment}; ACTION={action}; '
                        'arch=x86_64; FORCE_VERSION=standard; VERIFY_STATUS=0; TOKEN=fixture; '
                        'DDNSTO_VERSION=4.2.8; transaction_dir=/unused-fixture; '
                        'command() { if [ "$*" = "-v jq" ]; then return 1; fi; command "$@"; }; '
                        'status() { :; }; ddnsto_download() { :; }; ddnsto_checksum() { echo fixture; }; '
                        'ddnsto_linux_metadata')
                    expected = 2 if environment == 'test' and action == 'install' else 0
                    self.assertEqual(result.returncode, expected, result.stderr)
                    if expected:
                        self.assertIn('jq', result.stderr)

    def test_linux_test_registration_without_jq_stops_before_execution(self):
        result = self.shell(f'. "{ROOT / "templates/business.sh.in"}"; '
            'BUSINESS_ENV=test; ACTION=install; SERVICE_HAD_UNIT=0; '
            'command() { if [ "$*" = "-v jq" ]; then return 1; fi; command "$@"; }; '
            'installer_exec_native() { echo unexpected-execution; }; ddnsto_register')
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn('jq', result.stderr)
        self.assertEqual(result.stdout, '')

    def test_linux_update_registration_without_jq_preserves_config(self):
        for environment in ('production', 'test'):
            with self.subTest(environment=environment), tempfile.TemporaryDirectory() as directory:
                config = Path(directory) / 'config'
                original = b'{"token":"fixture","routeridx":3}'
                config.write_bytes(original)
                result = self.shell(f'. "{ROOT / "templates/business.sh.in"}"; '
                    f'BUSINESS_ENV={environment}; ACTION=update; SERVICE_CONFIG="{config}"; '
                    'command() { if [ "$*" = "-v jq" ]; then return 1; fi; command "$@"; }; '
                    'installer_exec_native() { echo unexpected-execution; return 99; }; '
                    'ddnsto_managed_rewrite_unit() { echo rewrite-unit; }; '
                    'ddnsto_linux_register_environment() { echo configure-environment; }; '
                    'ddnsto_register')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(), ['rewrite-unit', 'configure-environment'])
                self.assertEqual(config.read_bytes(), original)

    def test_linux_unit_environment_switch_and_identity_preservation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            unit = root / 'service'
            config = root / 'config'
            identity = root / '.ddnsto_boot.cfg'
            config.write_bytes(b'{"token":"fixture","routeridx":3}')
            identity.write_bytes(b'encrypted-identity-unchanged')
            unit.write_text('[Service]\nExecStart=/example\n')
            setup = f'. "{ROOT / "managed-service.sh"}"; SERVICE_UNIT="{unit}"; SERVICE_CONFIG="{config}"; transaction_dir="{root}"; '
            legacy = self.shell(setup + 'BUSINESS_ENV=production; ddnsto_linux_environment')
            self.assertEqual(legacy.returncode, 0, legacy.stderr)
            assignment = self.shell('ddnsto_business_assignment production').stdout.strip()
            unit.write_text(f"[Service]\nEnvironment='DDNSTO_TEST_SERVER_ASSIGNMENT_JSON={assignment}'\nExecStart=/example\n")
            rejected = self.shell(setup + 'BUSINESS_ENV=test; ddnsto_linux_environment')
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn('E_ENV_SWITCH', rejected.stderr)
            applied = self.shell(setup + 'BUSINESS_ENV=test; SWITCH_ENVIRONMENT=1; ddnsto_linux_environment || exit $?; '
                'installer_exec_native() { cp "$transaction_dir/business-unit" "$SERVICE_UNIT"; }; '
                'ddnsto_linux_register_environment')
            self.assertEqual(applied.returncode, 0, applied.stderr)
            self.assertIn('tunnel.toany.net:4445', unit.read_text())
            self.assertEqual(identity.read_bytes(), b'encrypted-identity-unchanged')
            self.assertEqual(config.read_bytes(), b'{"token":"fixture","routeridx":3}')
            repeated = self.shell(setup + 'BUSINESS_ENV=test; ddnsto_linux_environment')
            self.assertEqual(repeated.returncode, 0, repeated.stderr)

    def test_linux_capability_check_is_read_only(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / 'ddnsto'
            binary.write_bytes(b'#!/bin/sh\nexit 99\n')
            binary.chmod(0o700)
            body = f'. "{ROOT / "managed-service.sh"}"; BUSINESS_ENV=test; ddnsto_linux_environment_capability "{binary}"'
            missing = self.shell(body)
            self.assertEqual(missing.returncode, 2)
            self.assertIn('E_ENV_CAPABILITY', missing.stderr)
            binary.write_bytes(b'#!/bin/sh\nexit 99\n# DDNSTO_TEST_SERVER_ASSIGNMENT_JSON\n')
            present = self.shell(body)
            self.assertEqual(present.returncode, 0, present.stderr)

    def test_missing_or_legacy_linux_unit_defaults_to_production(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / 'config'
            config.write_text('{"token":"fixture","routeridx":3}')
            legacy = root / 'legacy-unit'
            legacy.write_text('[Service]\nExecStart=/example\n')
            binary_dir = root / 'bin'
            binary_dir.mkdir()
            for boot_dir in (None, root, binary_dir):
                identity = boot_dir / '.ddnsto_boot.cfg' if boot_dir else None
                if identity:
                    identity.write_bytes(b'encrypted-identity-unchanged')
                for unit in (root / 'missing-unit', legacy):
                    for args, expected in (
                        ('', 0), ('--env production', 0),
                        ('--env test', 2), ('--env test --switch-environment', 0),
                    ):
                        with self.subTest(unit=unit.name, boot=boot_dir, args=args):
                            result = self.shell(f'. "{ROOT / "managed-service.sh"}"; '
                                f'ddnsto_parse_args {args} || exit $?; '
                                f'SERVICE_CONFIG="{config}"; SERVICE_UNIT="{unit}"; '
                                f'SERVICE_EXEC="{binary_dir / "ddnsto"}"; ACTION=repair; '
                                'ddnsto_linux_environment; rc=$?; '
                                'echo "$BUSINESS_CURRENT_ENV"; exit "$rc"')
                            self.assertEqual(result.returncode, expected, result.stderr)
                            self.assertEqual(result.stdout.strip(), 'production')
                            if expected:
                                self.assertIn('E_ENV_SWITCH', result.stderr)
                if identity:
                    self.assertEqual(identity.read_bytes(), b'encrypted-identity-unchanged')
                    identity.unlink()
            self.assertEqual(config.read_text(), '{"token":"fixture","routeridx":3}')
            self.assertFalse((root / 'missing-unit').exists())
            self.assertEqual(legacy.read_text(), '[Service]\nExecStart=/example\n')

    def test_explicit_linux_test_record_requires_switch_to_default_production(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            unit = root / 'unit'
            assignment = self.shell('ddnsto_business_assignment test').stdout.strip()
            original = f"[Service]\nEnvironment='DDNSTO_TEST_SERVER_ASSIGNMENT_JSON={assignment}'\n"
            unit.write_text(original)
            for args, expected in (
                ('', 2), ('--env production', 2),
                ('--switch-environment', 0), ('--env production --switch-environment', 0),
                ('--env test', 0),
            ):
                with self.subTest(args=args):
                    result = self.shell(f'. "{ROOT / "managed-service.sh"}"; '
                        f'ddnsto_parse_args {args} || exit $?; '
                        f'SERVICE_UNIT="{unit}"; SERVICE_CONFIG="{root / "config"}"; '
                        'ddnsto_linux_environment')
                    self.assertEqual(result.returncode, expected, result.stderr)
                    if expected:
                        self.assertIn('E_ENV_SWITCH', result.stderr)
            self.assertEqual(unit.read_text(), original)

    def test_linux_custom_configuration_is_refused_even_with_switch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / 'config'
            unit = root / 'unit'
            for field in ('remoteAddr', 'serverAddr', 'serverAssignment', 'serverDomain', 'bootConfigPath'):
                original = '{"' + field + '":"custom.example"}'
                config.write_text(original)
                for legacy in (False, True):
                    if legacy:
                        unit.write_text('[Service]\nExecStart=/example\n')
                    elif unit.exists():
                        unit.unlink()
                    with self.subTest(field=field, legacy=legacy):
                        result = self.shell(f'. "{ROOT / "managed-service.sh"}"; '
                            f'SERVICE_UNIT="{unit}"; SERVICE_CONFIG="{config}"; '
                            'ddnsto_parse_args --switch-environment; ddnsto_linux_environment')
                        self.assertEqual(result.returncode, 2, result.stderr)
                        self.assertIn('E_ENV_UNKNOWN', result.stderr)
                        self.assertEqual(config.read_text(), original)

    def test_candidate_capability_precedes_version_commit_and_execution(self):
        for cached in (0, 1):
            for supported in (False, True):
                with self.subTest(cached=cached, supported=supported), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    candidate = root / 'candidate'
                    candidate.write_text('#!/bin/sh\nexit 99\n' +
                        ('# DDNSTO_TEST_SERVER_ASSIGNMENT_JSON\n' if supported else ''))
                    result = self.shell(f'. "{ROOT / "managed-service.sh"}"; . "{ROOT / "templates/business.sh.in"}"; '
                        f'transaction_dir="{root}"; SERVICE_EXEC="{candidate}"; BUSINESS_ENV=test; '
                        f'installer_service_cached() {{ SERVICE_CACHED={cached}; }}; '
                        'ddnsto_linux_metadata() { version_num=4.2.8; digest=fixture; arch=amd64; }; '
                        'status() { :; }; ddnsto_download() { :; }; '
                        f'installer_extract_member() {{ cp "{candidate}" "$1"; }}; '
                        'installer_exec_native() { echo execute; }; '
                        'installer_service_stage() { echo stage; }; '
                        'installer_service_copy() { echo copy; }; '
                        'installer_service_commit_version() { echo commit; }; '
                        'installer_service_activate() { echo activate; }; '
                        'ddnsto_linux')
                    self.assertEqual(result.returncode, 0 if supported else 2, result.stderr)
                    if supported:
                        self.assertIn('activate', result.stdout)
                        if not cached:
                            self.assertIn('commit', result.stdout)
                    else:
                        self.assertIn('E_ENV_CAPABILITY', result.stderr)
                        self.assertEqual(result.stdout, '')

    def test_custom_appliance_service_is_refused_even_for_production(self):
        with tempfile.TemporaryDirectory() as directory:
            service = Path(directory) / 'service'
            service.write_text('exec ddnstod -u "$token" -r custom.example:4445\n')
            result = self.shell(f'ddnsto_business_service_file "{service}"')
            self.assertEqual(result.returncode, 2)
            self.assertIn('E_ENV_UNKNOWN', result.stderr)

    def test_failed_service_scan_does_not_mean_production(self):
        with tempfile.TemporaryDirectory() as directory:
            service = Path(directory) / 'service'
            service.write_text('exec ddnstod\n')
            result = self.shell(f'grep() {{ return 2; }}; ddnsto_business_service_file "{service}"')
            self.assertEqual(result.returncode, 2)
