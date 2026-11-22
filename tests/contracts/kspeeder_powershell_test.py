#!/usr/bin/env python3
"""KSpeeder Windows entries are generated, mirrored, checksummed and install-only."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[2]

subprocess.run([sys.executable, "-B", str(ROOT / "scripts/build.py"), "--check"], check=True)

config = json.loads((ROOT / "apps/zsetup/config-windows.json").read_text(encoding="utf-8"))
for app in ("ks-cli", "kspeeder"):
    manifest = json.loads((ROOT / "apps" / app / "app.json").read_text(encoding="utf-8"))
    payload = ROOT / "apps" / app / manifest["version"] / "installer.ps1"
    assert payload.read_bytes().startswith(b"\xef\xbb\xbf")
    assert (ROOT / "apps" / app / "install.ps1").read_bytes() == (
        ROOT / "apps" / app / f"{app}-install.ps1"
    ).read_bytes()
    records = [record for record in config["installers"] if record["application"] == app]
    assert len(records) == 2
    assert {record["arch"] for record in records} == {"x86_64", "aarch64"}
    assert {record["sha256"] for record in records} == {
        hashlib.sha256(payload.read_bytes()).hexdigest()
    }

policy = (ROOT / "apps/ks-cli/0.1.2/installer.ps1").read_text(encoding="utf-8-sig")
for required in (
    "ks-cli-win-$arch.exe",
    "iStoreEnhance-win.exe.$arch",
    "release.txt",
    "kspeeder/releases/$($release.Release)",
    "SHA256SUMS",
    "--sha256",
    "Test-KSpeederProduct",
):
    assert required in policy
for base in (
    "https://dl.istoreos.com/binary",
    "https://fw.d4ctech.com/binary",
    "https://fw20.koolcenter.com/binary",
    "https://fw.koolcenter.com/binary",
):
    assert base in policy
assert "https://kspeeder.com" not in policy
for forbidden in ("New-Service", "Start-Service", "schtasks.exe", "Register-ScheduledTask"):
    assert forbidden not in policy

print("KSpeeder PowerShell: generated identity, Windows targets, immutable mirror and install-only policy passed")
