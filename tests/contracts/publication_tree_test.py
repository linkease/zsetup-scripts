#!/usr/bin/env python3
"""The apps directory alone scales and copies as a complete release tree."""

import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / "scripts/build.py"
PUBLIC_CHECK = ROOT / "scripts/check-public-tree.py"


BASE = {
    "schema_version": 1,
    "source_groups": [{
        "id": "koolcenter", "primary_bases": ["https://one.invalid/binary"],
        "fallback_base": "https://fallback.invalid/binary",
    }],
    "stable_zsetup": {
        "version": "0.6.4", "source_group": "koolcenter",
        "artifacts": [{"arch": "x86_64", "path": "zsetup/0.6.4/zsetup-linux-x86_64",
                       "sha256": "2" * 64, "size": 123}],
    },
}


def make_tree(apps: Path, count: int):
    (apps / "zsetup").mkdir(parents=True)
    (apps / "zsetup/base.json").write_text(json.dumps(BASE) + "\n")
    (apps / "README.md").write_text("public tree\n")
    for number in range(count):
        app_id = f"app-{number:03d}"
        app = apps / app_id
        (app / "1.0.0").mkdir(parents=True)
        (app / "1.0.0/installer.sh").write_text(f"#!/bin/sh\nprintf '%s\\n' '{app_id}'\n")
        (app / "app.json").write_text(json.dumps({
            "schema_version": 1, "id": app_id, "name": app_id,
            "version": "1.0.0", "min_zsetup": "0.5.0", "entrypoints": ["sh"],
            "targets": [{"os": ["linux"], "package_manager": ["*"], "arch": ["x86_64"]}],
            "compatibility_aliases": [],
        }) + "\n")


def bytes_by_path(root: Path):
    return {path.relative_to(root): path.read_bytes() for path in root.rglob("*") if path.is_file()}


with tempfile.TemporaryDirectory(prefix="apps-publication-") as name:
    work = Path(name)
    apps = work / "apps"
    make_tree(apps, 100)
    command = [sys.executable, "-B", str(BUILD), "--apps", str(apps)]
    subprocess.run(command, check=True, stdout=subprocess.DEVNULL)
    subprocess.run([sys.executable, "-B", str(PUBLIC_CHECK), str(apps)], check=True,
                   stdout=subprocess.DEVNULL)
    subprocess.run(["sha256sum", "-c", "SHA256SUMS"], cwd=apps, check=True,
                   stdout=subprocess.DEVNULL)
    config = json.loads((apps / "zsetup/config.json").read_text())
    assert len(config["installers"]) == 100
    assert len(list(apps.glob("app-*/install.sh"))) == 100

    first = bytes_by_path(apps)
    subprocess.run(command, check=True, stdout=subprocess.DEVNULL)
    assert bytes_by_path(apps) == first
    subprocess.run(command + ["--check"], check=True, stdout=subprocess.DEVNULL)

    public = work / "binary"
    public.mkdir()
    existing = public / "fastnet/FastNet-product.bin"
    existing.parent.mkdir()
    existing.write_bytes(b"server-owned product")
    shutil.copytree(apps, public, dirs_exist_ok=True)
    assert existing.read_bytes() == b"server-owned product"
    assert all((public / relative).read_bytes() == content for relative, content in first.items())
    assert not list(public.rglob("tests")) and not list(public.rglob("fixtures"))

    target = apps / "app-000/1.0.0/installer.sh"
    target.write_text("tampered\n")
    failed = subprocess.run(["sha256sum", "-c", "SHA256SUMS"], cwd=apps,
                            text=True, capture_output=True)
    assert failed.returncode != 0

print("Publication tree: 100-app generation, checksums, copy identity and no-delete preservation passed")

