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
RELEASE = Path(sys.argv[2]).resolve() if len(sys.argv)>2 else ZROOT / "dist/release"
IS_RUST = (ZROOT / "Cargo.toml").is_file()
RELEASE_MANIFEST = json.loads((RELEASE / "release-manifest.json").read_text())
EXPECTED_VERSION = RELEASE_MANIFEST["version"]
CATALOG = json.loads((ROOT / "catalog.json").read_text())
with tempfile.TemporaryDirectory(prefix="scripts-package-") as tmp:
    output = Path(tmp) / "release"
    argv = ["python3", "-B", str(ROOT / "scripts/package-release.py"), "--zsetup-root", str(ZROOT), "--output", str(output), "--zsetup-release", str(RELEASE)]
    subprocess.run(argv, check=True)
    binary = output / "binary"
    manifest = json.loads((output / "scripts-release-manifest.json").read_text())
    assert manifest["readiness"] == "server-artifacts-and-canary-unverified"
    assert manifest["business_artifacts"] == {"owner": "business-server-release", "included": False}
    assert not (output.parent / "ddnsto-artifacts").exists()
    assert not any(p.suffix in {".ipk", ".apk"} or p.suffix == ".gz" and p.relative_to(binary).parts[0] != "zsetup" for p in binary.rglob("*"))
    for relative in ("openwrt/install_ddnsto.sh", "openwrt/install_ddnsto_business.sh", "openwrt/setup_ddnsto.sh", "linux-binary/install_ddnsto_linux.sh"):
        assert (binary / "ddnsto" / relative).read_bytes() == (ROOT / "ddnsto/ddnsto-install.sh").read_bytes()
    for relative in ("install.ps1", "install-macos.sh"):
        assert (binary / "ddnsto" / relative).read_bytes() == (ROOT / "ddnsto" / relative).read_bytes()
    config = json.loads((binary / "zsetup/config.json").read_text())
    assert config["stable_zsetup"]["version"] == EXPECTED_VERSION
    if IS_RUST and RELEASE_MANIFEST.get("target") == "linux":
        assert {r["arch"] for r in config["stable_zsetup"]["artifacts"]} == {"x86_64", "aarch64", "armv7", "mipsel"}
        assert {p.name for p in (binary / "zsetup").iterdir()} == {EXPECTED_VERSION, "config.json", "stable"}
        assert not any("windows" in p.name or "macos" in p.name for p in (binary / "zsetup" / EXPECTED_VERSION).iterdir())
    assert {r["application"] for r in config["installers"]} == {"fastnet", "ddnsto", "linkease", "fastpve"}
    assert {p.name for p in binary.iterdir()} == {"fastnet", "ddnsto", "linkease", "fastpve", "zsetup"}
    assert not (binary / "legacy").exists()
    assert not any(p.name in {"business.sh", "main.sh", "README.md"} or p.suffix == ".py" for p in binary.rglob("*"))

    for record in config["installers"] + config["stable_zsetup"]["artifacts"]:
        path = binary / record["path"]
        assert path.is_file()
        assert path.stat().st_size == record["size"]
        assert hashlib.sha256(path.read_bytes()).hexdigest() == record["sha256"]
    for app in ("fastnet", "ddnsto", "linkease", "fastpve"):
        record = next(r for r in config["installers"] if r["application"] == app)
        catalog_record = next(r for r in json.loads((ROOT / "catalog.json").read_text())["installers"] if r["application"] == app)
        assert record["path"] == catalog_record["path"]
        assert len(record["path"].split("/")) == 3 and record["path"].split("/")[1] not in {"stable", "latest"}
        assert record["path"] == f"{app}/{CATALOG["config_version"].removeprefix("scripts-")}/{app}-install.sh"
        current = binary / app / f"{app}-install.sh"
        assert (binary / record["path"]).read_bytes() == current.read_bytes()
        # Historical public URL remains an identical compatibility copy.
        assert (binary / app / "install.sh").read_bytes() == current.read_bytes()
    def select(app, os_name, pm, arch):
        matches = [r for r in config["installers"] if r["application"] == app and all(r[k] in ("*", v) for k,v in (("os", os_name), ("package_manager", pm), ("arch", arch)))]
        assert len(matches) == 1, (app, os_name, pm, arch, matches)
    select("fastpve", "debian", "apt", "x86_64")
    pve_records = [r for r in config["installers"] if r["application"] == "fastpve"]
    assert len(pve_records) == 1
    assert (pve_records[0]["os"], pve_records[0]["package_manager"], pve_records[0]["arch"]) == ("debian", "apt", "x86_64")
    assert not any(p.name.startswith("FastPVE-") for p in binary.rglob("*")), "product binaries belong on servers"
    for pm in ("opkg", "apk"):
        for arch in ("x86_64", "aarch64", "armv7", "mipsel"):
            select("ddnsto", "openwrt", pm, arch)
    for os_name, pm in (("ubuntu", "apt"), ("debian", "apt"), ("centos", "yum"), ("rhel", "dnf")):
        for arch in ("x86_64", "aarch64"):
            select("ddnsto", os_name, pm, arch)
    for arch in ("x86_64", "aarch64", "armv7"):
        select("linkease", "openwrt", "opkg", arch)
        select("linkease", "ubuntu", "apt", arch)
    assert not any(r["application"] == "linkease" and (r["arch"] == "mipsel" or r["os"] == "openwrt" and r["package_manager"] == "apk") for r in config["installers"])
    assert not any(r["application"] == "fastnet" and r["arch"] in ("mipsel", "*") for r in config["installers"])
    subprocess.run(["sha256sum", "-c", "PACKAGE-SHA256SUMS"], cwd=output, check=True, stdout=subprocess.DEVNULL)
    env = __import__("os").environ | {"ZSETUP_CONFIG": str(binary / "zsetup/config.json")}
    listed = subprocess.run([str(RELEASE / "immutable/zsetup" / EXPECTED_VERSION / "zsetup-linux-x86_64" if IS_RUST else RELEASE / "zsetup-linux-x86_64"), "install", "--list"], env=env, text=True, capture_output=True, check=True)
    assert set(listed.stdout.splitlines()) == {"fastnet", "ddnsto", "linkease", "fastpve"}
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
    historical_named = binary / "ddnsto/0.0.9/ddnsto-install.sh"
    historical_named.write_bytes(b"historical named installer")
    historical_native = binary / "zsetup/0.0.9/zsetup-linux-x86_64"
    historical_native.parent.mkdir(parents=True)
    historical_native.write_bytes(b"historical immutable native")
    subprocess.run(argv, check=True, stdout=subprocess.DEVNULL)
    assert not stale.exists() and not pointer.exists()
    assert historical.read_bytes() == b"historical immutable installer"
    assert historical_named.read_bytes() == b"historical named installer"
    assert historical_native.read_bytes() == b"historical immutable native"
    assert (output / "scripts-release-manifest.json").is_file()
    with tarfile.open(next(output.glob("*.tar.gz"))) as archive:
        assert not any(name.endswith((".ipk", ".apk", ".tar.gz")) for name in archive.getnames())
        assert not any("legacy" in Path(name).parts for name in archive.getnames())
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
