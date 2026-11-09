"""Real competing shells, isolated lock directory; no host services."""
from pathlib import Path
import os
import signal
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HARNESS = r'''
set -eu
. "$ADAPTER"
id() { echo 0; }
# Fixture has no privileged paths. Ancestor policy is tested separately by
# bootstrap_policy_test.py; exercise the real lease/traps with competing shells.
ddnsto_bootstrap_safe_ancestors() { [ -d "$1" ] && [ ! -L "$1" ]; }
action() {
    test -d "$DDNSTO_LOCK_DIR"
    printf 'entered\n'
    case "$MODE" in
        fail) exit 23 ;;
        wait) while :; do sleep 1; done ;;
    esac
}
ddnsto_machine_locked action
'''


class OperationLockTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        etc = self.root / 'etc'
        etc.mkdir()
        self.lock = etc / 'zsetup/install-locks/ddnsto'
        self.lock.parent.mkdir(parents=True)
        # Redirect fixed protected paths in this fixture copy only; do not add
        # production environment overrides that could bypass the global lease.
        adapter = self.root / 'extra-platforms.sh'
        source = (ROOT / 'extra-platforms.sh').read_text()
        self.assertIn('docker_lock=/etc/zsetup/install-locks/ddnsto', source)
        adapter.write_text(source.replace('/etc', str(etc)))
        self.env = dict(os.environ, ADAPTER=str(adapter),
                        DDNSTO_LOCK_DIR=str(self.lock), MODE='success')

    def run_action(self, **env):
        return subprocess.run(['sh', '-c', HARNESS], env=self.env | env,
                              capture_output=True, text=True, timeout=5)

    def test_success_releases_lock(self):
        r = self.run_action()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, 'entered\n')
        self.assertFalse(self.lock.exists())

    def test_failure_preserves_code_and_releases_lock(self):
        r = self.run_action(MODE='fail')
        self.assertEqual(r.returncode, 23, r.stderr)
        self.assertFalse(self.lock.exists())

    def test_foreign_lock_not_removed(self):
        self.lock.mkdir()
        (self.lock / 'owner').write_text('other')
        r = self.run_action()
        self.assertEqual(r.returncode, 16, r.stderr)
        self.assertNotIn('entered', r.stdout)
        self.assertEqual((self.lock / 'owner').read_text(), 'other')

    def test_symlink_lock_rejected_without_touching_target(self):
        target = self.root / 'target'
        target.mkdir()
        self.lock.symlink_to(target)
        r = self.run_action()
        self.assertEqual(r.returncode, 16, r.stderr)
        self.assertTrue(self.lock.is_symlink())
        self.assertTrue(target.is_dir())

    def test_competing_process_and_signal_release(self):
        child = subprocess.Popen(['sh', '-c', HARNESS], env=self.env | {'MODE': 'wait'},
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                 start_new_session=True)
        try:
            self.assertEqual(child.stdout.readline(), 'entered\n')
            r = self.run_action()
            self.assertEqual(r.returncode, 16, r.stderr)
            self.assertTrue(self.lock.exists())
            os.killpg(child.pid, signal.SIGTERM)
            child.communicate(timeout=5)
            self.assertFalse(self.lock.exists())
            self.assertEqual(self.run_action().returncode, 0)
        finally:
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGKILL)
                child.communicate()


if __name__ == '__main__':
    unittest.main()
