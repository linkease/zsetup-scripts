#!/usr/bin/env python3
"""Direct apps publication stages, activates, verifies and rolls back safely."""

import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / "scripts/build.py"
PUBLISH = ROOT / "scripts/publish.sh"


BASE = {
    "schema_version": 1,
    "public_path_prefix": "zsetup-scripts/apps",
    "source_groups": [{"id": "koolcenter", "primary_bases": ["https://one.invalid/binary"],
                       "fallback_base": "https://fallback.invalid/binary"}],
    "stable_zsetup": {"version": "0.6.4", "source_group": "koolcenter",
                      "artifacts": [{"arch": "x86_64", "path": "zsetup/0.6.4/zsetup-linux-x86_64",
                                     "sha256": "3" * 64, "size": 123}]},
}


def make_apps(root: Path):
    (root / "zsetup").mkdir(parents=True)
    (root / "zsetup/base.json").write_text(json.dumps(BASE) + "\n")
    app = root / "demo"
    (app / "1.0.0").mkdir(parents=True)
    installer = app / "1.0.0/installer.sh"
    installer.write_text("#!/bin/sh\nprintf 'new payload\\n'\n")
    installer.chmod(0o775)
    (app / "app.json").write_text(json.dumps({
        "schema_version": 1, "id": "demo", "name": "Demo", "version": "1.0.0",
        "min_zsetup": "0.5.0", "entrypoints": ["sh"],
        "targets": [{"os": ["linux"], "package_manager": ["*"], "arch": ["x86_64"]}],
        "compatibility_aliases": ["demo-install.sh"],
    }) + "\n")
    subprocess.run([sys.executable, "-B", str(BUILD), "--apps", str(root)], check=True,
                   stdout=subprocess.DEVNULL)


def make_live(root: Path):
    (root / "zsetup").mkdir(parents=True)
    (root / "zsetup/config.json").write_bytes(b"old config\n")
    (root / "demo").mkdir()
    (root / "demo/install.sh").write_bytes(b"old entry\n")
    (root / "products").mkdir()
    (root / "products/product.bin").write_bytes(b"server-owned")
    (root / "SHA256SUMS").write_bytes(b"old manifest\n")


def run(mode, apps, live, extra=None):
    environment = os.environ.copy()
    environment["ZSETUP_PUBLISH_ALLOW_UNVERSIONED"] = "1"
    if extra:
        environment.update(extra)
    return subprocess.run(["sh", str(PUBLISH), mode, str(apps), str(live)],
                          env=environment, text=True, capture_output=True)


def run_prevalidated(mode, apps, live, release_id):
    environment = os.environ.copy()
    environment.pop("ZSETUP_PUBLISH_ALLOW_UNVERSIONED", None)
    environment.update({
        "ZSETUP_PUBLISH_PREVALIDATED_RELEASE_ID": release_id,
        "ZSETUP_PUBLISH_PYTHON": "/python-is-intentionally-unavailable",
    })
    return subprocess.run(["sh", str(PUBLISH), mode, str(apps), str(live)],
                          env=environment, text=True, capture_output=True)


with tempfile.TemporaryDirectory(prefix="apps-publish-") as name:
    work = Path(name)
    apps = work / "apps"; make_apps(apps)
    release_id = hashlib.sha256((apps / "SHA256SUMS").read_bytes()).hexdigest()
    live = work / "binary"; make_live(live)

    staged = run("stage", apps, live)
    assert staged.returncode == 0, staged.stderr
    assert (live / "demo/1.0.0/installer.sh").read_bytes() == (apps / "demo/1.0.0/installer.sh").read_bytes()
    assert not ((live / "demo/1.0.0/installer.sh").stat().st_mode & (stat.S_IWGRP | stat.S_IWOTH))
    assert (live / "demo/install.sh").read_bytes() == b"old entry\n"
    assert (live / "SHA256SUMS").read_bytes() == b"old manifest\n"
    snapshot = live / f"zsetup/.apps-rollback-{release_id}"
    assert (snapshot / "phase").read_text().strip() == "staged"
    assert run("stage", apps, live).returncode != 0

    active = run("activate", apps, live)
    assert active.returncode == 0, active.stderr
    assert (snapshot / "phase").read_text().strip() == "activated"
    assert (live / "demo/install.sh").read_bytes() == (apps / "demo/install.sh").read_bytes()
    assert (live / "SHA256SUMS").read_bytes() == (apps / "SHA256SUMS").read_bytes()
    assert not ((live / "demo/install.sh").stat().st_mode & (stat.S_IWGRP | stat.S_IWOTH))
    assert (live / "zsetup/config.json").read_bytes() == (apps / "zsetup/config.json").read_bytes()
    assert (live / "products/product.bin").read_bytes() == b"server-owned"
    verified = run("verify", apps, live)
    assert verified.returncode == 0, verified.stderr

    rolled = run("rollback", apps, live)
    assert rolled.returncode == 0, rolled.stderr
    assert (live / "demo/install.sh").read_bytes() == b"old entry\n"
    assert (live / "SHA256SUMS").read_bytes() == b"old manifest\n"
    assert (live / "zsetup/config.json").read_bytes() == b"old config\n"
    assert (live / "demo/1.0.0/installer.sh").is_file(), "immutable version must remain"
    assert (live / "products/product.bin").read_bytes() == b"server-owned"

    conflict = work / "conflict"; make_live(conflict)
    (conflict / "demo/1.0.0").mkdir(parents=True)
    (conflict / "demo/1.0.0/installer.sh").write_bytes(b"different immutable bytes\n")
    before = (conflict / "zsetup/config.json").read_bytes()
    assert run("stage", apps, conflict).returncode != 0
    assert (conflict / "zsetup/config.json").read_bytes() == before

    failed = work / "failed"; make_live(failed)
    assert run("stage", apps, failed).returncode == 0
    injected = run("activate", apps, failed, {"ZSETUP_PUBLISH_FAIL_AFTER": "2"})
    assert injected.returncode != 0
    assert (failed / "demo/install.sh").read_bytes() == b"old entry\n"
    assert (failed / "zsetup/config.json").read_bytes() == b"old config\n"

    changed = work / "changed"; make_live(changed)
    assert run("stage", apps, changed).returncode == 0
    assert run("activate", apps, changed).returncode == 0
    (changed / "demo/install.sh").write_bytes(b"later release\n")
    rejected = run("rollback", apps, changed)
    assert rejected.returncode != 0 and "later publication" in rejected.stderr

    locked = work / "locked"; make_live(locked)
    (locked / "zsetup/.apps-publish-lock").mkdir()
    lock_result = run("stage", apps, locked)
    assert lock_result.returncode != 0 and "lock" in lock_result.stderr

    detached = work / "detached"; make_live(detached)
    wrong_id = run_prevalidated("stage", apps, detached, "0" * 64)
    assert wrong_id.returncode != 0 and "does not match" in wrong_id.stderr
    staged_detached = run_prevalidated("stage", apps, detached, release_id)
    assert staged_detached.returncode == 0, staged_detached.stderr
    active_detached = run_prevalidated("activate", apps, detached, release_id)
    assert active_detached.returncode == 0, active_detached.stderr
    verified_detached = run_prevalidated("verify", apps, detached, release_id)
    assert verified_detached.returncode == 0, verified_detached.stderr

print("Publish transaction: stage, activate, verify, rollback, failure recovery, protection and detached release passed")

