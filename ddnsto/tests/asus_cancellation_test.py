import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class AsusCancellation(unittest.TestCase):
    def test_controller_waits_for_worker_before_unlock_and_return(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = f'''
set -eu
. "{ROOT}/auto-install.sh"
. "{ROOT}/asus-transaction.sh"
. "{ROOT}/auto-asus.sh"
ddnsto_asus_preflight() {{ ASUS_STATE="$FIXTURE"; }}
ddnsto_asus_ensure_locked() {{
    : > "$FIXTURE/ready"
    sleep 0.3
    ddnsto_asus_checkpoint || return $?
    : > "$FIXTURE/unexpected-mutation"
}}
ddnsto_asus_ensure &
worker=$!
echo "$worker" > "$FIXTURE/controller"
wait "$worker"
'''
            process = subprocess.Popen(['sh', '-c', script], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       text=True, env=os.environ | {'FIXTURE': directory})
            deadline = time.monotonic() + 5
            while not (root / 'ready').exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue((root / 'ready').exists())
            os.kill(int((root / 'controller').read_text()), signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=5)
            # A nested descendant may retain stdout after its parent exits;
            # communicate joins that lifetime and reveals post-return writes.
            self.assertFalse((root / 'unexpected-mutation').exists(), stdout + stderr)
            self.assertFalse((root / 'install.lock').exists(), stdout + stderr)
            self.assertNotEqual(process.returncode, 0)


if __name__ == '__main__':
    unittest.main()
