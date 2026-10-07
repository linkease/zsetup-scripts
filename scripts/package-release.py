#!/usr/bin/env python3
"""Build reviewable static release trees using the canonical zsetup generator/checker."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    with path.open("rb") as stream:
        value = hashlib.file_digest(stream, "sha256").hexdigest()
    return value


def git_commit(root):
    return subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()


def tree_dirty(root):
    return bool(subprocess.check_output(["git", "-C", str(root), "status", "--porcelain", "--", "."], text=True).strip())


def copy_immutable(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        if not destination.is_file() or digest(source) != digest(destination):
            raise ValueError(f"immutable path has different bytes: {destination}")
    else:
        shutil.copy2(source, destination)


def copy_ddnsto_artifacts(source, destination):
    """Require complete business-owned bytes plus an approved digest inventory."""
    inventory = json.loads((source / "artifacts.json").read_text())
    if set(inventory) != {"schema_version", "provenance", "files"} or inventory["schema_version"] != 1 or not inventory["provenance"]:
        raise ValueError("DDNSTO artifacts.json requires schema_version, provenance and files")
    approved = {}
    for record in inventory["files"]:
        if set(record) != {"path", "sha256"}:
            raise ValueError("invalid DDNSTO artifact record")
        name = record["path"]
        if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9_./+-]+", name) or any(part in {"", ".", ".."} for part in name.split("/")):
            raise ValueError("invalid DDNSTO artifact path")
        if name in approved or not re.fullmatch(r"[a-f0-9]{64}", record["sha256"]):
            raise ValueError("duplicate path or invalid approved SHA256")
        file = (source / name).resolve()
        if not file.is_relative_to(source.resolve()) or not file.is_file() or digest(file) != record["sha256"]:
            raise ValueError(f"DDNSTO approved digest mismatch: {name}")
        approved[name] = file
    versions = {}
    mutable = set()
    for variant, pointer in (("lite", "VERSION_LITE"), ("standard", "VERSION")):
        pointer_path = "openwrt/" + pointer
        if pointer_path not in approved:
            raise ValueError(f"missing DDNSTO version pointer: {pointer_path}")
        version = approved[pointer_path].read_text().strip()
        if not re.fullmatch(r"[A-Za-z0-9._+-]{1,64}", version):
            raise ValueError("invalid DDNSTO version")
        versions[variant] = version
        mutable.add(pointer_path)
        for ext in ("ipk", "apk"):
            folder = f"openwrt/{variant}{'-apk' if ext == 'apk' else ''}/{version}"
            names = [f"ddnsto_{arch}.{ext}" for arch in ("x86_64", "aarch64", "arm", "mipsel")]
            names += [f"luci-app-ddnsto.{ext}", f"luci-i18n-ddnsto-zh-cn.{ext}"]
            for name in names:
                if f"{folder}/{name}" not in approved:
                    raise ValueError(f"missing DDNSTO artifact: {folder}/{name}")
    linux_name = "linux-binary/ddnsto-standard-4.2.3.tar.gz"
    if linux_name not in approved:
        raise ValueError("Linux default 4.2.3 artifact missing")
    with tarfile.open(approved[linux_name], "r:gz") as archive:
        for arch in ("x86_64", "aarch64"):
            member = archive.getmember(f"ddnsto-standard-4.2.3/ddnsto.{arch}")
            if not member.isfile():
                raise ValueError("Linux tar member must be a regular binary")
    # Stage all approved files, then generate the digest metadata consumed by business.sh.
    for name, file in approved.items():
        target = destination / name
        if name in mutable:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(file, target)
        else:
            copy_immutable(file, target)
    for parent in sorted({Path(name).parent for name in approved if name not in mutable}):
        files = sorted((name, file) for name, file in approved.items() if Path(name).parent == parent)
        target = destination / parent / "SHA256SUMS"
        content = "".join(f"{digest(file)}  {Path(name).name}\n" for name, file in files)
        if str(parent) != "linux-binary" and target.exists() and target.read_text() != content:
            raise ValueError(f"immutable DDNSTO digest metadata changed: {parent}")
        target.write_text(content)
    return inventory["provenance"]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--zsetup-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=ROOT / "dist/release")
    parser.add_argument("--ddnsto-artifacts", type=Path)
    parser.add_argument("--require-production-ready", action="store_true")
    args = parser.parse_args()
    zroot = args.zsetup_root.resolve()
    output = args.output.resolve()
    if output in {ROOT, zroot, ROOT.parent, zroot.parent, Path(output.anchor)}:
        raise ValueError("output must be a dedicated release directory")
    if output.exists() and (not output.is_dir() or (any(output.iterdir()) and not (output / "scripts-release-manifest.json").is_file())):
        raise ValueError("refusing to replace a directory without this tool's release manifest")
    subprocess.run(["python3", "-B", str(ROOT / "scripts/build-entrypoints.py"), "--check"], check=True)
    release = zroot / "dist/release"
    subprocess.run([str(zroot / "scripts/check-release-artifacts.sh"), "--directory", str(release)], check=True)
    manifest = json.loads((release / "release-manifest.json").read_text())
    version = manifest["version"]
    components = [int(v) for v in version.split(".")]
    if components < [0, 2, 3]:
        raise ValueError("zsetup >= 0.2.3 required (Race budget fix)")
    if args.require_production_ready and not args.ddnsto_artifacts:
        raise ValueError("production package requires approved DDNSTO artifacts and digest inventory")
    scripts_dirty, zsetup_dirty = tree_dirty(ROOT), tree_dirty(zroot)
    if args.require_production_ready and (scripts_dirty or zsetup_dirty):
        raise ValueError("production candidate requires clean scripts and zsetup source trees")
    catalog = json.loads((ROOT / "catalog.json").read_text())
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".release-", dir=output.parent) as temporary:
        staging = Path(temporary)
        binary = staging / "binary"
        if (output / "binary").exists():
            shutil.copytree(output / "binary", binary)
        # Refuse replacing any previously staged immutable executable or installer.
        for file in sorted(release.iterdir()):
            copy_immutable(file, binary / "zsetup" / version / file.name)
        for record in catalog["installers"]:
            copy_immutable(ROOT / record["script"], binary / record["path"])
        provenance = None
        if args.ddnsto_artifacts:
            provenance = copy_ddnsto_artifacts(args.ddnsto_artifacts.resolve(), binary / "ddnsto")
        for app in sorted({r["application"] for r in catalog["installers"]}):
            shutil.copy2(ROOT / "apps" / app / "install.sh", binary / app / "install.sh")
        # Compatibility URLs carry the exact same installer, not another business implementation.
        for name in ("install_ddnsto.sh", "install_ddnsto_linux.sh", "install_ddnsto_business.sh", "setup_ddnsto.sh"):
            target = binary / "ddnsto" / ("linux-binary" if name == "install_ddnsto_linux.sh" else "openwrt") / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / "apps/ddnsto/install.sh", target)
        subprocess.run(["python3", "-B", str(zroot / "scripts/generate-product-config.py"), "--release-directory", str(release), "--installer-catalog", str(ROOT / "catalog.json"), "--output", str(binary / "zsetup/config.json")], check=True)
        (binary / "zsetup/stable").write_text(version + "\n")
        evidence = {
            "schema_version": 1, "config_version": catalog["config_version"],
            "scripts_commit": git_commit(ROOT), "zsetup_commit": git_commit(zroot),
            "scripts_tree_dirty": scripts_dirty, "zsetup_tree_dirty": zsetup_dirty,
            "zsetup_release_source_commit": manifest["source_commit"],
            "zsetup_version": version, "ddnsto_provenance": provenance,
            "readiness": "artifacts-verified-canary-required" if provenance else "development-ddnsto-artifacts-required",
            "files": [{"path": str(file.relative_to(staging)), "size": file.stat().st_size, "sha256": digest(file)} for file in sorted(binary.rglob("*")) if file.is_file()],
        }
        (staging / "scripts-release-manifest.json").write_text(json.dumps(evidence, indent=2) + "\n")
        files = sorted(file for file in staging.rglob("*") if file.is_file())
        (staging / "PACKAGE-SHA256SUMS").write_text("".join(f"{digest(file)}  {file.relative_to(staging)}\n" for file in files))
        archive = staging / f"zsetup-scripts-{catalog['config_version']}.tar.gz"
        with archive.open("wb") as raw, gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed, tarfile.open(fileobj=compressed, mode="w") as tar:
            for file in sorted(file for file in staging.rglob("*") if file.is_file() and file != archive):
                info = tar.gettarinfo(str(file), arcname=str(file.relative_to(staging)))
                info.uid = info.gid = info.mtime = 0
                info.uname = info.gname = ""
                info.mode = 0o755 if file.name.startswith("zsetup-linux-") or file.suffix == ".sh" else 0o644
                with file.open("rb") as stream:
                    tar.addfile(info, stream)
        subprocess.run(["sha256sum", "-c", "PACKAGE-SHA256SUMS"], cwd=staging, check=True, stdout=subprocess.DEVNULL)
        previous = output.with_name(output.name + ".previous")
        if previous.exists():
            raise ValueError(f"existing recovery backup: {previous}")
        if output.exists():
            output.rename(previous)
        try:
            shutil.move(str(staging), str(output))
        except BaseException:
            if previous.exists():
                previous.rename(output)
            raise
        if previous.exists():
            shutil.rmtree(previous)
    print(f"Release tree: {output}; {evidence['readiness']}")


if __name__ == "__main__":
    main()
