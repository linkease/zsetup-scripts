#!/usr/bin/env python3
"""Application manifests generate deterministic, non-recursive zsetup config."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / "scripts/build.py"


BASE = {
    "schema_version": 1,
    "public_path_prefix": "zsetup-scripts/apps",
    "source_groups": [{
        "id": "koolcenter",
        "primary_bases": ["https://one.invalid/binary"],
        "fallback_base": "https://fallback.invalid/binary",
    }],
    "stable_zsetup": {
        "version": "0.6.4",
        "source_group": "koolcenter",
        "artifacts": [{
            "arch": "x86_64", "path": "zsetup/0.6.4/zsetup-linux-x86_64",
            "sha256": "1" * 64, "size": 123,
        }],
    },
}


def create(apps: Path):
    app = apps / "demo"
    (app / "versions/1.2.3").mkdir(parents=True)
    payload = b"#!/bin/sh\nexit 0\n"
    (app / "versions/1.2.3/install.sh").write_bytes(payload)
    (app / "install.md").write_text("# Demo installation\n")
    (app / "app.json").write_text(json.dumps({
        "schema_version": 2, "id": "demo", "name": "Demo",
        "version": "1.2.3", "min_zsetup": "0.5.0",
        "entrypoints": {"posix": "install.sh"},
        "targets": [{
            "os": ["linux", "openwrt"], "package_manager": ["*"],
            "arch": ["x86_64", "aarch64"],
        }],
    }) + "\n")
    (apps / "zsetup").mkdir()
    (apps / "zsetup/base.json").write_text(json.dumps(BASE) + "\n")
    return payload


with tempfile.TemporaryDirectory(prefix="apps-config-") as name:
    apps = Path(name) / "apps"
    payload = create(apps)
    command = [sys.executable, "-B", str(BUILD), "--apps", str(apps)]
    result = subprocess.run(command, text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    config_path = apps / "zsetup/config.json"
    config = json.loads(config_path.read_text())
    assert set(config) == {"schema_version", "config_version", "source_groups", "stable_zsetup", "installers"}
    assert config["schema_version"] == 1
    assert config["source_groups"] == BASE["source_groups"]
    assert config["stable_zsetup"] == BASE["stable_zsetup"]
    assert len(config["installers"]) == 4
    expected_sha = hashlib.sha256(payload).hexdigest()
    assert config["installers"][0] == {
        "application": "demo", "os": "linux", "package_manager": "*", "arch": "aarch64",
        "path": "zsetup-scripts/apps/demo/versions/1.2.3/install.sh", "background": False,
        "source_group": "koolcenter", "sha256": expected_sha,
        "size": len(payload), "min_version": "0.5.0",
    }
    assert all(record["path"] != "demo/install.sh" for record in config["installers"])
    first = config_path.read_bytes()
    subprocess.run(command, check=True, stdout=subprocess.DEVNULL)
    assert config_path.read_bytes() == first
    checked = subprocess.run(command + ["--check"], text=True, capture_output=True)
    assert checked.returncode == 0, checked.stderr
    config_path.write_text("{}\n")
    stale = subprocess.run(command + ["--check"], text=True, capture_output=True)
    assert stale.returncode != 0 and "stale zsetup config" in stale.stderr

    # A runtime below the declared capability floor cannot publish the app.
    data = json.loads((apps / "demo/app.json").read_text())
    data["min_zsetup"] = "0.7.0"
    (apps / "demo/app.json").write_text(json.dumps(data) + "\n")
    blocked = subprocess.run(command, text=True, capture_output=True)
    assert blocked.returncode != 0 and "requires zsetup" in blocked.stderr

print("Zsetup config: deterministic selectors, immutable payload identity and runtime floor passed")

