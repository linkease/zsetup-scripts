"""Offline real Zig startup in an explicitly isolated network namespace.

Set DDNSTO_TEST_ZIG and DDNSTO_TEST_NATIVE; never supplies a real account token.
The download boundary is replaced by a local copy of reviewed SHA-bound bytes.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ZigNative(unittest.TestCase):
    @unittest.skipUnless(os.environ.get('DDNSTO_TEST_ZIG') and os.environ.get('DDNSTO_TEST_NATIVE'),
                         'requires reviewed Zig/native binaries and offline namespace')
    def test_low_space_install_repeat_stop_and_restart(self):
        self.run_install()

    @unittest.skipUnless(os.environ.get('DDNSTO_TEST_SMALL_FS') and os.environ.get('DDNSTO_TEST_ZIG')
                         and os.environ.get('DDNSTO_TEST_NATIVE'), 'requires isolated 3 MiB filesystem')
    def test_actual_small_filesystem(self):
        root = os.environ['DDNSTO_TEST_SMALL_FS']
        stats = os.statvfs(root)
        self.assertEqual(stats.f_blocks * stats.f_frsize, 3 * 1048576)
        self.run_install(real_storage=True, parent=root)

    def run_install(self, real_storage=False, parent=None):
        # Refuse ordinary host networking even if a maintainer sets the inputs.
        interfaces = [line.split(':', 1)[0].strip() for line in Path('/proc/net/dev').read_text().splitlines()[2:]]
        self.assertEqual(interfaces, ['lo'], 'test requires an offline network namespace')
        self.assertLessEqual(len(Path('/proc/net/route').read_text().splitlines()), 1)
        binary = Path(os.environ['DDNSTO_TEST_ZIG'])
        config = json.loads((ROOT / 'sources/ddnsto/platform-releases.json').read_text())['platforms']['linux']
        self.assertEqual(hashlib.sha256(binary.read_bytes()).hexdigest(), config['zig_x86_64_sha256'])
        with tempfile.TemporaryDirectory(prefix='ddnsto-zig-native-', dir=parent) as directory:
            script = 'set -eu\n' + ''.join(f'. "{ROOT / path}"\n' for path in (
                'lib/install-storage.sh', 'lib/install-bounds.sh', 'lib/install-transaction.sh',
                'lib/install-service.sh', 'sources/ddnsto/portable-files.sh',
                'sources/ddnsto/managed-cli.sh', 'sources/ddnsto/managed-service.sh',
                'sources/ddnsto/auto-install.sh', 'sources/ddnsto/product-pins.sh',
                'sources/ddnsto/process-product.sh', 'sources/ddnsto/process-linux.sh',
                'sources/ddnsto/process-install.sh')) + '''
probe() {
 if [ "$TEST_REAL_STORAGE" = 0 ] && [ "$1" = storage ] && [ "$4" = available_bytes ]; then echo "${TEST_AVAILABLE:-3145728}"
 else "$DDNSTO_TEST_NATIVE" "$@"; fi
}
ZSETUP_BIN=probe
installer_download() {
 [ "$1" = ddnsto-zig/ddnsto.x86_64 ] || return 97
 cp "$DDNSTO_TEST_ZIG" "$2"
}
TOKEN=offline-fixture-token; BUSINESS_ENV=production; BUSINESS_ENV_EXPLICIT=0
SWITCH_ENVIRONMENT=0; ACTION=ensure; arch=x86_64; detected_platform=linux
installer_prefix=; installer_work_dir=; FORCE_VERSION=
ddnsto_process_paths
cleanup() { ddnsto_process_stop >/dev/null 2>&1 || :; }
trap cleanup EXIT
ddnsto_process_entry
first=$(cat "$PROCESS_PREFIX/pid")
test "$("$PROCESS_PREFIX/ddnsto" -v)" = 4.2.1
grep -q 'enabled: false' "$PROCESS_PREFIX/config.yaml"
TEST_AVAILABLE=1048576
if [ "$TEST_REAL_STORAGE" = 1 ]; then
 # Consume actual capacity after installation; repeat/start must reuse the
 # installed binary rather than insist on another download and backup.
 dd if=/dev/zero of="$HOME/space-pressure" bs=1024 count=1500 2>/dev/null
 test "$("$DDNSTO_TEST_NATIVE" storage "$PROCESS_PREFIX" get available_bytes)" -lt 1048576
fi
ddnsto_process_entry
test "$first" = "$(cat "$PROCESS_PREFIX/pid")"
ACTION=stop; ddnsto_process_entry
! ddnsto_process_running
ACTION=start; ddnsto_process_entry
ddnsto_process_running
'''
            result = subprocess.run(['sh', '-c', script], capture_output=True, text=True,
                                    env=os.environ | {'HOME': directory, 'TEST_REAL_STORAGE': str(int(real_storage))}, timeout=35)
            logs = '\n'.join(p.read_text(errors='replace') for p in Path(directory).rglob('startup.log'))
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout + logs)


if __name__ == '__main__':
    unittest.main()
