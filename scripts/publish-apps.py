#!/usr/bin/env python3
"""Prepare and publish the complete apps/ tree under one fixed namespace.

This is the production coordinator.  It deliberately derives the public
destination as BINARY_ROOT/zsetup-scripts/apps; callers cannot provide a
different destination.  The lower-level publish.sh transaction is bundled
with each release and runs on the target server.
"""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parents[1]
PUBLIC_SUBPATH = PurePosixPath("zsetup-scripts/apps")
RELEASES_DIRECTORY = ".zsetup-scripts-releases"
SSH_OPTIONS = ("-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes")
RELEASE_ID = re.compile(r"[0-9a-f]{64}\Z")
SAFE_SERVER = re.compile(r"[A-Za-z0-9_.@:-]+\Z")
SAFE_COMPONENT = re.compile(r"[A-Za-z0-9._-]+\Z")
VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?\Z")


class PublicationError(RuntimeError):
    pass


def run(command, *, cwd=None, capture=False, check=True):
    return subprocess.run(
        [str(item) for item in command], cwd=cwd, check=check, text=True,
        capture_output=capture,
    )


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        while block := stream.read(1024 * 1024):
            value.update(block)
    return value.hexdigest()


def read_manifest(apps: Path) -> list[tuple[str, str]]:
    manifest = apps / "SHA256SUMS"
    if not manifest.is_file() or manifest.is_symlink():
        raise PublicationError("apps/SHA256SUMS is missing or unsafe")
    records: list[tuple[str, str]] = []
    seen: set[str] = set()
    for line in manifest.read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([^\s]+)", line)
        if not match:
            raise PublicationError("apps/SHA256SUMS has an invalid record")
        expected, relative = match.groups()
        parts = PurePosixPath(relative).parts
        if (not parts or relative in seen
                or any(part in {"", ".", ".."} or not SAFE_COMPONENT.fullmatch(part)
                       for part in parts)):
            raise PublicationError("apps/SHA256SUMS has a duplicate or unsafe path")
        path = apps.joinpath(*parts)
        if not path.is_file() or path.is_symlink() or digest(path) != expected:
            raise PublicationError(f"apps checksum failed: {relative}")
        seen.add(relative)
        records.append((expected, relative))
    if not records:
        raise PublicationError("apps/SHA256SUMS is empty")
    return records


def release_identity(apps: Path) -> str:
    return digest(apps / "SHA256SUMS")


def source_commit(root: Path) -> str:
    result = run(["git", "-C", root, "rev-parse", "HEAD"], capture=True)
    return result.stdout.strip()


def validate_candidate(root: Path, *, require_clean: bool = True) -> tuple[str, list[tuple[str, str]]]:
    apps = root / "apps"
    run([sys.executable, "-B", root / "scripts/build.py", "--check"])
    run([sys.executable, "-B", root / "scripts/check-public-tree.py", apps])
    records = read_manifest(apps)
    identity = release_identity(apps)
    if require_clean:
        status = run(
            ["git", "-C", root, "status", "--porcelain=v1", "--", "apps"],
            capture=True,
        ).stdout
        if status:
            raise PublicationError("apps candidate must be committed and clean")
    return identity, records


def release_metadata(root: Path, identity: str, records: list[tuple[str, str]]) -> dict:
    linux = json.loads((root / "apps/zsetup/config.json").read_text(encoding="utf-8"))
    windows = json.loads((root / "apps/zsetup/config-windows.json").read_text(encoding="utf-8"))
    applications = sorted(path.parent.name for path in (root / "apps").glob("*/app.json"))
    return {
        "schema_version": 1,
        "release_id": identity,
        "source_commit": source_commit(root),
        "source_directory": "apps",
        "public_subpath": str(PUBLIC_SUBPATH),
        "applications": applications,
        "file_count": len(records) + 1,
        "linux_config_version": linux["config_version"],
        "linux_installer_records": len(linux["installers"]),
        "windows_config_version": windows["config_version"],
        "windows_installer_records": len(windows["installers"]),
        "published": False,
    }


def write_release_checksums(release: Path) -> None:
    names = ("apps/SHA256SUMS", "publish.sh", "release.json")
    text = "".join(f"{digest(release / name)}  {name}\n" for name in names)
    (release / "RELEASE-SHA256SUMS").write_text(text, encoding="utf-8")


def validate_release(release: Path, identity: str, *, require_name: bool = True) -> dict:
    if (not release.is_dir() or release.is_symlink()
            or (require_name and release.name != identity)):
        raise PublicationError("release directory is missing or has the wrong identity")
    metadata = json.loads((release / "release.json").read_text(encoding="utf-8"))
    if metadata.get("release_id") != identity or metadata.get("public_subpath") != str(PUBLIC_SUBPATH):
        raise PublicationError("release metadata does not match the required namespace")
    expected_names = {"apps/SHA256SUMS", "publish.sh", "release.json"}
    checked_names = set()
    for line in (release / "RELEASE-SHA256SUMS").read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([^\s]+)", line)
        if (not match or match[2] not in expected_names or match[2] in checked_names
                or digest(release / match[2]) != match[1]):
            raise PublicationError("release coordinator checksum failed")
        checked_names.add(match[2])
    if checked_names != expected_names:
        raise PublicationError("release coordinator checksum set is incomplete")
    if release_identity(release / "apps") != identity:
        raise PublicationError("release apps identity does not match")
    read_manifest(release / "apps")
    return metadata


def prepare_release(root: Path = ROOT, output_root: Path | None = None,
                    *, require_clean: bool = True) -> Path:
    identity, records = validate_candidate(root, require_clean=require_clean)
    output_root = output_root or root / "dist/apps-releases"
    output_root.mkdir(parents=True, exist_ok=True)
    destination = output_root / identity
    if destination.exists():
        validate_release(destination, identity)
        return destination
    temporary = Path(tempfile.mkdtemp(prefix=f".{identity}.", dir=output_root))
    try:
        shutil.copytree(root / "apps", temporary / "apps", copy_function=shutil.copy2)
        shutil.copy2(root / "scripts/publish.sh", temporary / "publish.sh")
        (temporary / "publish.sh").chmod(0o755)
        metadata = release_metadata(root, identity, records)
        (temporary / "release.json").write_text(
            json.dumps(metadata, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        write_release_checksums(temporary)
        validate_release(temporary, identity, require_name=False)
        temporary.replace(destination)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)
    return destination


def validate_server(server: str) -> str:
    if not SAFE_SERVER.fullmatch(server) or server.startswith("-"):
        raise PublicationError("unsafe SSH server; use an SSH config host or user@host")
    return server


def validate_remote_path(value: str, *, binary_root: bool = False) -> PurePosixPath:
    path = PurePosixPath(value)
    if not value.startswith("/") or value == "/" or any(
        part in {"", ".", ".."} or not SAFE_COMPONENT.fullmatch(part)
        for part in path.parts[1:]
    ):
        raise PublicationError("remote path must be a safe absolute POSIX path")
    if binary_root and (path.name != "binary" or len(path.parts) < 4):
        raise PublicationError("binary root must be an absolute path ending in /binary")
    return path


def deployment_paths(binary_root: str, identity: str) -> tuple[PurePosixPath, PurePosixPath]:
    if not RELEASE_ID.fullmatch(identity):
        raise PublicationError("release id must be a lowercase SHA256")
    binary = validate_remote_path(binary_root, binary_root=True)
    public_apps = binary / PUBLIC_SUBPATH
    private_release = binary.parent.parent / RELEASES_DIRECTORY / identity
    return public_apps, private_release


def require_approval(approved: str | None, identity: str) -> None:
    if approved != identity:
        raise PublicationError(f"remote mutation requires --approve {identity}")


def ssh_command(server: str, *remote: object) -> list[str]:
    validate_server(server)
    return ["ssh", *SSH_OPTIONS, server, *(str(item) for item in remote)]


def scp_command(source: Path, server: str, destination: PurePosixPath) -> list[str]:
    validate_server(server)
    return ["scp", *SSH_OPTIONS, "-r", str(source), f"{server}:{destination}/"]


def remote_exists(server: str, path: PurePosixPath) -> bool:
    result = run(ssh_command(server, "test", "-e", path), check=False)
    if result.returncode not in {0, 1}:
        raise PublicationError(f"cannot inspect remote release path: {path}")
    return result.returncode == 0


def upload_release(server: str, binary_root: str, release: Path) -> PurePosixPath:
    identity = release.name
    validate_release(release, identity)
    _, remote_release = deployment_paths(binary_root, identity)
    parent = remote_release.parent
    run(ssh_command(server, "mkdir", "-p", parent))
    if not remote_exists(server, remote_release):
        run(scp_command(release, server, parent))
    # The transaction independently verifies every apps byte and the release id.
    return remote_release


def ensure_public_destination(server: str, binary_root: str, identity: str) -> PurePosixPath:
    public_apps, _ = deployment_paths(binary_root, identity)
    binary = validate_remote_path(binary_root, binary_root=True)
    run(ssh_command(server, "test", "-d", binary))
    run(ssh_command(server, "test", "!", "-L", binary))
    run(ssh_command(server, "mkdir", "-p", public_apps))
    run(ssh_command(server, "test", "!", "-L", public_apps.parent))
    run(ssh_command(server, "test", "-d", public_apps))
    run(ssh_command(server, "test", "!", "-L", public_apps))
    return public_apps


def remote_action(server: str, binary_root: str, identity: str, mode: str) -> None:
    if mode not in {"stage", "activate", "verify", "rollback"}:
        raise PublicationError("invalid remote publication action")
    public_apps, remote_release = deployment_paths(binary_root, identity)
    if mode == "stage":
        ensure_public_destination(server, binary_root, identity)
    if not remote_exists(server, remote_release):
        raise PublicationError(f"remote release is missing: {remote_release}")
    run(ssh_command(
        server, "env", f"ZSETUP_PUBLISH_PREVALIDATED_RELEASE_ID={identity}",
        "sh", remote_release / "publish.sh", mode, remote_release / "apps", public_apps,
    ))


def public_bases(apps: Path) -> list[str]:
    values: list[str] = []
    for name in ("base.json", "base-windows.json"):
        data = json.loads((apps / "zsetup" / name).read_text(encoding="utf-8"))
        if data.get("public_path_prefix") != str(PUBLIC_SUBPATH):
            raise PublicationError(f"{name} has the wrong public_path_prefix")
        for group in data["source_groups"]:
            values.extend(group["primary_bases"])
            values.append(group["fallback_base"])
    unique: list[str] = []
    for value in values:
        parsed = urlsplit(value)
        if parsed.scheme != "https" or not parsed.netloc or parsed.query or parsed.fragment:
            raise PublicationError("public source base must be a plain HTTPS URL")
        if value not in unique:
            unique.append(value.rstrip("/"))
    return unique


def is_immutable(relative: str) -> bool:
    parts = PurePosixPath(relative).parts
    return len(parts) >= 3 and VERSION.fullmatch(parts[1]) is not None


def fetch_public(url: str, expected: str, expected_size: int, *, timeout: float) -> None:
    request = Request(url, headers={"Cache-Control": "no-cache", "Pragma": "no-cache"})
    value = hashlib.sha256()
    size = 0
    with urlopen(request, timeout=timeout) as response:
        if urlsplit(response.url).scheme != "https":
            raise PublicationError("public verification followed a non-HTTPS redirect")
        while block := response.read(1024 * 1024):
            size += len(block)
            if size > expected_size:
                raise PublicationError("public file is larger than the candidate")
            value.update(block)
    if size != expected_size or value.hexdigest() != expected:
        raise PublicationError("public file differs from the candidate")


def verify_public(release: Path, *, immutable_only: bool, attempts: int = 6,
                  delay: float = 5.0, workers: int = 8, timeout: float = 30.0,
                  fetch=fetch_public) -> int:
    if attempts < 1 or delay < 0 or workers < 1 or timeout <= 0:
        raise PublicationError("public verification retry values are invalid")
    identity = release.name
    validate_release(release, identity)
    apps = release / "apps"
    records = [record for record in read_manifest(apps)
               if not immutable_only or is_immutable(record[1])]
    if not immutable_only:
        records.append((digest(apps / "SHA256SUMS"), "SHA256SUMS"))
    checks = []
    query = urlencode({"zsetup-release": identity})
    for base in public_bases(apps):
        for expected, relative in records:
            path = apps / relative
            url = f"{base}/{PUBLIC_SUBPATH}/{relative}?{query}"
            checks.append((url, expected, path.stat().st_size))

    def check(item):
        url, expected, size = item
        last_error: Exception | None = None
        for attempt in range(attempts):
            try:
                fetch(url, expected, size, timeout=timeout)
                return url, None
            except Exception as error:  # Network/CDN errors are reported together.
                last_error = error
                if attempt + 1 < attempts:
                    time.sleep(delay)
        return url, last_error

    failures = []
    with ThreadPoolExecutor(max_workers=workers) as executor:
        futures = [executor.submit(check, item) for item in checks]
        for future in as_completed(futures):
            url, error = future.result()
            if error is not None:
                failures.append(f"{url}: {error}")
    if failures:
        sample = "\n".join(failures[:20])
        raise PublicationError(
            f"{len(failures)} of {len(checks)} public byte checks failed\n{sample}"
        )
    return len(checks)


def output_root(value: str | None) -> Path:
    return Path(value).resolve() if value else ROOT / "dist/apps-releases"


def existing_release(identity: str, value: str | None) -> Path:
    if not RELEASE_ID.fullmatch(identity):
        raise PublicationError("release id must be a lowercase SHA256")
    release = output_root(value) / identity
    validate_release(release, identity)
    return release


def add_deployment_arguments(parser, *, release_id=False, approve=False):
    parser.add_argument("--server", required=True, help="SSH config host or user@host")
    parser.add_argument("--binary-root", required=True,
                        help="absolute server Web binary root; destination is always zsetup-scripts/apps")
    parser.add_argument("--output-root", help="local immutable release store")
    if release_id:
        parser.add_argument("--release-id", required=True)
    if approve:
        parser.add_argument("--approve", required=True,
                            help="exact release id authorizing this remote mutation")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    sub = result.add_subparsers(dest="action", required=True)
    prepare = sub.add_parser("prepare", help="validate apps and create an immutable local release")
    prepare.add_argument("--output-root")
    plan = sub.add_parser("plan", help="show the fixed local and remote paths; do not connect")
    add_deployment_arguments(plan)
    stage = sub.add_parser("stage", help="upload and stage immutable app payloads")
    add_deployment_arguments(stage, approve=True)
    staged = sub.add_parser("verify-staged", help="verify staged immutable files on every mirror")
    add_deployment_arguments(staged, release_id=True)
    publish = sub.add_parser("publish", help="stage, public-check, activate and verify")
    add_deployment_arguments(publish, approve=True)
    activate = sub.add_parser("activate", help="activate an already staged release")
    add_deployment_arguments(activate, release_id=True, approve=True)
    verify = sub.add_parser("verify", help="verify server and all public mirrors read-only")
    add_deployment_arguments(verify, release_id=True)
    rollback = sub.add_parser("rollback", help="restore mutable files for an active release")
    add_deployment_arguments(rollback, release_id=True, approve=True)
    for item in (stage, staged, publish, verify):
        item.add_argument("--attempts", type=int, default=6)
        item.add_argument("--delay", type=float, default=5.0)
        item.add_argument("--workers", type=int, default=8)
        item.add_argument("--timeout", type=float, default=30.0)
    return result


def main(argv=None) -> int:
    args = parser().parse_args(argv)
    try:
        if args.action == "prepare":
            release = prepare_release(output_root=output_root(args.output_root))
            metadata = validate_release(release, release.name)
            print(json.dumps(metadata, ensure_ascii=False, indent=2, sort_keys=True))
            return 0

        if args.action in {"plan", "stage", "publish"}:
            release = prepare_release(output_root=output_root(args.output_root))
            identity = release.name
        else:
            identity = args.release_id
            release = (existing_release(identity, args.output_root)
                       if args.action in {"verify-staged", "verify"} else None)
        public_apps, remote_release = deployment_paths(args.binary_root, identity)

        if args.action == "plan":
            print(json.dumps({
                "release_id": identity,
                "local_release": str(release),
                "server": validate_server(args.server),
                "remote_release": str(remote_release),
                "public_apps": str(public_apps),
                "remote_mutation": False,
            }, indent=2, sort_keys=True))
            return 0

        if args.action == "stage":
            require_approval(args.approve, identity)
            upload_release(args.server, args.binary_root, release)
            remote_action(args.server, args.binary_root, identity, "stage")
            checks = verify_public(
                release, immutable_only=True, attempts=args.attempts, delay=args.delay,
                workers=args.workers, timeout=args.timeout,
            )
            print(
                f"Staged apps release {identity}; {checks} immutable public checks passed; "
                "mutable entries remain unchanged"
            )
            return 0

        if args.action == "verify-staged":
            checks = verify_public(
                release, immutable_only=True, attempts=args.attempts, delay=args.delay,
                workers=args.workers, timeout=args.timeout,
            )
            print(f"Verified staged apps release {identity} with {checks} immutable public checks")
            return 0

        if args.action == "publish":
            require_approval(args.approve, identity)
            upload_release(args.server, args.binary_root, release)
            remote_action(args.server, args.binary_root, identity, "stage")
            immutable_checks = verify_public(
                release, immutable_only=True, attempts=args.attempts, delay=args.delay,
                workers=args.workers, timeout=args.timeout,
            )
            remote_action(args.server, args.binary_root, identity, "activate")
            remote_action(args.server, args.binary_root, identity, "verify")
            full_checks = verify_public(
                release, immutable_only=False, attempts=args.attempts, delay=args.delay,
                workers=args.workers, timeout=args.timeout,
            )
            print(
                f"Published apps release {identity}; "
                f"{immutable_checks} immutable and {full_checks} final public checks passed"
            )
            return 0

        if args.action == "activate":
            require_approval(args.approve, identity)
            remote_action(args.server, args.binary_root, identity, "activate")
            print(f"Activated apps release {identity}; run verify before declaring success")
            return 0

        if args.action == "verify":
            remote_action(args.server, args.binary_root, identity, "verify")
            checks = verify_public(
                release, immutable_only=False, attempts=args.attempts, delay=args.delay,
                workers=args.workers, timeout=args.timeout,
            )
            print(f"Verified apps release {identity} with {checks} public byte checks")
            return 0

        if args.action == "rollback":
            require_approval(args.approve, identity)
            remote_action(args.server, args.binary_root, identity, "rollback")
            print(f"Rolled back mutable files for apps release {identity}")
            return 0
        raise PublicationError("unsupported action")
    except (PublicationError, OSError, subprocess.CalledProcessError, ValueError, KeyError) as error:
        print(f"apps publication: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
