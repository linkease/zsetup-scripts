#!/usr/bin/env python3
"""FastNet is the first complete application in the direct apps tree."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
APP = ROOT / "apps/fastnet"

subprocess.run([sys.executable, "-B", str(ROOT / "scripts/build.py"), "--check"], check=True)
manifest = json.loads((APP / "app.json").read_text())
assert manifest == {
    "schema_version": 1,
    "id": "fastnet",
    "name": "FastNet",
    "version": "0.1.9",
    "min_zsetup": "0.5.0",
    "entrypoints": ["sh"],
    "targets": [{
        "os": ["*"], "package_manager": ["*"],
        "arch": ["x86_64", "aarch64", "armv7"],
    }],
    "compatibility_aliases": ["fastnet-install.sh"],
}
payload = APP / "0.1.9/installer.sh"
assert payload.read_bytes() == (ROOT / "fastnet/fastnet-install.sh").read_bytes()
for source in ("business.sh", "main.sh", "README.md"):
    assert (APP / source).read_bytes() == (ROOT / "fastnet" / source).read_bytes()
assert (APP / "install.sh").read_bytes() == (APP / "fastnet-install.sh").read_bytes()
assert not (APP / "tests").exists()

config = json.loads((ROOT / "apps/zsetup/config.json").read_text())
records = [record for record in config["installers"] if record["application"] == "fastnet"]
assert len(records) == 3
assert {record["arch"] for record in records} == {"x86_64", "aarch64", "armv7"}
assert {record["path"] for record in records} == {"fastnet/0.1.9/installer.sh"}
assert {record["sha256"] for record in records} == {hashlib.sha256(payload.read_bytes()).hexdigest()}
assert {record["size"] for record in records} == {payload.stat().st_size}
assert {record["min_version"] for record in records} == {"0.6.4"}
assert "fastnet" in {record["application"] for record in config["installers"]}

print("FastNet apps migration: public source, standard entry, immutable payload and config passed")

