"""Real DSM upgrade/account/stability controller; simulated synopkg and /proc."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SynologyRunningUpgrade(unittest.TestCase):
    def invoke(self, fault=''):
        with tempfile.TemporaryDirectory(prefix='synology-upgrade-') as d:
            root = Path(d)
            pkg = root / 'package'
            (pkg / 'var').mkdir(parents=True)
            (pkg / 'target/bin').mkdir(parents=True)
            (pkg / 'target/bin/ddnsto').write_bytes(b'old client fixture')
            (pkg / 'INFO').write_text('package="ddnsto"\n')
            (pkg / 'var/ddnsto.pid').write_text('1234')
            config = pkg / 'var/ddnsto-config.json'
            before = b'{ "token":"same-token", "routeridx":8, "custom":{"keep":true} }\n'
            config.write_bytes(before)
            (root / 'version').write_text('4.2.7-7')
            (root / 'running').touch()
            (root / 'flow').mkdir()
            script = f'. "{ROOT}/sources/ddnsto/auto-install.sh"\n. "{ROOT}/sources/ddnsto/auto-synology.sh"\n' + r'''
set -eu
TOKEN=same-token
DDNSTO_FLOW_DIR=$FIXTURE/flow
ddnsto_synology_preflight() { syno_pkg=$FIXTURE/package; syno_config=$syno_pkg/var/ddnsto-config.json; syno_storage=$FIXTURE; }
ddnsto_synology_check_paths() { :; }
ddnsto_synology_fetch() { [ "$FAULT" != download ] || return 11; printf verified > "$1"; }
readlink() {
    case "$1" in /proc/*/exe) printf '%s\n' "$syno_pkg/target/bin/ddnsto" ;; *) command readlink "$@" ;; esac
}
kill() { [ "$1" = -0 ] && [ -f "$FIXTURE/running" ]; }
sleep() { [ "$FAULT" != unstable ] || printf 9999 > "$syno_pkg/var/ddnsto.pid"; }
ddnsto_synopkg() {
    printf '%s\n' "$1" >> "$FIXTURE/calls"
    case "$1" in
        version) cat "$FIXTURE/version" ;;
        install)
            rm -f "$FIXTURE/running"
            printf 'new client fixture' > "$syno_pkg/target/bin/ddnsto"
            printf 4.2.8-7 > "$FIXTURE/version"
            [ "$FAULT" != package ] || return 9 ;;
        start)
            [ "$FAULT" != start ] || return 9
            printf 2345 > "$syno_pkg/var/ddnsto.pid"
            touch "$FIXTURE/running" ;;
        status) if [ -f "$FIXTURE/running" ]; then printf '{"status":"running"}'; else printf '{"status":"stop"}'; fi ;;
        *) return 99 ;;
    esac
}
ddnsto_synology_ensure_locked
'''
            result = subprocess.run(['sh', '-c', script], env=os.environ | {'FIXTURE': d, 'FAULT': fault},
                                    text=True, capture_output=True, timeout=15)
            self.assertEqual(config.read_bytes(), before)
            self.assertNotIn('same-token', result.stdout + result.stderr)
            return result, {
                'version': (root / 'version').read_text(),
                'running': (root / 'running').exists(),
                'pid': (pkg / 'var/ddnsto.pid').read_text(),
                'events': (root / 'flow/events.log').read_text() if (root / 'flow/events.log').exists() else '',
                'backups': len(list(root.glob('package.*/config.before.json'))),
                'calls': (root / 'calls').read_text().splitlines(),
            }

    def test_running_old_package_upgrade_checks_new_version_and_stable_process(self):
        result, state = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((state['version'], state['running'], state['pid']), ('4.2.8-7', True, '2345'))
        self.assertEqual(state['calls'].count('status'), 3)
        self.assertIn('stage=started', state['events'])
        self.assertEqual(state['backups'], 1)

    def test_download_failure_preserves_running_old_package(self):
        result, state = self.invoke('download')
        # With errexit, ddnsto_flow_error returns 2 before the later exit 11.
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn('E_DOWNLOAD', result.stderr)
        self.assertEqual((state['version'], state['running'], state['pid']), ('4.2.7-7', True, '1234'))
        self.assertNotIn('install', state['calls'])

    def test_partial_package_failure_does_not_claim_old_version_restored(self):
        result, state = self.invoke('package')
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn('E_PACKAGE', result.stderr)
        self.assertEqual(state['version'], '4.2.8-7')
        self.assertFalse(state['running'])
        self.assertEqual(state['backups'], 1)
        self.assertNotIn('stage=started', state['events'])

    def test_start_failure_leaves_new_package_stopped_and_reports_error(self):
        result, state = self.invoke('start')
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn('E_START', result.stderr)
        self.assertEqual(state['version'], '4.2.8-7')
        self.assertFalse(state['running'])
        self.assertNotIn('stage=started', state['events'])

    def test_pid_changes_after_start_are_not_accepted_as_stable(self):
        result, state = self.invoke('unstable')
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn('E_START', result.stderr)
        self.assertNotIn('stage=started', state['events'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
