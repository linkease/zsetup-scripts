"""Signal only the public PID; fixture workers must join before it returns.

No network, native installer, router or host services. Process groups are used
only by test teardown to contain regressions, never as the signal under test.
"""
import hashlib
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class EntryCancellation(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = os.environ | {'FIXTURE': str(self.root)}
        (self.root / 'state').mkdir(mode=0o700)

    def installer(self):
        path = self.root / 'installer.sh'
        path.write_text(f'''#!/bin/sh
set -eu
. "{ROOT}/auto-install.sh"
. "{ROOT}/asus-transaction.sh"
. "{ROOT}/auto-asus.sh"
detected_platform=asus
ddnsto_asus_storage() {{ ASUS_STATE="$FIXTURE/state"; }}
ddnsto_asus_mktemp() {{ mktemp -d "$1/attempt.XXXXXXXX"; }}
ddnsto_ensure_preflight() {{ :; }}
ddnsto_asus_preflight() {{ ASUS_STATE="$FIXTURE/state"; }}
ddnsto_asus_ensure_locked() {{
    : > "$FIXTURE/ready"
    sleep 0.6
    if ! ddnsto_asus_checkpoint; then
        [ -f "$0" ] && : > "$FIXTURE/source-retained"
        : > "$FIXTURE/joined"
        return 143
    fi
    : > "$FIXTURE/committed"
    ddnsto_flow_note started
}}
entry() {{ ddnsto_ensure_entry "$@"; }}
entry "$@"
''')
        return path

    def recommendation(self, installer):
        cache = self.root / 'cache'
        cache.mkdir(mode=0o700)
        selected = cache / 'fixture'
        selected.mkdir(mode=0o700)
        data = installer.read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        payload = selected / (digest + '.sh')
        payload.write_bytes(data)
        payload.chmod(0o600)
        manifest = selected / 'recommended.txt'
        manifest.write_text(f'ddnsto-recommendation-v1-shell\n{digest}\n{len(data)}\n')
        manifest.chmod(0o600)
        fakebin = self.root / 'bin'
        fakebin.mkdir()
        curl = fakebin / 'curl'
        curl.write_text('#!/bin/sh\nprintf 404\n')
        curl.chmod(0o700)
        self.env.update(DDNSTO_RECOMMEND_CACHE=str(cache),
                        PATH=str(fakebin) + ':' + os.environ['PATH'])
        wrapper = self.root / 'recommended.sh'
        # Instantiate only this test fixture; never regenerate a repository entry.
        wrapper.write_text((ROOT / 'recommended-entry.sh').read_text()
                           .replace('@@SOURCE_URL@@', 'https://fixture.invalid')
                           .replace('@@CACHE_KEY@@', 'fixture')
                           .replace('@@ASUS_STORAGE@@', ''))
        return wrapper, selected

    def launch(self, path):
        proc = subprocess.Popen(['sh', str(path)], env=self.env,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                start_new_session=True)
        def cleanup():
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait(timeout=5)
        self.addCleanup(cleanup)
        deadline = time.monotonic() + 5
        while not (self.root / 'ready').exists() and proc.poll() is None and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue((self.root / 'ready').exists(), f'entry exited {proc.poll()}')
        return proc

    def assert_cancelled_and_joined(self, proc, repeated=False):
        proc.send_signal(signal.SIGTERM)
        if repeated:
            time.sleep(0.08)
            self.assertIsNone(proc.poll(), 'outer returned before worker cleanup')
            proc.send_signal(signal.SIGTERM)
        self.assertEqual(proc.wait(timeout=5), 143)
        self.assertTrue((self.root / 'joined').exists(), 'worker outlived public entry')
        self.assertTrue((self.root / 'source-retained').exists(), 'wrapper removed live source')
        self.assertFalse((self.root / 'committed').exists())
        self.assertFalse((self.root / 'state/install.lock').exists())

    def test_public_installer_term_forwards_and_joins(self):
        self.assert_cancelled_and_joined(self.launch(self.installer()))

    def test_repeated_term_does_not_interrupt_join(self):
        self.assert_cancelled_and_joined(self.launch(self.installer()), repeated=True)

    def test_recommendation_term_joins_installer_before_removing_work(self):
        wrapper, cache = self.recommendation(self.installer())
        self.assert_cancelled_and_joined(self.launch(wrapper), repeated=True)
        self.assertFalse((cache / 'lock').exists())
        self.assertEqual(list(cache.glob('attempt.*')), [])

    def test_normal_success_still_returns_zero(self):
        proc = self.launch(self.installer())
        self.assertEqual(proc.wait(timeout=5), 0)
        self.assertTrue((self.root / 'committed').exists())
        self.assertFalse((self.root / 'state/install.lock').exists())

    def test_recommendation_preserves_stdin_argv_and_failure_status(self):
        installer = self.root / 'fixture.sh'
        installer.write_text('''#!/bin/sh
IFS= read -r value || exit 19
printf '%s\\n' "$value" "$1" > "$FIXTURE/input"
exit 17
''')
        wrapper, cache = self.recommendation(installer)
        result = subprocess.run(['sh', str(wrapper), 'literal $() value'],
                                input='input with spaces\n', env=self.env,
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertEqual((self.root / 'input').read_text(),
                         'input with spaces\nliteral $() value\n')
        self.assertFalse((cache / 'lock').exists())


if __name__ == '__main__':
    unittest.main()
