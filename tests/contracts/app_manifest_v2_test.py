#!/usr/bin/env python3
"""Layout v2 exposes only fixed cross-platform entries and version installers."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / "scripts/build.py"


def manifest():
    return {
        "schema_version": 2,
        "id": "demo",
        "name": "Demo",
        "version": "1.2.3",
        "min_zsetup": "0.6.4",
        "entrypoints": {"posix": "install.sh", "windows": "install.ps1"},
        "targets": [
            {"os": ["linux", "macos"], "package_manager": ["*"], "arch": ["x86_64"]},
            {"os": ["windows"], "package_manager": ["*"], "arch": ["x86_64"]},
        ],
    }


def write_tree(root: Path, data):
    app = root / "demo"
    version = app / "versions/1.2.3"
    version.mkdir(parents=True)
    (app / "app.json").write_text(json.dumps(data) + "\n")
    for name in ("install.sh", "install.ps1"):
        (app / name).write_text("entry\n")
        (version / name).write_text("payload\n")


def run(root: Path):
    return subprocess.run(
        [sys.executable, "-B", str(BUILD), "--apps", str(root), "--validate-only"],
        text=True, capture_output=True,
    )


with tempfile.TemporaryDirectory(prefix="apps-v2-") as name:
    base = Path(name)
    valid = base / "valid"
    write_tree(valid, manifest())
    result = run(valid)
    assert result.returncode == 0, result.stderr

    alias = base / "alias"
    data = manifest()
    data["compatibility_aliases"] = ["demo-install.sh"]
    write_tree(alias, data)
    result = run(alias)
    assert result.returncode != 0 and "fields differ" in result.stderr

    renamed = base / "renamed"
    data = manifest()
    data["entrypoints"]["posix"] = "install-macos.sh"
    write_tree(renamed, data)
    result = run(renamed)
    assert result.returncode != 0 and "filenames are fixed" in result.stderr

    cluttered = base / "cluttered"
    write_tree(cluttered, manifest())
    (cluttered / "demo/i").write_text("short name\n")
    result = run(cluttered)
    assert result.returncode != 0 and "root must contain only" in result.stderr

    missing = base / "missing"
    write_tree(missing, manifest())
    (missing / "demo/versions/1.2.3/install.ps1").unlink()
    result = run(missing)
    assert result.returncode != 0 and "missing v2 payload" in result.stderr

print("Application manifest v2: fixed entries, clean root and version payloads passed")
