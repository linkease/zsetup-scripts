#!/usr/bin/env python3
"""Release package/index byte identity, immutability and repeatability."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import tarfile

ROOT = Path(__file__).resolve().parents[1]
ZROOT = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="scripts-package-") as tmp:
    output = Path(tmp) / "release"
    argv = ["python3", "-B", str(ROOT / "scripts/package-release.py"), "--zsetup-root", str(ZROOT), "--output", str(output)]
    subprocess.run(argv, check=True)
    binary = output / "binary"
    manifest = json.loads((output / "scripts-release-manifest.json").read_text())
    assert manifest["readiness"] == "server-artifacts-and-canary-unverified"
    assert manifest["business_artifacts"] == {"owner": "business-server-release", "included": False}
    assert not (output.parent / "ddnsto-artifacts").exists()
    assert not any(p.suffix in {".ipk", ".apk", ".gz"} for p in binary.rglob("*"))
    for relative in ("openwrt/install_ddnsto.sh", "openwrt/install_ddnsto_business.sh", "openwrt/setup_ddnsto.sh", "linux-binary/install_ddnsto_linux.sh"):
        assert (binary / "ddnsto" / relative).read_bytes() == (ROOT / "ddnsto/install.sh").read_bytes()
    config = json.loads((binary / "zsetup/config.json").read_text())
    assert config["stable_zsetup"]["version"] == "0.2.4"
    assert {r["application"] for r in config["installers"]} == {"fastnet", "ddnsto"}
    assert not any(r["application"] == "fastpve" for r in config["installers"])
    assert {p.name for p in binary.iterdir()} == {"fastnet", "ddnsto", "zsetup"}
    assert not any(p.name in {"business.sh", "main.sh", "README.md"} or p.suffix == ".py" for p in binary.rglob("*"))

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
    # A previous aggregate package must not pull server-owned products into this release.
    stale = binary / "ddnsto/openwrt/standard/4.2.6/ddnsto_x86_64.ipk"
    stale.parent.mkdir(parents=True, exist_ok=True)
    stale.write_bytes(b"previous locally bundled product")
    pointer = binary / "ddnsto/openwrt/VERSION"
    pointer.write_text("4.2.6\n")
    historical = binary / "ddnsto/0.0.9/install.sh"
    historical.parent.mkdir(parents=True)
    historical.write_bytes(b"historical immutable installer")
    historical_native = binary / "zsetup/0.0.9/zsetup-linux-x86_64"
    historical_native.parent.mkdir(parents=True)
    historical_native.write_bytes(b"historical immutable native")
    subprocess.run(argv, check=True, stdout=subprocess.DEVNULL)
    assert not stale.exists() and not pointer.exists()
    assert historical.read_bytes() == b"historical immutable installer"
    assert historical_native.read_bytes() == b"historical immutable native"
    assert (output / "scripts-release-manifest.json").is_file()
    with tarfile.open(next(output.glob("*.tar.gz"))) as archive:
        assert not any(name.endswith((".ipk", ".apk", ".tar.gz")) for name in archive.getnames())
    # A changed immutable path is rejected before any config or stable pointer update.
    immutable = binary / config["installers"][0]["path"]
    immutable.write_text("corrupt immutable version")
    config_before = (binary / "zsetup/config.json").read_bytes()
    bad = subprocess.run(argv, capture_output=True)
    assert bad.returncode != 0
    assert immutable.read_text() == "corrupt immutable version"
    assert (binary / "zsetup/config.json").read_bytes() == config_before
    assert not list(output.parent.glob(".release-*"))
print("Unified release: server-owned products excluded; config, SHA256, aliases, history, reproducibility and immutability passed")
