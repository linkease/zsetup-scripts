#!/usr/bin/env python3
"""Prepare one app's immutable installer and a complete, scoped index proposal.

Local only: no SSH, uploads, core upgrades or activation. A blocked proposal is
retained for review, never represented as a deployable production release.
"""
import argparse
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

from release_common import digest, copy_immutable

ROOT = Path(__file__).resolve().parents[1]
BASES = ["https://dl.istoreos.com/binary", "https://fw.d4ctech.com/binary", "https://fw20.koolcenter.com/binary"]
FALLBACK = "https://fw.koolcenter.com/binary"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=True, indent=2) + "\n").encode()


def read_json(path):
    raw = path.read_bytes()
    require(len(raw) <= 131072, "JSON exceeds configuration bound")
    return raw, json.loads(raw)


def public_path(value, application):
    require(isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9_./+-]+", value), "unsafe public path")
    parts = value.split("/")
    require(parts[0] == application and len(parts) >= 2 and all(p not in {"", ".", ".."} for p in parts),
            "public path escapes selected application")
    return value


def release_tuple(value):
    require(isinstance(value, str) and re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", value),
            "release compatibility needs a plain three-component version")
    return tuple(map(int, value.split(".")))


def validate_native(cli, config_path, scratch):
    # install --list parses the authoritative local file and returns before
    # convergence, downloads or installer execution. Isolate all ambient state.
    env = {k: v for k, v in os.environ.items() if not k.startswith("ZSETUP_")}
    env.update(ZSETUP_CONFIG=str(config_path), ZSETUP_CONFIG_CACHE=str(scratch / "lkg"),
               ZSETUP_MANAGED_ROOT=str(scratch / "managed"))
    result = subprocess.run([str(cli), "install", "--list"], env=env, capture_output=True, timeout=15)
    require(result.returncode == 0, "native schema 1 validation failed: " + result.stderr.decode(errors="replace"))


def prepare(args):
    registration = read_json(ROOT / "release/applications.json")[1]
    require(registration.get("schema_version") == 1, "unsupported release registration")
    require(args.application in registration["applications"], "application is not enabled for scoped rollout")
    app = args.application
    settings = registration["applications"][app]
    floor = settings["minimum_runtime"]
    public_entries = [public_path(p, app) for p in settings["public_entries"]]
    require(public_entries and len(set(public_entries)) == len(public_entries), "duplicate/empty public entries")
    output = args.output.absolute()
    require(not output.exists() and not output.is_symlink(), "review output already exists; refusing overwrite")
    live_raw, live = read_json(args.live_config)
    require(live.get("schema_version") == 1, "a complete live schema 1 config is required")
    stable = live["stable_zsetup"]["version"]
    compatible = release_tuple(stable) >= release_tuple(floor)
    # The native protocol uses exact strings, including min_version. The floor
    # is only a release-tool compatibility check, never a relaxed runtime rule.
    installer_version = stable if compatible else floor
    cli = args.native_cli.resolve(strict=True)
    version = subprocess.check_output([str(cli), "--version"], text=True, timeout=10).strip()
    require(version.startswith("zsetup ") and release_tuple(version.removeprefix("zsetup ")) >= release_tuple(floor),
            "native validator is older than the installer runtime floor")
    spec = importlib.util.spec_from_file_location("canonical_product_config", args.zsetup_root / "scripts/generate-product-config.py")
    generator = importlib.util.module_from_spec(spec); spec.loader.exec_module(generator)
    _, all_records = generator.catalog_installers(ROOT / "catalog.json", installer_version)
    records = [r for r in all_records if r["application"] == app]
    require(records, "application has no canonical installer records")
    paths = {r["path"] for r in records}
    require(len(paths) == 1, "first rollout requires one standalone installer per application")
    immutable_path = public_path(paths.pop(), app)
    require(len(immutable_path.split("/")) == 3 and immutable_path not in public_entries,
            "installer must use a distinct immutable version directory")
    script_version = immutable_path.split("/")[1]
    require(script_version not in {"stable", "latest"}, "mutable installer version refused")
    catalog = read_json(ROOT / "catalog.json")[1]
    scripts = {r["script"] for r in catalog["installers"] if r["application"] == app}
    require(len(scripts) == 1, "application has multiple source entries")
    source = (ROOT / scripts.pop()).resolve(strict=True)
    require(source.is_relative_to(ROOT / app), "installer source escapes application owner")
    groups = [g for g in live["source_groups"] if g["id"] == "koolcenter"]
    require(len(groups) == 1 and groups[0].get("primary_bases") == BASES and groups[0].get("fallback_base") == FALLBACK,
            "live source group conflicts with canonical installer sources")
    subprocess.run([sys.executable, "-B", str(ROOT / "scripts/build-entrypoints.py"), "--check"], check=True, capture_output=True)
    proposed = copy.deepcopy(live)
    proposed["installers"] = [r for r in live["installers"] if r["application"] != app] + records
    proposed["config_version"] = f"{app}-{script_version}-{hashlib.sha256(live_raw).hexdigest()[:12]}"
    require(len(json_bytes(proposed)) <= 131072, "proposed config exceeds native bound")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".app-release-", dir=output.parent) as name:
        stage = Path(name)
        baseline = stage / "baseline/zsetup/config.json"
        baseline.parent.mkdir(parents=True)
        baseline.write_bytes(live_raw)
        validate_native(cli, baseline, stage)
        immutable = stage / "immutable" / immutable_path
        copy_immutable(source, immutable)
        for path in public_entries:
            pointer = stage / "pointers" / path
            pointer.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(immutable, pointer)
        config_path = stage / "pointers/zsetup/config.json"
        config_path.parent.mkdir(parents=True)
        config_path.write_bytes(json_bytes(proposed))
        validate_native(cli, config_path, stage)
        require(all(r["sha256"] == digest(immutable) and r["size"] == immutable.stat().st_size for r in records),
                "installer changed during packaging")
        blockers = [] if compatible else [f"live Linux stable {stable} cannot run this installer; requires >= {floor}; core upgrade is separate"]
        files = [{"path": str(p.relative_to(stage)), "destination": str(p.relative_to(stage / area)),
                  "size": p.stat().st_size, "sha256": digest(p)}
                 for area in ("immutable", "pointers") for p in sorted((stage / area).rglob("*")) if p.is_file()]
        plan = {
            "schema_version": 1, "application": app, "script_version": script_version,
            "scripts_commit": subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True).strip(),
            "scripts_tree_dirty": bool(subprocess.check_output(["git", "-C", str(ROOT), "status", "--porcelain"], text=True).strip()),
            "registration_sha256": digest(ROOT / "release/applications.json"),
            "canonical_generator_sha256": digest(args.zsetup_root / "scripts/generate-product-config.py"),
            "public_release_authorized": False, "business_products_included": False,
            "mode": "local-review-only", "readiness": "blocked" if blockers else "ready-for-staging",
            "blockers": blockers, "minimum_runtime": floor, "live_stable_version": stable,
            "live_config_sha256": hashlib.sha256(live_raw).hexdigest(),
            "proposed_config_sha256": digest(config_path),
            "native_validator": {"version": version, "sha256": digest(cli)},
            "preserved_installer_applications": sorted({r["application"] for r in live["installers"] if r["application"] != app}),
            "files": files, "public_bases": [*BASES, FALLBACK],
            "unchanged": ["other application files and installer records", "all core binaries, stable and platform pointers", "source groups"],
            "activation_order": [immutable_path, *public_entries, "zsetup/config.json"],
            "required_before_activation": ["no blockers", "live config still matches baseline SHA256", "snapshot current public entry bytes/modes",
                                           "four-site HTTPS SHA256/size readback of immutable installer", "safe FastNet canary via both entries",
                                           "explicit production activation authorization"],
        }
        (stage / "app-release-manifest.json").write_bytes(json_bytes(plan))
        (stage / "release-state.txt").write_text("\n".join([
            app, script_version, plan["readiness"], stable, plan["live_config_sha256"],
            plan["proposed_config_sha256"], digest(immutable),
        ]) + "\n")
        shutil.copy2(ROOT / "scripts/install-app-release.sh", stage / "install-app-release.sh")
        checksummed = sorted(p for p in stage.rglob("*") if p.is_file())
        (stage / "PACKAGE-SHA256SUMS").write_text("".join(f"{digest(p)}  {p.relative_to(stage)}\n" for p in checksummed))
        # Output must remain absent: a review is immutable once materialized.
        stage.rename(output)
    print(f"FastNet-only local review: {output}; {plan['readiness']}; no remote changes")
    return plan


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--application", required=True)
    parser.add_argument("--live-config", type=Path, required=True, help="read-only snapshot from the actual Linux config")
    parser.add_argument("--zsetup-root", type=Path, required=True)
    parser.add_argument("--native-cli", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    prepare(parser.parse_args())


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print("app release: " + str(error), file=sys.stderr)
        sys.exit(1)
