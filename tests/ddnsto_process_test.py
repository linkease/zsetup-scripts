"""Generic Linux process fallback; only disposable user-owned processes."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / 'sources/ddnsto/process-linux.sh'
NATIVE = os.environ.get('DDNSTO_TEST_NATIVE', '')


class ProcessTests(unittest.TestCase):
    def test_linux_binary_selection_does_not_require_package_manager(self):
        for distro in ('ubuntu', 'debian', 'centos', 'rhel', 'linux'):
            r = subprocess.run(['sh', '-c', '''
. "$1/sources/ddnsto/managed-cli.sh"
ddnsto_appliance_platform() { :; }
ddnsto_error() { printf '%s\n' "$*" >&2; }
REQUESTED_PLATFORM=auto; os=$2; package_manager=unknown
ddnsto_detect_platform
''', 'test', str(ROOT), distro], text=True, capture_output=True)
            self.assertEqual(r.returncode, 0, distro + ': ' + r.stderr)

    def test_index_does_not_require_apt_for_linux_binary(self):
        import json
        targets = json.loads((ROOT / 'apps/ddnsto/app.json').read_text())['targets']
        for distro in ('ubuntu', 'debian'):
            self.assertTrue(any(distro in t['os'] and '*' in t['package_manager'] for t in targets))

    def test_generic_backend_replaces_s6_in_generated_program(self):
        import sys
        sys.path.insert(0, str(ROOT / 'scripts'))
        from build_ddnsto_installer import compose
        script = compose(ROOT, ROOT / 'apps/ddnsto')
        self.assertIn('ddnsto_process_entry()', script)
        self.assertNotIn('ddnsto_s6_', script)
        program = script.split("cat <<'ZSETUP_PRIVATE_ROOT_PROGRAM'\n", 1)[1].split('\nZSETUP_PRIVATE_ROOT_PROGRAM', 1)[0]
        self.assertTrue(program.rstrip().endswith('installer_dispatch ddnsto "$@"'))
        self.assertIn('unset ZSETUP_CA_FILE', program)

    def test_default_path_is_under_real_user_home(self):
        with tempfile.TemporaryDirectory(prefix="ddnsto-home ' ") as d:
            r = subprocess.run(['sh', '-c', '. "$1"; ddnsto_process_paths; printf "%s" "$PROCESS_PREFIX"',
                                'test', str(MODULE)], env={**os.environ, 'HOME': d}, text=True, capture_output=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(r.stdout, d + '/.local/share/ddnsto')

    def test_missing_or_relative_home_is_rejected(self):
        for home_value in ('', 'relative-home'):
            r = subprocess.run(['sh', '-c', '. "$1"; ddnsto_process_paths', 'test', str(MODULE)],
                               env={**os.environ, 'HOME': home_value}, text=True, capture_output=True)
            self.assertNotEqual(r.returncode, 0)

    def test_home_install_creates_parents_and_escapes_config_paths(self):
        self.run_case('''
ddnsto_process_entry
test "$PROCESS_PREFIX" = "$FIXTURE/user's home/.local/share/ddnsto"
grep -F "bootConfigPath: '$FIXTURE/user''s home/.local/share/ddnsto/.ddnsto_boot.cfg'" "$PROCESS_PREFIX/config.yaml"
test "$(stat -c %a "$PROCESS_PREFIX")" = 700
first=$(cat "$PROCESS_PREFIX/pid")
ddnsto_process_entry
test "$first" = "$(cat "$PROCESS_PREFIX/pid")"
''', use_home=True)

    def test_symlink_home_parent_rejected_before_writes(self):
        self.run_case('''
mkdir "$FIXTURE/foreign"
ln -s "$FIXTURE/foreign" "$FIXTURE/user's home/.local"
if ddnsto_process_entry; then exit 90; fi
test -z "$(ls -A "$FIXTURE/foreign")"
''', use_home=True)

    def run_case(self, body, use_home=False):
        self.assertTrue(MODULE.is_file(), 'generic process backend is missing')
        if not NATIVE or not shutil.which('cc'):
            self.skipTest('requires DDNSTO_TEST_NATIVE and C compiler for isolated fixture')
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / 'client.c').write_text('''
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>
int main(int n, char **v) {
 if(n>1 && !strcmp(v[1],"-v")){puts("4.2.8");return 0;}
 if(getenv("FAIL_START")) return 7;
 for(;;) sleep(1);
}
''')
            subprocess.run(['cc', str(root / 'client.c'), '-o', str(root / 'client')], check=True)
            script = '''
set -eu
. "$REPO/lib/install-storage.sh"
. "$REPO/lib/install-bounds.sh"
. "$REPO/lib/install-transaction.sh"
. "$REPO/lib/install-service.sh"
. "$REPO/sources/ddnsto/portable-files.sh"
. "$REPO/sources/ddnsto/auto-install.sh"
. "$REPO/sources/ddnsto/managed-cli.sh"
. "$REPO/sources/ddnsto/process-linux.sh"
. "$REPO/sources/ddnsto/product-pins.sh"
. "$REPO/sources/ddnsto/process-product.sh"
. "$REPO/sources/ddnsto/process-install.sh"
if [ "$USE_HOME" = 0 ]; then ddnsto_process_paths() { PROCESS_PREFIX=$FIXTURE/owned; }; fi
ddnsto_process_fetch() {
 [ "${FAIL_FETCH:-0}" != 1 ] || return 11
 cp "$FIXTURE/client" "$transaction_dir/ddnsto"
}
ddnsto_pinned_version() { echo 4.2.8; }
ddnsto_pinned_sha() { printf '%064d\\n' 0; }
TOKEN=fixture-token; BUSINESS_ENV=production; BUSINESS_ENV_EXPLICIT=0
SWITCH_ENVIRONMENT=0; ACTION=ensure; arch=x86_64
installer_prefix=; installer_work_dir=; detected_platform=linux
ddnsto_process_paths
cleanup() { ddnsto_process_stop >/dev/null 2>&1 || :; }
trap cleanup EXIT
''' + body
            task_home = root / "user's home"
            task_home.mkdir(mode=0o700)
            r = subprocess.run(['sh', '-c', script], env={**os.environ,
                'REPO': str(ROOT), 'FIXTURE': d, 'ZSETUP_BIN': NATIVE,
                'HOME': str(task_home), 'USE_HOME': str(int(use_home))},
                text=True, capture_output=True, timeout=40)
            self.assertEqual(r.returncode, 0, r.stderr + r.stdout)

    def test_fresh_repeat_stop_start(self):
        self.run_case('''
ddnsto_process_entry
ddnsto_process_paths
first=$(cut -d ' ' -f 1 "$PROCESS_PREFIX/pid")
cp "$PROCESS_PREFIX/config.yaml" "$FIXTURE/original"
ddnsto_process_entry
test "$first" = "$(cut -d ' ' -f 1 "$PROCESS_PREFIX/pid")"
cmp "$PROCESS_PREFIX/config.yaml" "$FIXTURE/original"
ACTION=stop; ddnsto_process_entry
! kill -0 "$first" 2>/dev/null || test "$(cut -d ' ' -f 3 /proc/$first/stat)" = Z
ACTION=start; TOKEN=; ddnsto_process_entry
test "$first" != "$(cut -d ' ' -f 1 "$PROCESS_PREFIX/pid")"
''')

    def test_different_account_is_not_overwritten(self):
        self.run_case('''
ddnsto_process_entry
cp "$PROCESS_PREFIX/config.yaml" "$FIXTURE/original"
TOKEN=different-account
if ddnsto_process_entry; then exit 90; fi
cmp "$PROCESS_PREFIX/config.yaml" "$FIXTURE/original"
''')

    def test_symlink_prefix_rejected(self):
        self.run_case('''
mkdir "$FIXTURE/foreign"
ln -s "$FIXTURE/foreign" "$FIXTURE/owned"
if ddnsto_process_entry; then exit 90; fi
test -z "$(ls -A "$FIXTURE/foreign")"
''')

    def test_world_writable_prefix_rejected(self):
        self.run_case('''
mkdir -m 777 "$FIXTURE/owned"
if ddnsto_process_entry; then exit 90; fi
test -z "$(ls -A "$FIXTURE/owned")"
''')

    def test_download_failure_does_not_start(self):
        self.run_case('''
FAIL_FETCH=1
if ddnsto_process_entry; then exit 90; fi
test ! -e "$PROCESS_PREFIX/pid"
''')

    def test_failed_start_is_not_success(self):
        self.run_case('''
export FAIL_START=1
if ddnsto_process_entry; then exit 90; fi
test -f "$PROCESS_PREFIX/config.yaml"
! ddnsto_process_running
''')

    def test_pid_reuse_never_kills_foreign_process(self):
        self.run_case('''
ddnsto_process_entry
ddnsto_process_stop
echo $$ > "$PROCESS_PREFIX/pid"
ddnsto_process_stop
kill -0 $$
''')

    def test_unsupported_arch_has_clear_error(self):
        self.run_case('''
arch=mips
if ddnsto_process_entry 2> "$FIXTURE/error"; then exit 90; fi
grep -q E_ARCH "$FIXTURE/error"
test ! -d "$FIXTURE/owned"
''')

    def test_environment_conflict_preserves_running_process(self):
        self.run_case('''
ddnsto_process_entry
first=$(cat "$PROCESS_PREFIX/pid")
BUSINESS_ENV=test; BUSINESS_ENV_EXPLICIT=1
if ddnsto_process_entry; then exit 90; fi
test "$first" = "$(cat "$PROCESS_PREFIX/pid")"
''')

    def test_environment_switch_requires_install_transaction(self):
        self.run_case('''
ddnsto_process_entry
BUSINESS_ENV=test; SWITCH_ENVIRONMENT=1; ACTION=start
if ddnsto_process_entry; then exit 90; fi
''')

    def test_upgrade_download_failure_preserves_running_pid(self):
        self.run_case('''
ddnsto_process_entry
first=$(cat "$PROCESS_PREFIX/pid")
ddnsto_pinned_version() { echo 4.2.9; }
FAIL_FETCH=1
if ddnsto_process_entry; then exit 90; fi
test "$first" = "$(cat "$PROCESS_PREFIX/pid")"
ddnsto_process_running
''')

    def test_newer_installed_version_is_not_downgraded(self):
        self.run_case('''
ddnsto_process_entry
first=$(cat "$PROCESS_PREFIX/pid")
ddnsto_pinned_version() { echo 4.2.7; }
if ddnsto_process_entry; then exit 90; fi
test "$first" = "$(cat "$PROCESS_PREFIX/pid")"
''')

    def test_changed_digest_is_rejected(self):
        self.run_case('''
ddnsto_process_entry
ddnsto_pinned_sha() { printf '%064d\\n' 1; }
if ddnsto_process_entry; then exit 90; fi
ddnsto_process_running
''')

    def test_failed_upgrade_rolls_back(self):
        self.run_case('''
ddnsto_process_entry
cp "$PROCESS_PREFIX/receipt" "$FIXTURE/original-receipt"
cp "$PROCESS_PREFIX/config.yaml" "$FIXTURE/original-config"
ddnsto_pinned_version() { echo 4.2.9; }
ddnsto_process_fetch() { cp /bin/false "$transaction_dir/ddnsto"; }
if ddnsto_process_entry; then exit 90; fi
cmp "$PROCESS_PREFIX/receipt" "$FIXTURE/original-receipt"
cmp "$PROCESS_PREFIX/config.yaml" "$FIXTURE/original-config"
ddnsto_process_running
''')

    def test_detaches_from_terminal_session_when_setsid_available(self):
        self.run_case('''
command -v setsid >/dev/null || exit 0
ddnsto_process_entry
pid=$(cut -d ' ' -f 1 "$PROCESS_PREFIX/pid")
test "$(cut -d ' ' -f 6 /proc/$pid/stat)" != "$(cut -d ' ' -f 6 /proc/$$/stat)"
''')


if __name__ == '__main__':
    unittest.main()
