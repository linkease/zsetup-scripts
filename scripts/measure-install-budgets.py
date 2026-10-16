#!/usr/bin/env python3
"""Read-only product measurements. All network I/O uses canonical zsetup.

Products are temporary, never executed, bundled or copied into releases.
The report records observations, not a replacement for business SHA metadata.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import zipfile

BASES = ["https://dl.istoreos.com/binary", "https://fw.d4ctech.com/binary", "https://fw20.koolcenter.com/binary"]
FALLBACK = "https://fw.koolcenter.com/binary"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--zsetup", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args()
    results = []
    with tempfile.TemporaryDirectory(prefix="zsetup-measure-") as name:
        root = Path(name)

        def download(relative, path, sha=None):
            cmd = [str(args.zsetup.resolve()), "download", "--quiet", "-o", str(path), "--max-bytes", str(512 * 1024**2), "--min-free-bytes", str(64 * 1024**2), "--overall-timeout", "120s", "--retry-rounds", "3"]
            if sha:
                cmd += ["--sha256", sha]
            cmd += [f"{base}/{relative}" for base in BASES] + ["--fallback-url", f"{FALLBACK}/{relative}"]
            return subprocess.run(cmd).returncode

        items = []
        for app, keys in [("fastnet", ["FASTNET_AMD64_SHA256", "FASTNET_ARM64_SHA256", "FASTNET_ARMV7_SHA256"]), ("fastpve", ["FASTPVE_SHA256"])]:
            meta = root / app
            code = download(f"{app}/version.txt", meta)
            if code:
                results.append({"application": app, "metadata_exit": code}); continue
            version = subprocess.check_output([str(args.zsetup.resolve()), "metadata", "version", str(meta), "VERSION"], text=True).strip()
            for key in keys:
                sha = subprocess.check_output([str(args.zsetup.resolve()), "metadata", "sha256", str(meta), key], text=True).strip()
                arch = key.split("_")[1].lower()
                filename = f"FastNet-{version}.{arch}" if app == "fastnet" else f"FastPVE-{version}"
                items.append((app, f"{app}/{filename}", sha, "binary"))
        items += [("ddnsto", "ddnsto/linux-binary/ddnsto-standard-4.2.3.tar.gz", "b982ebd38e8c145d955049eb5b73960c01941bc05f084c3a2115dfca2b6eea6e", "tar")]
        items += [("linkease", "LinkEase/LinuxStorage/linkease-binary-1.7.5.tar.gz", None, "tar")]
        items += [("linkease", f"LinkEase/AutoUpgrade/linkmount/{arch}.zip", None, "zip") for arch in ["amd64", "arm64", "arm"]]
        for index, (app, relative, sha, kind) in enumerate(items):
            path = root / str(index)
            row = {"application": app, "path": relative, "expected_sha256": sha, "kind": kind}
            row["exit"] = download(relative, path, sha)
            if row["exit"] == 0:
                row["size"] = path.stat().st_size
                with path.open("rb") as stream:
                    row["sha256"] = hashlib.file_digest(stream, "sha256").hexdigest()
                expanded = row["size"] if kind == "binary" else 0
                members = 0
                if kind == "tar":
                    with tarfile.open(path, "r|gz") as archive:
                        for member in archive:
                            members += 1
                            expanded += member.size
                            if members > 4096 or expanded > 1024**3:
                                raise ValueError("measurement archive budget exceeded")
                elif kind == "zip":
                    with zipfile.ZipFile(path) as archive:
                        members = len(archive.infolist())
                        expanded = sum(member.file_size for member in archive.infolist())
                        if members > 4096 or expanded > 1024**3:
                            raise ValueError("measurement ZIP budget exceeded")
                row.update(expanded_bytes=expanded, members=members)
                path.unlink()
            results.append(row)
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(json.dumps({"schema_version": 1, "executed_products": False, "temporary_products_retained": False, "observations": results}, indent=2) + "\n")
    print(args.report)


if __name__ == "__main__":
    main()
