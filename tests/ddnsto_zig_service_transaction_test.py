"""Coordinator start/rollback with isolated files and a fake service manager."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ServiceTransaction(unittest.TestCase):
    def run_case(self, body):
        with tempfile.TemporaryDirectory(prefix='zig-transaction-') as directory:
            script = '''set -eu
. "$REPO/lib/install-service.sh"
. "$REPO/lib/install-bounds.sh"
. "$REPO/sources/ddnsto/linux-zig-config.sh"
. "$REPO/sources/ddnsto/product-pins.sh"
. "$REPO/sources/ddnsto/managed-service.sh"
if [ -f "$REPO/sources/ddnsto/linux-zig-service.sh" ]; then . "$REPO/sources/ddnsto/linux-zig-service.sh"; fi
SERVICE_APP=ddnsto; SERVICE_BACKEND=systemd; SERVICE_NAME=fixture
INSTALLER_PREFIX="$TEST_ROOT/prefix"; state="$TEST_ROOT/state"
transaction_dir="$TEST_ROOT/transaction"; SERVICE_CONFIG="$state/config.json"
SERVICE_UNIT="$state/unit"; INSTALLER_RESERVE=0
mkdir -p "$INSTALLER_PREFIX/versions/4.2.1/bin" "$state" "$transaction_dir"
old_exec="$INSTALLER_PREFIX/versions/4.2.1/bin/ddnsto"
printf '#!/bin/sh\\nexit 0\\n' > "$old_exec"
chmod 700 "$old_exec"
ddnsto_zig_service_wrapper "$old_exec" "$state/.ddnsto-zig.yaml" > "$(dirname "$old_exec")/.service-run"
ln -s versions/4.2.1 "$INSTALLER_PREFIX/current"
printf '{"token":"old-account","routeridx":7}\\n' > "$SERVICE_CONFIG"
printf 'old unit\\n' > "$SERVICE_UNIT"
ZSETUP_BIN=native
# Isolate OS/native boundaries, not coordinator or configuration logic.
native() {
 if [ "$1" = storage ]; then printf 'true\\n'; return; fi
 if [ "$1" = capture ]; then
   output=$3; shift 3
   while [ "$1" != -- ]; do shift; done; shift
   "$@" > "$output"; return
 fi
 [ "$1" = run ]; shift 2; "$@"
}
installer_exec_native() { "$@"; }
systemctl() { printf '%s\\n' "$1" >> "$TEST_ROOT/actions"; }
''' + body
            return subprocess.run(['sh', '-c', script], capture_output=True, text=True,
                                  env=os.environ | {'REPO': str(ROOT), 'TEST_ROOT': directory})

    def test_start_reads_current_json_each_time(self):
        r = self.run_case('''
installer_service_manager start
grep -q 'userToken: "old-account"' "$state/.ddnsto-zig.yaml"
printf '{"token":"new-account","routeridx":8}\\n' > "$SERVICE_CONFIG"
installer_service_manager start
grep -q 'userToken: "new-account"' "$state/.ddnsto-zig.yaml"
grep -q 'routerIdx: 8' "$state/.ddnsto-zig.yaml"
''')
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_invalid_config_never_starts_or_replaces_previous_runtime(self):
        r = self.run_case('''
printf 'old runtime\\n' > "$state/.ddnsto-zig.yaml"
printf '{"token":123}\\n' > "$SERVICE_CONFIG"
if installer_service_manager start; then exit 97; fi
test ! -e "$TEST_ROOT/actions"
test "$(cat "$state/.ddnsto-zig.yaml")" = 'old runtime'
test -z "$(ls -A "$state" | grep '^.zig-config.' || :)"
''')
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_failed_update_rollback_regenerates_old_configuration(self):
        r = self.run_case('''
cp "$SERVICE_CONFIG" "$transaction_dir/old-config"
cp "$SERVICE_UNIT" "$transaction_dir/old-unit"
printf '{"token":"failed-update"}\\n' > "$SERVICE_CONFIG"
installer_service_manager start
SERVICE_CHANGED=1; SERVICE_HAD_UNIT=1; SERVICE_CONFIG_TOUCHED=1
SERVICE_HAD_CONFIG=1; SERVICE_OLD=versions/4.2.1
SERVICE_WAS_ENABLED=1; SERVICE_WAS_ACTIVE=1
SERVICE_CANDIDATE=; SERVICE_NEW_VERSION=0; SERVICE_DEST_LOCK_HELD=0
SERVICE_EXEC=/deliberately/stale/new/version
installer_service_cleanup
grep -q 'userToken: "old-account"' "$state/.ddnsto-zig.yaml"
grep -q 'routerIdx: 7' "$state/.ddnsto-zig.yaml"
test "$(readlink "$INSTALLER_PREFIX/current")" = versions/4.2.1
''')
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_runtime_symlink_is_not_followed(self):
        r = self.run_case('''
printf 'unrelated\\n' > "$TEST_ROOT/other"
ln -s "$TEST_ROOT/other" "$state/.ddnsto-zig.yaml"
if installer_service_manager start; then exit 97; fi
test "$(cat "$TEST_ROOT/other")" = unrelated
test ! -e "$TEST_ROOT/actions"
''')
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_managed_receipt_accepts_only_pinned_zig_wrapper(self):
        r = self.run_case('''
arch=x86_64
ddnsto_process_product_metadata zig
version_dir="$INSTALLER_PREFIX/versions/4.2.1"
printf '%s\\n' .service-run ddnsto > "$version_dir/.files"
printf '%s\\n' "$arch" > "$version_dir/.arch"
printf '%s\\n' "$PROCESS_DIGEST" > "$version_dir/.artifact-sha256"
chmod 700 "$version_dir/bin/.service-run"
ddnsto_managed_receipt versions/4.2.1
printf '%064d\\n' 0 > "$version_dir/.artifact-sha256"
if ddnsto_managed_receipt versions/4.2.1; then exit 97; fi
''')
        self.assertEqual(r.returncode, 0, r.stderr)


if __name__ == '__main__':
    unittest.main()
