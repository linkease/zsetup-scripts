import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SynologyAuto(unittest.TestCase):
    def test_help_describes_synology_automatic_support(self):
        result = subprocess.run(['sh', str(ROOT / 'ddnsto/ddnsto-install.sh'), '--help'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn('DS220j', result.stdout)
        self.assertNotIn('暂不支持 NAS/Docker', result.stdout)

    def test_fresh_volume_selection_does_not_require_jq_regex_library(self):
        source = (ROOT / 'ddnsto/auto-synology-fresh.sh').read_text()
        self.assertNotIn('test("', source)

    def test_fresh_preflight_requires_unoccupied_listed_numeric_volume(self):
        source = (ROOT / 'ddnsto/auto-synology-fresh.sh').read_text().replace('/usr/syno/bin/synowebapi', '/bin/true')
        script = f'. "{ROOT}/ddnsto/auto-install.sh"\n' + source + '''
ddnsto_synowebapi() { printf '%s' "$RESPONSE"; }
ddnsto_bootstrap_safe_ancestors() { :; }
ddnsto_synology_fresh_check() { :; }
ddnsto_synology_fresh_preflight || exit $?
printf '%s' "$syno_volume"
'''
        for volume, occupied, listed, success, expected in [
            ('/volume1', False, True, True, 0),
            ('/volume2', False, True, True, 0),
            ('/volume1', True, True, True, 2),
            ('/volume1', False, False, True, 2),
            ('/volume1', False, True, False, 2),
            ('/volume1/../etc', False, True, True, 2),
            ('/volume', False, True, True, 2),
        ]:
            response = {'success': success, 'data': {'volume_path': volume, 'is_occupied': occupied, 'volume_list': [{'mount_point': volume}] if listed else []}}
            result = subprocess.run(['sh', '-c', script], env=os.environ | {'RESPONSE': json.dumps(response)}, capture_output=True, text=True)
            self.assertEqual(result.returncode, expected, result.stderr)
            if expected == 0:
                self.assertEqual(result.stdout, volume)

    def test_sudo_authorization_failure_is_explicit_and_never_executes(self):
        main = (ROOT / 'ddnsto/main.sh').read_text().rsplit('\nmain "$@"', 1)[0]
        script = f'. "{ROOT}/ddnsto/auto-install.sh"\n' + main + '''
ddnsto_parse_args() { ACTION=ensure; PLAN_ONLY=0; }
ddnsto_local_platform() { detected_platform=synology; }
ddnsto_validate_platform_options() { :; }
id() { echo 1000; }
sudo() { [ "$1" != -v ] || return 1; echo UNEXPECTED_EXECUTION; }
ddnsto_entry_install --token fixture
'''
        result = subprocess.run(['sh', '-c', script, str(ROOT / 'ddnsto/main.sh')], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('E_PRIVILEGE', result.stderr)
        self.assertNotIn('UNEXPECTED_EXECUTION', result.stdout)

    def test_default_synology_routes_without_generic_linux_dispatch(self):
        script = f'. "{ROOT}/ddnsto/auto-install.sh"\n' + '''
detected_platform=synology
ddnsto_synology_ensure() { printf 'SYNOLOGY'; }
bootstrap_and_run() { exit 99; }
ddnsto_ensure_execute
'''
        result = subprocess.run(['sh', '-eu', '-c', script], capture_output=True, text=True)
        self.assertEqual((result.returncode, result.stdout), (0, 'SYNOLOGY'))

    def test_bootstrap_uses_protected_storage_not_noexec_tmp(self):
        with tempfile.TemporaryDirectory() as directory:
            script = f'. "{ROOT}/ddnsto/auto-synology.sh"\n' + '''
ddnsto_synology_storage() { syno_storage=$FIXTURE; }
ddnsto_bootstrap_zsetup() { [ "$WORK_ROOT" = "$FIXTURE/native" ] || exit 99; ACTIVE_ZSETUP=/bin/true; }
ddnsto_synology_select() { digest=fixture; relative=fixture; }
ddnsto_synology_fetch "$FIXTURE/package.spk"
'''
            result = subprocess.run(['sh', '-eu', '-c', script], env=os.environ | {'FIXTURE': directory, 'WORK_ROOT': '/tmp/noexec'}, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def invoke(self, version='4.2.7-7', token='same-token', fail='', fresh=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = root / 'package'
            (package / 'var').mkdir(parents=True)
            config = package / 'var/ddnsto-config.json'
            original = {'token': 'same-token', 'routeridx': 8, 'supplierCode': 'keep', 'webdav': {'enable': False}}
            if not fresh:
                (package / 'INFO').write_text('package="ddnsto"\n')
                config.write_text(json.dumps(original))
                config.chmod(0o600)
            script = f'''
set -eu
. "{ROOT}/ddnsto/auto-install.sh"
. "{ROOT}/ddnsto/auto-synology.sh"
. "{ROOT}/ddnsto/auto-synology-fresh.sh"
TOKEN=$1
jq() {{
  for arg do [ "$arg" != --rawfile ] || return 2; done
  command jq "$@"
}}
DDNSTO_FLOW_DIR="$FIXTURE/flow"
mkdir "$DDNSTO_FLOW_DIR"
ddnsto_synology_preflight() {{ syno_pkg="$FIXTURE/package"; syno_config="$syno_pkg/var/ddnsto-config.json"; syno_storage="$FIXTURE"; }}
ddnsto_synology_check_paths() {{ :; }}
ddnsto_synology_fresh_preflight() {{ syno_volume=/volume1; }}
ddnsto_synology_fresh_check() {{ [ "$FAIL" != residue ]; }}
ddnsto_synowebapi() {{
  printf 'webapi\\n' >> "$FIXTURE/calls"
  printf 'secret echo: %s' "$TOKEN" >&2
  [ "$FAIL" != api_exit ] || return 1
  if [ "$FAIL" = api_json ]; then printf '{{"success":false,"error":{{"code":4532}}}}'; return; fi
  if [ "$FAIL" = api_empty ]; then return; fi
  flags=0
  for arg do
    case "$arg" in
      extra_values=*) extra=${{arg#extra_values=}} ;;
      force=false|installrunpackage=false|check_codesign=false) flags=$((flags + 1)) ;;
    esac
  done
  [ "$flags" = 3 ] || return 1
  printf '%s' "$extra" | jq -r 'fromjson | {{token:.wizard_ddnsto_token,routeridx:(.wizard_ddnsto_idx|tonumber)}}' > "$syno_config"
  [ "$FAIL" != account ] || printf '{{"token":"foreign","routeridx":0}}' > "$syno_config"
  chmod 600 "$syno_config"
  printf 'package="ddnsto"\\n' > "$syno_pkg/INFO"
  printf '4.2.8-7' > "$FIXTURE/version"
  printf '{{"success":true}}'
}}
ddnsto_synology_running() {{ [ "$FAIL" != running ]; }}
ddnsto_synology_fetch() {{ printf 'download\\n' >> "$FIXTURE/calls"; printf verified > "$1"; }}
ddnsto_synopkg() {{
  printf '%s\\n' "$1" >> "$FIXTURE/calls"
  case "$1" in
    version) cat "$FIXTURE/version" ;;
    install)
      [ "$FAIL" != install ] || return 1
      printf '4.2.8-7' > "$FIXTURE/version"
      if [ ! -f "$syno_config" ]; then
        jq -n --arg token "$wizard_ddnsto_token" '{{token:$token,routeridx:0}}' > "$syno_config"
        chmod 600 "$syno_config"
        printf 'package="ddnsto"\\n' > "$syno_pkg/INFO"
      fi ;;
    start) [ "$FAIL" != start ] ;;
  esac
}}
ddnsto_synology_ensure_locked
'''
            (root / 'version').write_text(version)
            result = subprocess.run(['sh', '-c', script, 'test', token], env=os.environ | {'FIXTURE': directory, 'FAIL': fail}, capture_output=True, text=True)
            calls = (root / 'calls').read_text() if (root / 'calls').exists() else ''
            if not fresh:
                self.assertEqual(json.loads(config.read_text()), original)
            self.assertNotIn(token, result.stdout + result.stderr)
            return result, calls

    def test_upgrade_preserves_configuration(self):
        result, calls = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('install\n', calls)
        self.assertIn('start\n', calls)

    def test_same_or_newer_never_reinstalls(self):
        for version in ['4.2.8-7', '4.2.8-8', '4.2.9-1']:
            result, calls = self.invoke(version=version)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn('install\n', calls)

    def test_foreign_account_or_unknown_version_stops(self):
        for kwargs, error in [({'token': 'other-token'}, 'E_ACCOUNT'), ({'version': 'garbage'}, 'E_VERSION')]:
            result, calls = self.invoke(**kwargs)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(error, result.stderr)
            self.assertNotIn('install\n', calls)
            self.assertNotIn('start\n', calls)

    def test_install_or_start_failure_never_claims_success(self):
        for fail in ['install', 'start', 'running']:
            result, _ = self.invoke(fail=fail)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('E_', result.stderr)

    def test_fresh_uses_package_api_wizard_and_starts(self):
        result, calls = self.invoke(fresh=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('webapi\n', calls)
        self.assertNotIn('install\n', calls)
        self.assertIn('start\n', calls)

    def test_fresh_api_failure_or_residue_never_starts(self):
        for fail in ['api_exit', 'api_json', 'api_empty', 'residue', 'account']:
            result, calls = self.invoke(fresh=True, fail=fail)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('start\n', calls)

    def test_residue_including_dangling_symlink_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'data').mkdir()
            (root / 'link').symlink_to(root / 'missing')
            script = f'. "{ROOT}/ddnsto/auto-install.sh"\n. "{ROOT}/ddnsto/auto-synology-fresh.sh"\nddnsto_synology_absent_paths "$1"\n'
            for name, expected in [('data', 2), ('link', 2), ('absent', 0)]:
                result = subprocess.run(['sh', '-c', script, 'test', str(root / name)], capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, result.stderr)


if __name__ == '__main__':
    unittest.main()
