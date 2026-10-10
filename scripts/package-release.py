#!/usr/bin/env python3
"""Build reviewable static release trees using the canonical zsetup generator/checker."""
import argparse
import gzip
import json
from pathlib import Path
import runpy
import re
import shutil
import subprocess
import tarfile
import tempfile

from release_common import digest, copy_immutable

ROOT = Path(__file__).resolve().parents[1]
DDNSTO = runpy.run_path(str(ROOT / "ddnsto/release.py"))


def git_commit(root):
    return subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()


def tree_dirty(root):
    return bool(subprocess.check_output(["git", "-C", str(root), "status", "--porcelain", "--", "."], text=True).strip())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--zsetup-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=ROOT / "dist/release")
    parser.add_argument("--require-clean", action="store_true", help="require committed scripts and zsetup sources; server verification remains a separate release step")
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
    if components < [0, 2, 4]:
        raise ValueError("zsetup >= 0.2.4 required (native metadata and memory facts)")
    scripts_dirty, zsetup_dirty = tree_dirty(ROOT), tree_dirty(zroot)
    if args.require_clean and (scripts_dirty or zsetup_dirty):
        raise ValueError("production candidate requires clean scripts and zsetup source trees")
    catalog = json.loads((ROOT / "catalog.json").read_text())
    applications = {record["application"] for record in catalog["installers"]}
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".release-", dir=output.parent) as temporary:
        staging = Path(temporary)
        binary = staging / "binary"
        # Keep immutable installer/native history only. Products already live on the server.
        previous_binary = output / "binary"
        native_names = {file.name for file in release.iterdir()}
        for file in sorted(previous_binary.rglob("*")):
            if not file.is_file():
                continue
            parts = file.relative_to(previous_binary).parts
            if len(parts) != 3 or not re.fullmatch(r"[A-Za-z0-9._+-]{1,64}", parts[1]) or parts[1] in {".", "..", "stable", "latest"}:
                continue
            if (parts[0] == "zsetup" and parts[2] in native_names) or (parts[0] in applications and parts[2] == "install.sh"):
                copy_immutable(file, binary.joinpath(*parts))
        # Refuse replacing any previously staged immutable executable or installer.
        for file in sorted(release.iterdir()):
            copy_immutable(file, binary / "zsetup" / version / file.name)
        for record in catalog["installers"]:
            copy_immutable(ROOT / record["script"], binary / record["path"])
        for app in sorted(applications):
            shutil.copy2(ROOT / app / "install.sh", binary / app / "install.sh")
        # Native desktop entrypoints are public business installers, but are
        # not zsetup POSIX catalog entries and therefore are copied explicitly.
        for relative in ("install.ps1", "install-macos.sh"):
            copy_immutable(ROOT / "ddnsto" / relative, binary / "ddnsto" / relative)
        DDNSTO["copy_compat_installers"](ROOT / "ddnsto/install.sh", binary / "ddnsto")
        subprocess.run(["python3", "-B", str(zroot / "scripts/generate-product-config.py"), "--release-directory", str(release), "--installer-catalog", str(ROOT / "catalog.json"), "--output", str(binary / "zsetup/config.json")], check=True)
        (binary / "zsetup/stable").write_text(version + "\n")
        evidence = {
            "schema_version": 1, "config_version": catalog["config_version"],
            "scripts_commit": git_commit(ROOT), "zsetup_commit": git_commit(zroot),
            "scripts_tree_dirty": scripts_dirty, "zsetup_tree_dirty": zsetup_dirty,
            "zsetup_release_source_commit": manifest["source_commit"],
            "zsetup_version": version,
            "business_artifacts": {"owner": "business-server-release", "included": False},
            "readiness": "server-artifacts-and-canary-unverified",
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
