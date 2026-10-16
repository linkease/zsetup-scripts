"""Real native bounded extraction; archive output never writes its own paths."""
import io
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
native = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix="installer-bounds-") as name:
    root = Path(name)
    archive = root / "bomb.tar.gz"
    with tarfile.open(archive, "w:gz") as tar:
        info = tarfile.TarInfo("member"); info.size = 100000
        tar.addfile(info, io.BytesIO(b"x" * info.size))
    code = '. "$1"; . "$2"; shift 2; installer_policy ddnsto; INSTALLER_MAX_EXPANDED=4096; installer_extract_member "$1" tar -xOzf "$2" member'
    output = root / "out"
    output.write_bytes(b"original")
    result = subprocess.run(["sh", "-eu", "-c", code, "test", str(ROOT / "lib/install-storage.sh"), str(ROOT / "lib/install-bounds.sh"), str(output), str(archive)], env={**os.environ, "ZSETUP_BIN": native}, capture_output=True)
    assert result.returncode == 11, result
    assert output.read_bytes() == b"original"
    assert not list(root.glob(".zsetup-capture*"))
    # The shared total also bounds many individually small members.
    code = '. "$1"; . "$2"; shift 2; installer_policy ddnsto; INSTALLER_MAX_EXPANDED=5; installer_extract_member "$1" printf hello; installer_extract_member "$2" printf x'
    result = subprocess.run(["sh", "-eu", "-c", code, "test", str(ROOT / "lib/install-storage.sh"), str(ROOT / "lib/install-bounds.sh"), str(root / "first"), str(root / "second")], env={**os.environ, "ZSETUP_BIN": native}, capture_output=True)
    assert result.returncode == 11, result
    assert (root / "first").read_bytes() == b"hello" and not (root / "second").exists()
print("Bounded extraction: expansion bomb, aggregate cap, old output and temporary cleanup passed")
