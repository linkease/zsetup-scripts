#!/usr/bin/env python3
"""Application manifests are the single safe registration source."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / "scripts/build.py"


def manifest(app="demo"):
    return {
        "schema_version": 1,
        "id": app,
        "name": "Demo",
        "version": "1.2.3",
        "min_zsetup": "0.6.4",
        "entrypoints": ["sh"],
        "targets": [{
            "os": ["linux"],
            "package_manager": ["*"],
            "arch": ["x86_64", "aarch64"],
        }],
        "compatibility_aliases": [f"{app}-install.sh"],
    }


def write_tree(root: Path, data, directory="demo"):
    app = root / directory
    (app / "1.2.3").mkdir(parents=True)
    (app / "app.json").write_text(json.dumps(data) + "\n")
    (app / "1.2.3/installer.sh").write_text("#!/bin/sh\nexit 0\n")


def run(root: Path):
    return subprocess.run(
        [sys.executable, "-B", str(BUILD), "--apps", str(root), "--validate-only"],
        text=True,
        capture_output=True,
    )


with tempfile.TemporaryDirectory(prefix="apps-manifest-") as name:
    base = Path(name)
    valid = base / "valid"
    write_tree(valid, manifest())
    result = run(valid)
    assert result.returncode == 0, result.stderr

    invalid = []
    changed = manifest(); changed["schema_version"] = 2
    invalid.append(("schema", changed, "demo", "schema_version"))
    changed = manifest("other")
    invalid.append(("identity", changed, "demo", "must equal directory"))
    changed = manifest(); changed["version"] = "latest"
    invalid.append(("version", changed, "demo", "version"))
    changed = manifest(); changed["min_zsetup"] = "0.6"
    invalid.append(("runtime", changed, "demo", "min_zsetup"))
    changed = manifest(); changed["entrypoints"] = ["python"]
    invalid.append(("entrypoint", changed, "demo", "entrypoints"))
    changed = manifest(); changed["compatibility_aliases"] = ["../install.sh"]
    invalid.append(("alias", changed, "demo", "compatibility alias"))
    changed = manifest(); changed["targets"][0]["arch"] = ["x86_64", "x86_64"]
    invalid.append(("duplicate-value", changed, "demo", "duplicate"))
    changed = manifest(); changed["targets"].append(dict(changed["targets"][0]))
    invalid.append(("duplicate-target", changed, "demo", "duplicate target"))
    changed = manifest(); changed["entrypoints"] = ["ps1"]; changed["compatibility_aliases"] = []
    changed["targets"][0]["os"] = ["windows"]
    invalid.append(("missing-payload", changed, "demo", "installer.ps1"))

    for label, data, directory, expected in invalid:
        tree = base / label
        write_tree(tree, data, directory)
        result = run(tree)
        assert result.returncode != 0, label
        assert expected in result.stderr, (label, result.stderr)

    duplicate = base / "duplicate"
    write_tree(duplicate, manifest("first"), "first")
    write_tree(duplicate, manifest("first"), "second")
    result = run(duplicate)
    assert result.returncode != 0

print("Application manifest: identity, version, entrypoint, target and payload contracts passed")

