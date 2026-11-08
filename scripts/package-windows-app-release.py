#!/usr/bin/env python3
"""Prepare one Windows application's immutable, rollback-capable local review."""
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

from release_common import copy_immutable, digest

ROOT = Path(__file__).resolve().parents[1]
MAX_JSON = 131072


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_json(path):
    data = path.read_bytes()
    require(len(data) <= MAX_JSON, "JSON exceeds configuration bound")
    return data, json.loads(data)


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=True, indent=2) + "\n").encode()


def plain_version(value):
    require(isinstance(value, str) and re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", value), "plain runtime version required")
    return tuple(map(int, value.split(".")))


def public_path(value, application):
    require(isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9_./+-]+", value), "unsafe public path")
    parts = value.split("/")
    require(parts[0] == application and len(parts) >= 2 and all(part not in {"", ".", ".."} for part in parts), "public path escapes application")
    require(value.endswith(".ps1"), "Windows public entry must use .ps1")
    return value


def validate_native(cli, config, scratch):
    environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSETUP_")}
    environment.update(ZSETUP_CONFIG=str(config), ZSETUP_CONFIG_CACHE=str(scratch / "lkg"), ZSETUP_MANAGED_ROOT=str(scratch / "managed"))
    result = subprocess.run([str(cli), "install", "--list"], env=environment, capture_output=True, timeout=15)
    require(result.returncode == 0, "native schema 1 validation failed: " + result.stderr.decode(errors="replace"))


def prepare(args):
    registration_raw, registration = read_json(args.registration)
    require(set(registration) == {"schema_version", "platform", "source_group", "applications"}, "invalid Windows registration fields")
    require(registration["schema_version"] == 1 and registration["platform"] == "windows", "unsupported Windows registration")
    require(args.application in registration["applications"], "application is not enabled for Windows rollout")
    settings = registration["applications"][args.application]
    require(set(settings) == {"minimum_runtime", "source_directory", "public_entries"}, "invalid application registration")
    expected_group = registration["source_group"]
    require(set(expected_group) == {"id", "primary_bases", "fallback_base"}, "invalid source group registration")
    app = args.application
    floor = settings["minimum_runtime"]
    plain_version(floor)
    public_entries = [public_path(path, app) for path in settings["public_entries"]]
    require(public_entries and len(public_entries) == len(set(public_entries)), "duplicate or empty public entries")
    output = args.output.absolute()
    require(not output.exists() and not output.is_symlink(), "review output already exists; refusing overwrite")
    live_raw, live = read_json(args.live_config)
    require(live.get("schema_version") == 1, "complete live Windows schema 1 config required")
    stable_bytes = args.stable_windows.read_bytes()
    require(len(stable_bytes) <= 128, "stable-windows exceeds bound")
    stable = stable_bytes.decode("ascii").rstrip("\r\n")
    plain_version(stable)
    require(stable == live["stable_zsetup"]["version"] == floor, "Windows core and application minimum must remain exact")
    groups = [group for group in live["source_groups"] if group.get("id") == expected_group["id"]]
    require(len(groups) == 1 and groups[0] == expected_group, "live Windows source group conflicts with canonical sources")
    require(live["stable_zsetup"]["source_group"] == expected_group["id"], "stable Windows source group mismatch")
    artifacts = live["stable_zsetup"]["artifacts"]
    require(len(artifacts) == 1 and artifacts[0]["arch"] == "i686", "canonical Windows core artifact required")
    core_record = artifacts[0]
    require(core_record["path"] == f"zsetup/{stable}/zsetup-windows-i686.exe", "Windows core path mismatch")
    core = (args.core_release / "zsetup-windows-i686.exe").resolve(strict=True)
    require(core.stat().st_size == core_record["size"] and digest(core) == core_record["sha256"], "Windows core size or SHA256 mismatch")
    owner = (ROOT / settings["source_directory"]).resolve(strict=True)
    require(owner.is_relative_to(ROOT) and owner == (ROOT / app).resolve(), "application source owner mismatch")
    subprocess.run([sys.executable, "-B", str(ROOT / "scripts/build-entrypoints.py"), "--check"], check=True, capture_output=True)
    spec = importlib.util.spec_from_file_location("canonical_product_config", args.zsetup_root / "scripts/generate-product-config.py")
    generator = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(generator)
    _, records = generator.catalog_installers(ROOT / "catalog-windows.json", stable)
    records = [dict(record, source_group=expected_group["id"]) for record in records if record["application"] == app]
    require(len(records) == 1, "Windows application requires one unambiguous selector")
    record = records[0]
    immutable_path = public_path(record["path"], app)
    require(immutable_path not in public_entries and len(immutable_path.split("/")) == 3, "immutable Windows path required")
    script_version = immutable_path.split("/")[1]
    require(script_version not in {"stable", "latest"}, "mutable application version refused")
    source = (ROOT / "scoop/scoop-install.ps1").resolve(strict=True)
    require(source.parent == owner and record["min_version"] == stable, "entry owner or minimum runtime mismatch")
    cli = args.native_cli.resolve(strict=True)
    cli_version = subprocess.check_output([str(cli), "--version"], text=True, timeout=10).strip()
    require(cli_version.startswith("zsetup ") and plain_version(cli_version.removeprefix("zsetup ")) >= plain_version(stable), "native validator is older than Windows stable")
    proposed = copy.deepcopy(live)
    proposed["installers"] = [item for item in live["installers"] if item["application"] != app] + records
    proposed["config_version"] = f"{app}-{script_version}-{hashlib.sha256(live_raw).hexdigest()[:12]}"
    require(len(json_bytes(proposed)) <= MAX_JSON, "proposed Windows config exceeds native bound")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".windows-app-release-", dir=output.parent) as temporary_name:
        stage = Path(temporary_name)
        baseline = stage / "baseline/zsetup/config-windows.json"
        baseline.parent.mkdir(parents=True)
        baseline.write_bytes(live_raw)
        (baseline.parent / "stable-windows").write_bytes(stable_bytes)
        validate_native(cli, baseline, stage)
        immutable = stage / "immutable" / immutable_path
        copy_immutable(source, immutable)
        for path in public_entries:
            pointer = stage / "pointers" / path
            pointer.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(immutable, pointer)
        config_path = stage / "pointers/zsetup/config-windows.json"
        config_path.parent.mkdir(parents=True)
        config_path.write_bytes(json_bytes(proposed))
        validate_native(cli, config_path, stage)
        require(record["sha256"] == digest(immutable) and record["size"] == immutable.stat().st_size, "installer changed during packaging")
        files = [{
            "path": str(path.relative_to(stage)), "destination": str(path.relative_to(stage / area)),
            "size": path.stat().st_size, "sha256": digest(path),
        } for area in ("immutable", "pointers") for path in sorted((stage / area).rglob("*")) if path.is_file()]
        plan = {
            "schema_version": 1, "platform": "windows", "application": app,
            "script_version": script_version,
            "scripts_commit": subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True).strip(),
            "scripts_tree_dirty": bool(subprocess.check_output(["git", "-C", str(ROOT), "status", "--porcelain"], text=True).strip()),
            "registration_sha256": hashlib.sha256(registration_raw).hexdigest(),
            "catalog_sha256": digest(ROOT / "catalog-windows.json"),
            "canonical_generator_sha256": digest(args.zsetup_root / "scripts/generate-product-config.py"),
            "public_release_authorized": False, "mode": "local-review-only", "readiness": "ready-for-staging",
            "minimum_runtime": floor, "live_stable_version": stable,
            "live_config_sha256": hashlib.sha256(live_raw).hexdigest(), "proposed_config_sha256": digest(config_path),
            "stable_windows_sha256": hashlib.sha256(stable_bytes).hexdigest(),
            "windows_core": {"path": core_record["path"], "size": core_record["size"], "sha256": core_record["sha256"]},
            "native_validator": {"version": cli_version, "sha256": digest(cli)},
            "preserved_installer_applications": sorted({item["application"] for item in live["installers"] if item["application"] != app}),
            "files": files,
            "unchanged": ["zsetup/stable-windows", "Windows core artifacts", "non-Windows configurations", "other Windows application files and installer records", "source groups"],
            "activation_order": [immutable_path, *public_entries, "zsetup/config-windows.json"],
            "required_before_activation": ["live config and stable-windows still match baseline", "four-site immutable entry readback", "native Windows canary", "explicit production authorization"],
        }
        (stage / "windows-app-release-manifest.json").write_bytes(json_bytes(plan))
        (stage / "release-state.txt").write_text("\n".join([app, script_version, stable, plan["live_config_sha256"], plan["proposed_config_sha256"], digest(immutable), core_record["sha256"]]) + "\n", encoding="ascii")
        shutil.copy2(ROOT / "scripts/install-windows-app-release.sh", stage / "install-windows-app-release.sh")
        checksummed = sorted(path for path in stage.rglob("*") if path.is_file())
        (stage / "PACKAGE-SHA256SUMS").write_text("".join(f"{digest(path)}  {path.relative_to(stage)}\n" for path in checksummed), encoding="ascii")
        stage.rename(output)
    print(f"{app} Windows-only local review: {output}; no remote changes")
    return plan


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--application", required=True)
    parser.add_argument("--live-config", type=Path, required=True)
    parser.add_argument("--stable-windows", type=Path, required=True)
    parser.add_argument("--core-release", type=Path, required=True)
    parser.add_argument("--zsetup-root", type=Path, required=True)
    parser.add_argument("--native-cli", type=Path, required=True)
    parser.add_argument("--registration", type=Path, default=ROOT / "release/windows-applications.json")
    parser.add_argument("--output", type=Path, required=True)
    prepare(parser.parse_args())


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print("Windows app release: " + str(error), file=sys.stderr)
        sys.exit(1)
