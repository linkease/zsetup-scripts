#!/usr/bin/env python3
"""Approved DDNSTO bytes become complete, verifiable immutable release metadata."""
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]
ZROOT = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="ddnsto-artifact-package-") as tmp:
    folder = Path(tmp)
    source = folder / "approved-fixture"
    source.mkdir()
    files = {"openwrt/VERSION": b"4.2.3\n", "openwrt/VERSION_LITE": b"4.2.2\n"}
    for variant, version in (("lite", "4.2.2"), ("standard", "4.2.3")):
        for ext in ("ipk", "apk"):
            parent = f"openwrt/{variant}{'-apk' if ext == 'apk' else ''}/{version}"
            for name in ("ddnsto_x86_64", "ddnsto_aarch64", "ddnsto_arm", "ddnsto_mipsel", "luci-app-ddnsto", "luci-i18n-ddnsto-zh-cn"):
                files[f"{parent}/{name}.{ext}"] = f"isolated fixture {parent}/{name}".encode()
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode="w:gz") as archive:
        for arch in ("x86_64", "aarch64"):
            body = b"#!/bin/sh\necho fixture\n"
            member = tarfile.TarInfo(f"ddnsto-standard-4.2.3/ddnsto.{arch}")
            member.size = len(body); member.mode = 0o755
            archive.addfile(member, io.BytesIO(body))
    files["linux-binary/ddnsto-standard-4.2.3.tar.gz"] = stream.getvalue()
    inventory = {"schema_version": 1, "provenance": "ISOLATED TEST FIXTURE; NEVER PUBLISH", "files": []}
    for name, body in files.items():
        path = source / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(body)
        inventory["files"].append({"path": name, "sha256": hashlib.sha256(body).hexdigest()})
    (source / "artifacts.json").write_text(json.dumps(inventory))
    output = folder / "release"
    argv = ["python3", "-B", str(ROOT / "scripts/package-release.py"), "--zsetup-root", str(ZROOT), "--ddnsto-artifacts", str(source), "--output", str(output)]
    subprocess.run(argv, check=True)
    manifest = json.loads((output / "scripts-release-manifest.json").read_text())
    assert manifest["readiness"] == "artifacts-verified-canary-required"
    for sums in (output / "binary/ddnsto").rglob("SHA256SUMS"):
        subprocess.run(["sha256sum", "-c", sums.name], cwd=sums.parent, check=True, stdout=subprocess.DEVNULL)
    before = (output / "binary/zsetup/config.json").read_bytes()
    (source / "openwrt/standard/4.2.3/ddnsto_x86_64.ipk").write_bytes(b"corruption")
    bad = subprocess.run(argv, capture_output=True)
    assert bad.returncode != 0 and b"digest mismatch" in bad.stderr
    assert (output / "binary/zsetup/config.json").read_bytes() == before
    # Unsupported/missing approved platform bytes cannot silently reduce a claimed matrix.
    inventory["files"] = [r for r in inventory["files"] if r["path"] != "openwrt/standard/4.2.3/ddnsto_x86_64.ipk"]
    (source / "artifacts.json").write_text(json.dumps(inventory))
    missing = subprocess.run(argv, capture_output=True)
    assert missing.returncode != 0 and b"missing DDNSTO artifact" in missing.stderr
    assert not list(folder.glob(".release-*"))
print("DDNSTO artifact package: full matrix, approved digests, generated metadata and safe rejection passed")
