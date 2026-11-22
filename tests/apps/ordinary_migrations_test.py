#!/usr/bin/env python3
"""Ordinary POSIX applications preserve payload behavior in the apps tree."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
EXPECTED = {
    "fastpve": {
        "version": "0.1.9", "count": 1,
        "targets": [("debian", "apt", "x86_64")],
    },
    "linkspace": {
        "version": "0.1.1", "count": 21,
        "os": {"asuswrt", "centos", "debian", "linux", "openwrt", "rhel", "ubuntu"},
        "arch": {"x86_64", "aarch64", "armv7"},
    },
    "ks-cli": {
        "version": "0.1.2", "count": 17,
        "os": {"centos", "debian", "linux", "macos", "rhel", "ubuntu"},
        "arch": {"x86_64", "aarch64", "armv7"},
    },
    "kspeeder": {
        "version": "0.1.2", "count": 17,
        "os": {"centos", "debian", "linux", "macos", "rhel", "ubuntu"},
        "arch": {"x86_64", "aarch64", "armv7"},
    },
}

subprocess.run([sys.executable, "-B", str(ROOT / "scripts/build.py"), "--check"], check=True)
config = json.loads((ROOT / "apps/zsetup/config.json").read_text())
for app_id, expected in EXPECTED.items():
    app = ROOT / "apps" / app_id
    manifest = json.loads((app / "app.json").read_text())
    assert manifest["id"] == app_id and manifest["version"] == expected["version"]
    payload = app / expected["version"] / "installer.sh"
    assert payload.is_file() and not payload.is_symlink()
    assert (app / "install.sh").read_bytes() == (app / f"{app_id}-install.sh").read_bytes()
    assert not (app / "tests").exists()
    records = [record for record in config["installers"] if record["application"] == app_id]
    assert len(records) == expected["count"]
    assert {record["path"] for record in records} == {
        f"zsetup-scripts/apps/{app_id}/{expected['version']}/installer.sh"
    }
    assert {record["sha256"] for record in records} == {hashlib.sha256(payload.read_bytes()).hexdigest()}
    if "targets" in expected:
        assert {(record["os"], record["package_manager"], record["arch"]) for record in records} == set(expected["targets"])
    else:
        assert {record["os"] for record in records} == expected["os"]
        assert {record["arch"] for record in records} == expected["arch"]
        assert {record["package_manager"] for record in records} == {"*"}

ordinary_ids = {"fastnet", "fastpve", "linkspace", "ks-cli", "kspeeder"}
ordinary_records = [record for record in config["installers"]
                    if record["application"] in ordinary_ids]
assert {record["application"] for record in ordinary_records} == ordinary_ids
assert len(ordinary_records) == 59
print("Ordinary apps migration: source identity, standard aliases and 59 runtime records passed")

