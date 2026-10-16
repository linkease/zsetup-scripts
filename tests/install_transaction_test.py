"""Real native coordination in isolated directories, no host services."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
native = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix="installer-txn-") as name:
    root = Path(name)
    work = root / "work"
    code = '. "$1"; shift; INSTALLER_WORK_ROOT=$1; installer_transaction_begin; printf ready; installer_owned_native "$ZSETUP_BIN" capture -o "$transaction_dir/out" --max-bytes 100 -- sh -c "sleep 20 & echo \\$! > \\"\$1\\"; wait" child "$2"'
    env = {**os.environ, "ZSETUP_BIN": native}
    # Success and failure clean exactly their own files.
    for result in [0, 37]:
        script = '. "$1"; INSTALLER_WORK_ROOT=$2; installer_transaction_begin; echo owned > "$transaction_dir/product"; exit "$3"'
        done = subprocess.run(["sh", "-eu", "-c", script, "test", str(ROOT / "lib/install-transaction.sh"), str(work), str(result)], env=env, capture_output=True)
        assert done.returncode == result, done
        assert not list(work.iterdir()), list(work.iterdir())
    # Signal cancellation waits for native capture to close/join its full group.
    pidfile = root / "child.pid"
    process = subprocess.Popen(["sh", "-eu", "-c", code, "test", str(ROOT / "lib/install-transaction.sh"), str(work), str(pidfile)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        assert process.stdout.read(5) == b"ready"
        deadline = time.monotonic() + 5
        while not pidfile.exists():
            assert time.monotonic() < deadline
            time.sleep(.01)
        # Concurrent attempt must not clean or adopt the live transaction.
        denied = subprocess.run(["sh", "-eu", "-c", '. "$1"; INSTALLER_WORK_ROOT=$2; installer_transaction_begin', "test", str(ROOT / "lib/install-transaction.sh"), str(work)], env=env, capture_output=True)
        assert denied.returncode == 2, denied
        process.send_signal(signal.SIGTERM)
        out, err = process.communicate(timeout=5)
        assert process.returncode == 143, (process.returncode, err)
        assert not list(work.iterdir()), list(work.iterdir())
        try:
            os.kill(int(pidfile.read_text()), 0)
            raise AssertionError("owned grandchild survived")
        except ProcessLookupError:
            pass
    finally:
        if process.poll() is None:
            process.kill(); process.wait()
    # A crash/stale lock is not guessed away; subsequent calls cannot accumulate.
    lock = work / ".install-lock"
    lock.mkdir()
    (lock / "owner").write_text("stale-or-unknown\n")
    denied = subprocess.run(["sh", "-eu", "-c", '. "$1"; INSTALLER_WORK_ROOT=$2; installer_transaction_begin', "test", str(ROOT / "lib/install-transaction.sh"), str(work)], env=env, capture_output=True)
    assert denied.returncode == 2 and lock.exists(), denied
    # Existing shared directory and symlink are refused, never chmodded.
    work.chmod(0o777)
    denied = subprocess.run(["sh", "-eu", "-c", '. "$1"; INSTALLER_WORK_ROOT=$2; installer_transaction_begin', "test", str(ROOT / "lib/install-transaction.sh"), str(work)], env=env, capture_output=True)
    assert denied.returncode == 12 and work.stat().st_mode & 0o777 == 0o777, denied
print("Transactions: success/failure/TERM, join, concurrent isolation, stale lock and private ownership passed")
