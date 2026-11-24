#!/usr/bin/env python3
"""Exercise a complete apps/ release against an isolated server directory."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
APPS = ROOT / "apps"
PUBLISH = ROOT / "scripts/publish.sh"


def publish(mode, live):
    env = os.environ | {"ZSETUP_PUBLISH_ALLOW_UNVERSIONED": "1"}
    return subprocess.run(
        ["sh", str(PUBLISH), mode, str(APPS), str(live)],
        env=env, text=True, capture_output=True, timeout=120,
    )


subprocess.run([sys.executable, "-B", str(ROOT / "scripts/build.py"), "--check"],
               check=True, stdout=subprocess.DEVNULL)

with tempfile.TemporaryDirectory(prefix="apps-full-preflight-") as folder:
    binary = Path(folder) / "binary"
    live = binary / "zsetup-scripts/apps"
    (live / "zsetup").mkdir(parents=True)
    (live / "ddnsto").mkdir()
    (binary / "zsetup").mkdir()
    (binary / "ddnsto").mkdir()
    (binary / "server-owned").mkdir()
    old_config = b"previous production config\n"
    old_entry = b"previous ddnsto entry\n"
    unrelated = b"must survive apps publication\n"
    (live / "zsetup/config.json").write_bytes(old_config)
    (live / "ddnsto/install.sh").write_bytes(old_entry)
    root_config = b"existing global zsetup config\n"
    root_entry = b"existing global ddnsto entry\n"
    (binary / "zsetup/config.json").write_bytes(root_config)
    (binary / "ddnsto/install.sh").write_bytes(root_entry)
    (binary / "server-owned/product.bin").write_bytes(unrelated)

    staged = publish("stage", live)
    assert staged.returncode == 0, staged.stderr
    assert (live / "zsetup/config.json").read_bytes() == old_config
    assert (live / "ddnsto/install.sh").read_bytes() == old_entry
    assert (live / "ddnsto/versions/0.3.0/install.sh").read_bytes() == (
        APPS / "ddnsto/versions/0.3.0/install.sh").read_bytes()

    activated = publish("activate", live)
    assert activated.returncode == 0, activated.stderr
    assert (live / "SHA256SUMS").read_bytes() == (APPS / "SHA256SUMS").read_bytes()
    verified = publish("verify", live)
    assert verified.returncode == 0, verified.stderr
    assert (binary / "server-owned/product.bin").read_bytes() == unrelated
    assert (binary / "zsetup/config.json").read_bytes() == root_config
    assert (binary / "ddnsto/install.sh").read_bytes() == root_entry
    assert not any(path.name == "tests" for path in live.rglob("tests"))

    rolled_back = publish("rollback", live)
    assert rolled_back.returncode == 0, rolled_back.stderr
    assert (live / "zsetup/config.json").read_bytes() == old_config
    assert (live / "ddnsto/install.sh").read_bytes() == old_entry
    assert not (live / "SHA256SUMS").exists()
    assert (live / "ddnsto/versions/0.3.0/install.sh").is_file()
    assert (binary / "server-owned/product.bin").read_bytes() == unrelated
    assert (binary / "zsetup/config.json").read_bytes() == root_config
    assert (binary / "ddnsto/install.sh").read_bytes() == root_entry

print("Full apps preflight: stage, activate, byte verification, rollback and server-owned preservation passed")
