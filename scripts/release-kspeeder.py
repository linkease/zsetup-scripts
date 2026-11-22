#!/usr/bin/env python3
"""Discover, lock, validate and publish the latest stable KSpeeder release.

This is the maintained operator entrypoint.  It generates the product lock
from GitHub, proves the KSpeeder/KS-CLI apps tree is current, and delegates the
actual stage/activate/verify transaction to publish-kspeeder-products.py.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parents[1]
LOCK_PATH = ROOT / "release/kspeeder-products.json"
PUBLISHER_PATH = ROOT / "scripts/publish-kspeeder-products.py"
LATEST_API = "https://api.github.com/repos/kspeeder/docker_kspeeder/releases/latest"
REPOSITORY = "kspeeder/docker_kspeeder"
PUBLIC_BASES = [
    "https://dl.istoreos.com/binary",
    "https://fw.d4ctech.com/binary",
    "https://fw20.koolcenter.com/binary",
    "https://fw.koolcenter.com/binary",
]
VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")

SPEC = importlib.util.spec_from_file_location("publish_kspeeder_products", PUBLISHER_PATH)
publisher = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(publisher)


class WorkflowError(RuntimeError):
    pass


def run(command, *, capture=False, check=True):
    return subprocess.run(
        [str(item) for item in command], check=check, text=True,
        capture_output=capture,
    )


def request(url: str) -> Request:
    headers = {
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "zsetup-scripts-kspeeder-release/1",
    }
    token = os.environ.get("GITHUB_TOKEN")
    if token and urlsplit(url).hostname == "api.github.com":
        headers["Authorization"] = f"Bearer {token}"
    return Request(url, headers=headers)


def fetch_json(url: str = LATEST_API) -> dict:
    with urlopen(request(url), timeout=30) as response:
        if urlsplit(response.url).scheme != "https":
            raise WorkflowError("GitHub API followed a non-HTTPS redirect")
        body = response.read(2 * 1024 * 1024 + 1)
    if len(body) > 2 * 1024 * 1024:
        raise WorkflowError("GitHub release response exceeds 2 MiB")
    value = json.loads(body)
    if not isinstance(value, dict):
        raise WorkflowError("GitHub release response is not an object")
    return value


def fetch_small_asset(url: str, size: int, expected: str) -> bytes:
    if size > 64 * 1024:
        raise WorkflowError("release metadata asset exceeds 64 KiB")
    with urlopen(request(url), timeout=30) as response:
        if urlsplit(response.url).scheme != "https":
            raise WorkflowError("release metadata followed a non-HTTPS redirect")
        body = response.read(size + 1)
    if len(body) != size or hashlib.sha256(body).hexdigest() != expected:
        raise WorkflowError("release metadata size or SHA256 differs from GitHub")
    return body


def expected_asset_names(version: str) -> set[str]:
    return {
        f"iStoreEnhance-binary-{version}.tar.gz",
        "iStoreEnhance-linux.amd64",
        "iStoreEnhance-linux.arm",
        "iStoreEnhance-linux.arm64",
        f"ks-cli-binary-{version}.tar.gz",
        "ks-cli-linux-amd64",
        "ks-cli-linux-arm",
        "ks-cli-linux-arm64",
        "version.txt",
        "ks-cli-version.txt",
    }


def lock_from_release(release: dict, *, metadata_fetch=fetch_small_asset) -> dict:
    tag = release.get("tag_name")
    version = tag[1:] if isinstance(tag, str) and tag.startswith("v") else ""
    if not VERSION.fullmatch(version):
        raise WorkflowError("latest GitHub release tag must be vMAJOR.MINOR.PATCH")
    if release.get("draft") is not False or release.get("prerelease") is not False:
        raise WorkflowError("latest KSpeeder release must be stable and published")
    published = release.get("published_at")
    if not isinstance(published, str) or not published:
        raise WorkflowError("latest KSpeeder release has no publication timestamp")

    download_base = f"https://github.com/{REPOSITORY}/releases/download/v{version}"
    assets = release.get("assets")
    if not isinstance(assets, list) or len(assets) != 10:
        raise WorkflowError("latest KSpeeder release must contain exactly ten assets")
    locked = []
    urls = {}
    for asset in assets:
        if not isinstance(asset, dict):
            raise WorkflowError("GitHub release contains an invalid asset")
        name = asset.get("name")
        size = asset.get("size")
        digest = asset.get("digest")
        url = asset.get("browser_download_url")
        if (not isinstance(name, str) or not isinstance(size, int) or size <= 0
                or not isinstance(digest, str) or not digest.startswith("sha256:")
                or not SHA256.fullmatch(digest.removeprefix("sha256:"))):
            raise WorkflowError("GitHub asset is missing an exact SHA256 digest or size")
        if url != f"{download_base}/{name}":
            raise WorkflowError("GitHub asset download URL is not canonical")
        locked.append({"name": name, "size": size, "sha256": digest.removeprefix("sha256:")})
        urls[name] = url
    if {asset["name"] for asset in locked} != expected_asset_names(version):
        raise WorkflowError("latest KSpeeder release asset inventory is incomplete or unexpected")

    value = {
        "schema_version": 1,
        "product_version": version,
        "source": {
            "repository": REPOSITORY,
            "tag": f"v{version}",
            "published_at": published,
            "download_base": download_base,
        },
        "public": {
            "prefix": "kspeeder",
            "bases": PUBLIC_BASES,
            "root_pointers": ["version.txt", "ks-cli-version.txt"],
        },
        "assets": sorted(locked, key=lambda item: item["name"]),
    }

    with tempfile.TemporaryDirectory(prefix="kspeeder-latest-metadata-") as folder:
        directory = Path(folder)
        by_name = {asset["name"]: asset for asset in value["assets"]}
        for name in ("version.txt", "ks-cli-version.txt"):
            asset = by_name[name]
            (directory / name).write_bytes(metadata_fetch(urls[name], asset["size"], asset["sha256"]))
        publisher.validate_metadata(directory, value)
    return value


def latest_lock(*, release_fetch=fetch_json, metadata_fetch=fetch_small_asset) -> dict:
    return lock_from_release(release_fetch(), metadata_fetch=metadata_fetch)


def version_tuple(value: str) -> tuple[int, int, int]:
    if not VERSION.fullmatch(value):
        raise WorkflowError("invalid product version")
    return tuple(int(part) for part in value.split("."))


def canonical(value: dict) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode()


def lock_is_latest(latest: dict) -> bool:
    return publisher.load_lock(LOCK_PATH) == latest


def require_latest_lock(latest: dict) -> None:
    current = publisher.load_lock(LOCK_PATH)
    if current != latest:
        raise WorkflowError(
            f"tracked lock is {current['product_version']}, latest stable is "
            f"{latest['product_version']}; run update-lock, review and commit it first"
        )


def relevant_status() -> str:
    return run([
        "git", "-C", ROOT, "status", "--porcelain=v1", "--",
        "release/kspeeder-products.json", "scripts/install-kspeeder-product-release.sh",
        "scripts/publish-kspeeder-products.py", "scripts/release-kspeeder.py",
        "kspeeder", "apps/kspeeder", "apps/ks-cli",
        "apps/_shared/kspeeder-binary.sh", "apps/zsetup/config.json", "apps/SHA256SUMS",
    ], capture=True).stdout


def require_clean_candidate() -> None:
    status = relevant_status()
    if status:
        raise WorkflowError("KSpeeder release inputs must be committed and clean:\n" + status.rstrip())


def update_lock(latest: dict, lock_path: Path = LOCK_PATH, *, require_clean=True) -> bool:
    if require_clean:
        status = run([
            "git", "-C", ROOT, "status", "--porcelain=v1", "--", lock_path.relative_to(ROOT),
        ], capture=True).stdout
        if status:
            raise WorkflowError("refusing to overwrite an uncommitted KSpeeder product lock")
    current = publisher.load_lock(lock_path)
    if version_tuple(latest["product_version"]) < version_tuple(current["product_version"]):
        raise WorkflowError("refusing to downgrade the KSpeeder product lock")
    if current == latest:
        return False
    if latest["product_version"] == current["product_version"]:
        raise WorkflowError(
            "upstream changed an existing release; immutable KSpeeder bytes require a new version tag"
        )
    temporary = lock_path.with_name(f".{lock_path.name}.new")
    try:
        temporary.write_bytes(canonical(latest))
        publisher.load_lock(temporary)
        temporary.replace(lock_path)
    finally:
        temporary.unlink(missing_ok=True)
    return True


def validate_apps(*, root: Path = ROOT, native_bin: Path | None = None,
                  command_runner=run) -> dict:
    commands = [
        [sys.executable, "-B", root / "scripts/build-entrypoints.py", "--check"],
        [sys.executable, "-B", root / "scripts/build.py", "--check"],
        [sys.executable, "-B", root / "scripts/check-public-tree.py", root / "apps"],
        [sys.executable, "-B", root / "tests/apps/ordinary_migrations_test.py"],
    ]
    for command in commands:
        command_runner(command)

    config = json.loads((root / "apps/zsetup/config.json").read_text(encoding="utf-8"))
    results = {}
    for app in ("ks-cli", "kspeeder"):
        manifest = json.loads((root / "apps" / app / "app.json").read_text(encoding="utf-8"))
        version = manifest.get("version")
        if not isinstance(version, str) or not VERSION.fullmatch(version):
            raise WorkflowError(f"apps/{app}/app.json has an invalid installer version")
        source = root / "kspeeder" / app / f"{app}-install.sh"
        payload = root / "apps" / app / version / "installer.sh"
        alias = root / "apps" / app / f"{app}-install.sh"
        standard = root / "apps" / app / "install.sh"
        if not source.is_file() or payload.read_bytes() != source.read_bytes():
            raise WorkflowError(f"apps/{app} immutable payload differs from canonical source")
        if alias.read_bytes() != standard.read_bytes():
            raise WorkflowError(f"apps/{app} standard aliases differ")
        expected_sha = hashlib.sha256(payload.read_bytes()).hexdigest()
        records = [entry for entry in config["installers"] if entry["application"] == app]
        if not records or {entry["path"] for entry in records} != {
            f"zsetup-scripts/apps/{app}/{version}/installer.sh"
        } or {entry["sha256"] for entry in records} != {expected_sha}:
            raise WorkflowError(f"apps/{app} config records do not identify its immutable payload")
        for script in (source, payload, alias, standard):
            command_runner(["sh", "-n", script])
        results[app] = {"installer_version": version, "records": len(records), "sha256": expected_sha}

    shared = root / "apps/_shared/kspeeder-binary.sh"
    if shared.read_bytes() != (root / "kspeeder/lib/binary.sh").read_bytes():
        raise WorkflowError("apps shared KSpeeder policy differs from canonical source")
    policy = shared.read_text(encoding="utf-8")
    if ("INSTALLER_REMOTE_APP=$kp_product_root/$kp_version" not in policy
            or any(base not in policy for base in PUBLIC_BASES)):
        raise WorkflowError("KSpeeder apps do not use the four-site versioned product mirror")

    runtime = False
    if native_bin is not None:
        native_bin = native_bin.resolve()
        if not native_bin.is_file() or not os.access(native_bin, os.X_OK):
            raise WorkflowError("--native-bin must be an executable zsetup binary")
        command_runner([sys.executable, "-B", root / "kspeeder/tests/binary_install_test.py", native_bin])
        runtime = True
    return {"applications": results, "native_runtime": runtime}


def add_native(parser, *, required=False):
    parser.add_argument("--native-bin", type=Path, required=required,
                        help="verified zsetup binary used by the KSpeeder HTTPS/runtime suite")


def add_deployment(parser, *, approval=False):
    add_native(parser, required=True)
    parser.add_argument("--server", required=True)
    parser.add_argument("--binary-root", required=True)
    parser.add_argument("--output-root", type=Path)
    if approval:
        parser.add_argument("--approve", required=True)
    parser.add_argument("--attempts", type=int, default=6)
    parser.add_argument("--delay", type=float, default=5)
    parser.add_argument("--workers", type=int, default=8)
    parser.add_argument("--timeout", type=float, default=60)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    sub = result.add_subparsers(dest="action", required=True)
    check = sub.add_parser("check", help="compare the lock to GitHub latest and validate apps")
    add_native(check)
    sub.add_parser("update-lock", help="atomically lock the latest stable GitHub release")
    prepare = sub.add_parser("prepare", help="validate latest/apps and build the immutable product package")
    add_native(prepare, required=True)
    prepare.add_argument("--output-root", type=Path)
    plan = sub.add_parser("plan", help="show the exact production paths without connecting")
    add_deployment(plan)
    publish = sub.add_parser("publish", help="stage, verify, activate and verify the product release")
    add_deployment(publish, approval=True)
    return result


def delegate(action: str, args) -> int:
    command = [sys.executable, "-B", PUBLISHER_PATH, action]
    if getattr(args, "server", None):
        command.extend(["--server", args.server, "--binary-root", args.binary_root])
    if getattr(args, "output_root", None):
        command.extend(["--output-root", args.output_root])
    if getattr(args, "approve", None):
        command.extend(["--approve", args.approve])
    if action == "publish":
        command.extend([
            "--attempts", args.attempts, "--delay", args.delay,
            "--workers", args.workers, "--timeout", args.timeout,
        ])
    return run(command, check=False).returncode


def main(argv=None) -> int:
    args = parser().parse_args(argv)
    try:
        latest = latest_lock()
        if args.action == "update-lock":
            changed = update_lock(latest)
            print(json.dumps({
                "changed": changed,
                "product_version": latest["product_version"],
                "next": "review and commit release/kspeeder-products.json, then run prepare",
            }, indent=2, sort_keys=True))
            return 0

        apps = validate_apps(native_bin=args.native_bin)
        current = lock_is_latest(latest)
        if args.action == "check":
            print(json.dumps({
                "apps": apps,
                "latest_version": latest["product_version"],
                "lock_is_latest": current,
                "release_inputs_clean": not bool(relevant_status()),
            }, indent=2, sort_keys=True))
            return 0 if current else 1

        require_latest_lock(latest)
        require_clean_candidate()
        if args.action in {"prepare", "plan", "publish"}:
            return delegate(args.action, args)
        raise WorkflowError("unsupported action")
    except (WorkflowError, publisher.ProductReleaseError, OSError, ValueError, KeyError,
            json.JSONDecodeError, subprocess.CalledProcessError) as error:
        print(f"KSpeeder release workflow: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
