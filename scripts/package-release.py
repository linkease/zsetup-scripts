#!/usr/bin/env python3
"""Build reviewable static release trees using the canonical zsetup generator/checker."""
import argparse
import gzip
import json
from pathlib import Path
import runpy
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
    inputs = parser.add_mutually_exclusive_group()
    inputs.add_argument("--ddnsto-artifacts", type=Path)
    inputs.add_argument("--collect-ddnsto", action="store_true", help="capture artifacts from the proven legacy CDN paths through zsetup")
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
    if components < [0, 2, 4]:
        raise ValueError("zsetup >= 0.2.4 required (native metadata and memory facts)")
    if args.require_production_ready and not (args.ddnsto_artifacts or args.collect_ddnsto):
        raise ValueError("production package requires DDNSTO artifacts; use --collect-ddnsto or --ddnsto-artifacts")
    scripts_dirty, zsetup_dirty = tree_dirty(ROOT), tree_dirty(zroot)
    if args.require_production_ready and (scripts_dirty or zsetup_dirty):
        raise ValueError("production candidate requires clean scripts and zsetup source trees")
    if args.collect_ddnsto:
        args.ddnsto_artifacts = output.parent / "ddnsto-artifacts"
        subprocess.run(["python3", "-B", str(ROOT / "ddnsto/collect-artifacts.py"), "--zsetup-bin", str(release / "zsetup-linux-x86_64"), "--output", str(args.ddnsto_artifacts)], check=True)
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
            provenance = DDNSTO["copy_ddnsto_artifacts"](args.ddnsto_artifacts.resolve(), binary / "ddnsto")
        for app in sorted({r["application"] for r in catalog["installers"]}):
            shutil.copy2(ROOT / app / "install.sh", binary / app / "install.sh")
        DDNSTO["copy_compat_installers"](ROOT / "ddnsto/install.sh", binary / "ddnsto")
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
