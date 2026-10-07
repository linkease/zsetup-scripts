#!/usr/bin/env python3
"""Release package/index byte identity, immutability and repeatability."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ZROOT = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="scripts-package-") as tmp:
    output = Path(tmp) / "release"
    argv = ["python3", "-B", str(ROOT / "scripts/package-release.py"), "--zsetup-root", str(ZROOT), "--output", str(output)]
    subprocess.run(argv, check=True)
    binary = output / "binary"
    config = json.loads((binary / "zsetup/config.json").read_text())
    assert config["stable_zsetup"]["version"] == "0.2.3"
    assert {r["application"] for r in config["installers"]} == {"fastnet", "ddnsto"}
    assert not any(r["application"] == "fastpve" for r in config["installers"])
    for record in config["installers"] + config["stable_zsetup"]["artifacts"]:
        path = binary / record["path"]
        assert path.is_file()
        assert path.stat().st_size == record["size"]
        assert hashlib.sha256(path.read_bytes()).hexdigest() == record["sha256"]
    for app in ("fastnet", "ddnsto"):
        record = next(r for r in config["installers"] if r["application"] == app)
        catalog_record = next(r for r in json.loads((ROOT / "catalog.json").read_text())["installers"] if r["application"] == app)
        assert record["path"] == catalog_record["path"]
        assert len(record["path"].split("/")) == 3 and record["path"].split("/")[1] not in {"stable", "latest"}
        assert (binary / record["path"]).read_bytes() == (binary / app / "install.sh").read_bytes()
    def select(app, os_name, pm, arch):
        matches = [r for r in config["installers"] if r["application"] == app and all(r[k] in ("*", v) for k,v in (("os", os_name), ("package_manager", pm), ("arch", arch)))]
        assert len(matches) == 1, (app, os_name, pm, arch, matches)
    for pm in ("opkg", "apk"):
        for arch in ("x86_64", "aarch64", "armv7", "mipsel"):
            select("ddnsto", "openwrt", pm, arch)
    for os_name, pm in (("ubuntu", "apt"), ("debian", "apt"), ("centos", "yum"), ("rhel", "dnf")):
        for arch in ("x86_64", "aarch64"):
            select("ddnsto", os_name, pm, arch)
    assert not any(r["application"] == "fastnet" and r["arch"] in ("mipsel", "*") for r in config["installers"])
    subprocess.run(["sha256sum", "-c", "PACKAGE-SHA256SUMS"], cwd=output, check=True, stdout=subprocess.DEVNULL)
    env = __import__("os").environ | {"ZSETUP_CONFIG": str(binary / "zsetup/config.json")}
    listed = subprocess.run([str(ZROOT / "dist/release/zsetup-linux-x86_64"), "install", "--list"], env=env, text=True, capture_output=True, check=True)
    assert set(listed.stdout.splitlines()) == {"fastnet", "ddnsto"}
    archive = next(output.glob("*.tar.gz"))
    first = archive.read_bytes()
    subprocess.run(argv, check=True, stdout=subprocess.DEVNULL)
    assert next(output.glob("*.tar.gz")).read_bytes() == first
    # A changed immutable path is rejected before any config or stable pointer update.
    immutable = binary / config["installers"][0]["path"]
    immutable.write_text("corrupt immutable version")
    config_before = (binary / "zsetup/config.json").read_bytes()
    bad = subprocess.run(argv, capture_output=True)
    assert bad.returncode != 0
    assert immutable.read_text() == "corrupt immutable version"
    assert (binary / "zsetup/config.json").read_bytes() == config_before
    assert not list(output.parent.glob(".release-*"))
print("Unified release: config, platform records, SHA256, aliases, reproducibility and immutability passed")
