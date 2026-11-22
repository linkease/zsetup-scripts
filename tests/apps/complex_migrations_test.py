#!/usr/bin/env python3
"""Complex and cross-platform applications complete the M0 inventory."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
EXPECTED = {
    "ddnsto": {"version": "0.2.4", "entrypoints": ["sh"], "linux": 22, "windows": 0},
    "linkease": {"version": "0.1.9", "entrypoints": ["sh"], "linux": 24, "windows": 0},
    "jq": {"version": "0.1.0", "entrypoints": ["sh", "ps1"], "linux": 22, "windows": 3},
    "kai-skills": {"version": "1.2.6", "entrypoints": ["sh", "ps1"], "linux": 2, "windows": 1},
    "scoop": {"version": "0.1.2", "entrypoints": ["ps1"], "linux": 0, "windows": 1},
}

subprocess.run([sys.executable, "-B", str(ROOT / "scripts/build.py"), "--check"], check=True)
linux = json.loads((ROOT / "apps/zsetup/config.json").read_text())
windows = json.loads((ROOT / "apps/zsetup/config-windows.json").read_text())
for app_id, expected in EXPECTED.items():
    app = ROOT / "apps" / app_id
    manifest = json.loads((app / "app.json").read_text())
    assert manifest["version"] == expected["version"]
    for extension in ("sh", "ps1"):
        if extension not in expected["entrypoints"]:
            continue
        payload = app / expected["version"] / f"installer.{extension}"
        assert payload.is_file() and not payload.is_symlink()
        assert (app / f"install.{extension}").is_file()
        assert (app / f"{app_id}-install.{extension}").read_bytes() == (app / f"install.{extension}").read_bytes()
    assert not (app / "tests").exists()
    linux_records = [record for record in linux["installers"] if record["application"] == app_id]
    windows_records = [record for record in windows["installers"] if record["application"] == app_id]
    assert len(linux_records) == expected["linux"]
    assert len(windows_records) == expected["windows"]
    assert all(record["path"].startswith(
        f"zsetup-scripts/apps/{app_id}/{expected['version']}/installer.")
        for record in linux_records + windows_records)

assert len(linux["installers"]) == 129
assert len(windows["installers"]) == 9
assert {path.parent.name for path in (ROOT / "apps").glob("*/app.json")} == {
    "ddnsto", "fastnet", "fastpve", "jq", "kai-skills", "ks-cli", "kspeeder",
    "linkease", "linkspace", "scoop",
}

print("Complex apps migration: all ten applications and 138 platform records passed")

