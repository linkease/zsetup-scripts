#!/usr/bin/env python3
"""Capture published DDNSTO bytes using the historical installer layout and zsetup."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import runpy
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
RELEASE = runpy.run_path(str(ROOT / "scripts/package-release.py"))
digest = RELEASE["digest"]
copy_immutable = RELEASE["copy_immutable"]
PRIMARY_BASES = (
    "https://dl.istoreos.com/binary/ddnsto",
    "https://fw.d4ctech.com/binary/ddnsto",
    "https://fw20.koolcenter.com/binary/ddnsto",
)
FALLBACK_BASE = "https://fw.koolcenter.com/binary/ddnsto"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--zsetup-bin", required=True, type=Path)
    parser.add_argument("--output", type=Path, default=ROOT / "dist/ddnsto-artifacts")
    args = parser.parse_args()
    binary = args.zsetup_bin.resolve()
    product = subprocess.check_output([str(binary), "--version"], text=True).strip()
    match = re.fullmatch(r"zsetup (\d+)\.(\d+)\.(\d+)", product)
    if not match or tuple(map(int, match.groups())) < (0, 2, 3):
        raise ValueError("collector requires zsetup >= 0.2.3")
    output = args.output.resolve()
    if output in {ROOT, ROOT.parent, Path(output.anchor)}:
        raise ValueError("output must be a dedicated DDNSTO artifact directory")
    if output.exists() and (not output.is_dir() or (any(output.iterdir()) and not (output / "artifacts.json").is_file())):
        raise ValueError("refusing to replace an unrelated output directory")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".ddnsto-collect-", dir=output.parent) as temporary:
        staging = Path(temporary)
        if output.exists():
            shutil.copytree(output, staging, dirs_exist_ok=True)
        fetched = staging / ".upstream"
        fetched.mkdir(exist_ok=True)
        acquisitions = []
        captured = {}

        def fetch(remote):
            target = fetched / remote
            target.parent.mkdir(parents=True, exist_ok=True)
            print(f"[{len(acquisitions)+1}/23] DDNSTO {remote}", flush=True)
            urls = [base + "/" + remote for base in PRIMARY_BASES]
            fallback = FALLBACK_BASE + "/" + remote
            subprocess.run([str(binary), "download", "-o", str(target), "--no-cache", "--fallback-url", fallback, *urls], check=True, timeout=180)
            if not target.is_file() or target.stat().st_size == 0:
                raise ValueError(f"empty DDNSTO artifact: {remote}")
            acquisitions.append({"path": remote, "primary_urls": urls, "fallback_url": fallback, "sha256": digest(target), "size": target.stat().st_size})
            return target

        versions = {}
        for variant, pointer in (("standard", "VERSION"), ("lite", "VERSION_LITE")):
            remote = "openwrt/" + pointer
            file = fetch(remote)
            version = file.read_text().strip()
            if not re.fullmatch(r"[A-Za-z0-9._+-]{1,64}", version):
                raise ValueError(f"invalid legacy version metadata: {remote}")
            versions[variant] = version
            destination = staging / remote
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(file, destination)
            captured[remote] = destination
        # The old script takes UI packages from the root, not the version folders.
        ui = {}
        for ext in ("ipk", "apk"):
            for name in ("luci-app-ddnsto", "luci-i18n-ddnsto-zh-cn"):
                ui[name + "." + ext] = fetch(f"openwrt/{name}.{ext}")
        for variant, version in versions.items():
            for ext in ("ipk", "apk"):
                folder = f"openwrt/{variant}{'-apk' if ext == 'apk' else ''}/{version}"
                for arch in ("x86_64", "aarch64", "arm", "mipsel"):
                    name = f"ddnsto_{arch}.{ext}"
                    remote = f"{folder}/{name}"
                    destination = staging / remote
                    copy_immutable(fetch(remote), destination)
                    captured[remote] = destination
                for name, file in ui.items():
                    if name.endswith("." + ext):
                        relative = f"{folder}/{name}"
                        destination = staging / relative
                        copy_immutable(file, destination)
                        captured[relative] = destination
        # Keep the old Linux default and archive layout. The established final CDN now serves it.
        remote = "linux-binary/ddnsto-standard-4.2.3.tar.gz"
        destination = staging / remote
        copy_immutable(fetch(remote), destination)
        captured[remote] = destination
        inventory = {
            "schema_version": 1,
            "provenance": "Existing DDNSTO installer URLs: ddnsto_all_in_one_script@13bfb75; HTTPS acquisition through zsetup; hashes computed from captured published bytes",
            "files": [{"path": name, "sha256": digest(file)} for name, file in sorted(captured.items())],
        }
        (staging / "artifacts.json").write_text(json.dumps(inventory, indent=2) + "\n")
        (staging / "acquisition.json").write_text(json.dumps({"schema_version": 1, "captured_at": datetime.now(timezone.utc).isoformat(), "zsetup": product, "versions": versions, "downloads": acquisitions}, indent=2) + "\n")
        shutil.rmtree(fetched)
        # Reuse the package validator for completeness, SHA256 and the two Linux tar members.
        with tempfile.TemporaryDirectory(prefix=".ddnsto-validate-", dir=output.parent) as validation:
            RELEASE["copy_ddnsto_artifacts"](staging, Path(validation))
        previous = output.with_name(output.name + ".previous")
        if previous.exists():
            raise ValueError(f"existing recovery directory: {previous}")
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
    print(f"Captured DDNSTO artifacts: {output} (27 files; Standard {versions['standard']}, Lite {versions['lite']}, Linux 4.2.3)")


if __name__ == "__main__":
    main()
