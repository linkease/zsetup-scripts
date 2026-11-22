#!/usr/bin/env python3
"""Windows applications get a deterministic PowerShell bootstrap and config."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / "scripts/build.py"


def base(version, group, artifact, arch):
    return {
        "schema_version": 1,
        "source_groups": [{"id": group, "primary_bases": ["https://one.invalid/binary"],
                           "fallback_base": "https://fallback.invalid/binary"}],
        "stable_zsetup": {"version": version, "source_group": group,
                          "artifacts": [{"arch": arch, "path": f"zsetup/{version}/{artifact}",
                                         "sha256": "4" * 64, "size": 123}]},
    }


with tempfile.TemporaryDirectory(prefix="apps-powershell-") as name:
    apps = Path(name) / "apps"
    app = apps / "windows-demo"
    (app / "1.0.0").mkdir(parents=True)
    (app / "1.0.0/installer.ps1").write_text("exit 0\n")
    (app / "app.json").write_text(json.dumps({
        "schema_version": 1, "id": "windows-demo", "name": "Windows Demo",
        "version": "1.0.0", "min_zsetup": "0.6.4", "entrypoints": ["ps1"],
        "targets": [{"os": ["windows"], "package_manager": ["*"], "arch": ["x86_64"]}],
        "compatibility_aliases": ["windows-demo-install.ps1"],
    }) + "\n")
    (apps / "zsetup").mkdir()
    (apps / "zsetup/base.json").write_text(json.dumps(base(
        "0.6.4", "koolcenter", "zsetup-linux-x86_64", "x86_64")) + "\n")
    (apps / "zsetup/base-windows.json").write_text(json.dumps(base(
        "0.6.5", "release", "zsetup-windows-i686.exe", "i686")) + "\n")
    command = [sys.executable, "-B", str(BUILD), "--apps", str(apps)]
    built = subprocess.run(command, text=True, capture_output=True)
    assert built.returncode == 0, built.stderr
    entry = app / "install.ps1"
    alias = app / "windows-demo-install.ps1"
    assert entry.read_bytes().startswith(b"\xef\xbb\xbf"), "PowerShell 5.1 entry must use UTF-8 BOM"
    assert alias.read_bytes() == entry.read_bytes()
    text = entry.read_text(encoding="utf-8-sig")
    assert "$AppId = 'windows-demo'" in text
    assert "& $active install $AppId --foreground -- @InstallerArguments" in text
    assert "exit $LASTEXITCODE" in text
    config = json.loads((apps / "zsetup/config-windows.json").read_text())
    assert len(config["installers"]) == 1
    record = config["installers"][0]
    assert record["path"] == "windows-demo/1.0.0/installer.ps1"
    assert record["min_version"] == "0.6.5" and record["source_group"] == "release"
    assert json.loads((apps / "zsetup/config.json").read_text())["installers"] == []
    subprocess.run(command + ["--check"], check=True, stdout=subprocess.DEVNULL)

print("PowerShell entry: BOM, bootstrap command, alias and Windows config passed")

