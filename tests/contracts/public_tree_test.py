#!/usr/bin/env python3
"""The apps tree is a byte-for-byte public tree with no private/test material."""

import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
CHECK = ROOT / "scripts/check-public-tree.py"


def run(tree: Path):
    return subprocess.run(
        [sys.executable, "-B", str(CHECK), str(tree)],
        text=True,
        capture_output=True,
    )


def valid_tree(root: Path):
    app = root / "demo" / "0.1.0"
    app.mkdir(parents=True)
    (root / "demo/app.json").write_text('{"schema_version":1,"id":"demo"}\n')
    (root / "demo/install.sh").write_text("#!/bin/sh\nexit 0\n")
    (app / "installer.sh").write_text("#!/bin/sh\nexit 0\n")


with tempfile.TemporaryDirectory(prefix="apps-public-tree-") as name:
    base = Path(name)
    good = base / "apps"
    valid_tree(good)
    result = run(good)
    assert result.returncode == 0, result.stderr

    copied = base / "public"
    shutil.copytree(good, copied)
    assert {
        p.relative_to(good): p.read_bytes()
        for p in good.rglob("*") if p.is_file()
    } == {
        p.relative_to(copied): p.read_bytes()
        for p in copied.rglob("*") if p.is_file()
    }

    cases = {
        "tests/case.sh": "test directory",
        "demo/fixtures/input": "fixture directory",
        "demo/.env": "private or transient file",
        "demo/id_rsa": "private or transient file",
        "demo/private.key": "private or transient file",
        "demo/run.log": "private or transient file",
        "demo/__pycache__/x.pyc": "private or transient file",
        "Bad_Name/app.json": "unsafe public path",
    }
    for relative, expected in cases.items():
        tree = base / ("case-" + relative.replace("/", "-"))
        valid_tree(tree)
        target = tree / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("forbidden\n")
        result = run(tree)
        assert result.returncode != 0, relative
        assert expected in result.stderr, (relative, result.stderr)

    link_tree = base / "link"
    valid_tree(link_tree)
    (link_tree / "demo/outside").symlink_to(base)
    result = run(link_tree)
    assert result.returncode != 0
    assert "symbolic link" in result.stderr

    if hasattr(os, "mkfifo"):
        fifo_tree = base / "fifo"
        valid_tree(fifo_tree)
        os.mkfifo(fifo_tree / "demo/pipe")
        result = run(fifo_tree)
        assert result.returncode != 0
        assert "special file" in result.stderr

    production_tree = base / "connection"
    valid_tree(production_tree)
    (production_tree / "demo/server.txt").write_text(
        "ssh_target=root@192.168.3.1\ndeploy_base=/mnt/private/public_html\n"
    )
    result = run(production_tree)
    assert result.returncode != 0
    assert "production connection data" in result.stderr

print("Public apps tree: copy identity and forbidden-material boundaries passed")

