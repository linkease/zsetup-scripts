#!/usr/bin/env python3
"""Package and publish the locked KSpeeder product mirror without deleting history."""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
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
DEFAULT_LOCK = ROOT / "release/kspeeder-products.json"
DEFAULT_OUTPUT = ROOT / "dist/kspeeder-products"
SSH_OPTIONS = ("-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+\Z")
SAFE_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,127}\Z")
SAFE_SERVER = re.compile(r"[A-Za-z0-9_.@:-]+\Z")
SAFE_COMPONENT = re.compile(r"[A-Za-z0-9._-]+\Z")


class ProductReleaseError(RuntimeError):
    pass


def run(command, *, capture=False, check=True):
    return subprocess.run([str(item) for item in command], check=check, text=True,
                          capture_output=capture)


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        while block := stream.read(1024 * 1024):
            value.update(block)
    return value.hexdigest()


def canonical_json(value) -> bytes:
    return (json.dumps(value, ensure_ascii=True, indent=2, sort_keys=True) + "\n").encode()


def load_lock(path: Path = DEFAULT_LOCK) -> dict:
    raw = path.read_bytes()
    data = json.loads(raw)
    if set(data) != {"schema_version", "product_version", "source", "public", "assets"}:
        raise ProductReleaseError("KSpeeder product lock fields differ from schema")
    if data["schema_version"] != 1 or not VERSION.fullmatch(data["product_version"]):
        raise ProductReleaseError("invalid KSpeeder product lock version")
    version = data["product_version"]
    source = data["source"]
    if set(source) != {"repository", "tag", "published_at", "download_base"}:
        raise ProductReleaseError("invalid release source fields")
    if source["repository"] != "kspeeder/docker_kspeeder" or source["tag"] != f"v{version}":
        raise ProductReleaseError("release source does not match product version")
    if source["download_base"] != (
        f"https://github.com/kspeeder/docker_kspeeder/releases/download/v{version}"
    ):
        raise ProductReleaseError("release download base is not canonical")
    public = data["public"]
    if set(public) != {"prefix", "bases", "root_pointers"} or public["prefix"] != "kspeeder":
        raise ProductReleaseError("invalid public product namespace")
    if public["root_pointers"] != ["version.txt", "ks-cli-version.txt"]:
        raise ProductReleaseError("invalid mutable pointer set")
    if len(public["bases"]) != 4 or len(set(public["bases"])) != 4:
        raise ProductReleaseError("exactly four unique public bases are required")
    for base in public["bases"]:
        parsed = urlsplit(base)
        if parsed.scheme != "https" or not parsed.netloc or parsed.query or parsed.fragment:
            raise ProductReleaseError("public bases must be plain HTTPS URLs")
    assets = data["assets"]
    if not isinstance(assets, list) or len(assets) != 10:
        raise ProductReleaseError("v0.9.1 release must contain exactly ten locked assets")
    seen = set()
    for asset in assets:
        if set(asset) != {"name", "size", "sha256"}:
            raise ProductReleaseError("invalid locked asset fields")
        name = asset["name"]
        if not isinstance(name, str) or not SAFE_NAME.fullmatch(name) or name in seen:
            raise ProductReleaseError("duplicate or unsafe locked asset name")
        if not isinstance(asset["size"], int) or asset["size"] <= 0:
            raise ProductReleaseError("invalid locked asset size")
        if not isinstance(asset["sha256"], str) or not SHA256.fullmatch(asset["sha256"]):
            raise ProductReleaseError("invalid locked asset digest")
        seen.add(name)
    required = {
        f"iStoreEnhance-binary-{version}.tar.gz", "iStoreEnhance-linux.amd64",
        "iStoreEnhance-linux.arm", "iStoreEnhance-linux.arm64",
        f"ks-cli-binary-{version}.tar.gz", "ks-cli-linux-amd64",
        "ks-cli-linux-arm", "ks-cli-linux-arm64", "version.txt", "ks-cli-version.txt",
    }
    if seen != required:
        raise ProductReleaseError("locked asset inventory is incomplete")
    return data


def release_identity(lock_path: Path = DEFAULT_LOCK) -> str:
    value = hashlib.sha256()
    value.update(lock_path.read_bytes())
    value.update(b"\0")
    value.update((ROOT / "scripts/install-kspeeder-product-release.sh").read_bytes())
    return value.hexdigest()


def default_fetch(url: str, destination: Path, expected_size: int, expected_sha: str) -> None:
    last_error = None
    for attempt in range(3):
        request = Request(url, headers={"User-Agent": "zsetup-scripts-product-release/1"})
        value = hashlib.sha256()
        size = 0
        try:
            with urlopen(request, timeout=60) as response, destination.open("wb") as output:
                if urlsplit(response.url).scheme != "https":
                    raise ProductReleaseError("asset download followed a non-HTTPS redirect")
                while block := response.read(1024 * 1024):
                    size += len(block)
                    if size > expected_size:
                        raise ProductReleaseError("asset exceeds locked size")
                    value.update(block)
                    output.write(block)
            if size != expected_size or value.hexdigest() != expected_sha:
                raise ProductReleaseError("asset size or SHA256 differs from lock")
            return
        except Exception as error:
            last_error = error
            destination.unlink(missing_ok=True)
            if attempt < 2:
                time.sleep(attempt + 1)
    raise ProductReleaseError(f"asset download failed after three attempts: {last_error}")


def validate_metadata(directory: Path, lock: dict) -> None:
    version = lock["product_version"]
    by_name = {asset["name"]: asset for asset in lock["assets"]}
    values = {}
    for metadata in ("version.txt", "ks-cli-version.txt"):
        entries = {}
        for line in (directory / metadata).read_text(encoding="utf-8").splitlines():
            if not line:
                continue
            if "=" not in line:
                raise ProductReleaseError(f"invalid metadata line in {metadata}")
            key, value = line.split("=", 1)
            if key in entries:
                raise ProductReleaseError(f"duplicate metadata key in {metadata}")
            entries[key] = value
        if entries.get("VERSION") != version:
            raise ProductReleaseError(f"{metadata} version differs from lock")
        values[metadata] = entries
    for arch in ("amd64", "arm", "arm64"):
        if values["version.txt"].get(f"SHA256_linux_{arch}") != by_name[f"iStoreEnhance-linux.{arch}"]["sha256"]:
            raise ProductReleaseError("KSpeeder Linux metadata digest differs from locked asset")
        if values["ks-cli-version.txt"].get(f"SHA256_linux_{arch}") != by_name[f"ks-cli-linux-{arch}"]["sha256"]:
            raise ProductReleaseError("KS-CLI Linux metadata digest differs from locked asset")
    if values["ks-cli-version.txt"].get("SHA256_openwrt_bundle") != by_name[f"ks-cli-binary-{version}.tar.gz"]["sha256"]:
        raise ProductReleaseError("KS-CLI bundle metadata digest differs from locked asset")


def validate_package(package: Path, identity: str, lock: dict, *, require_name: bool = True) -> dict:
    if (not package.is_dir() or package.is_symlink()
            or (require_name and package.name != identity)):
        raise ProductReleaseError("product release package is missing or has the wrong identity")
    state = (package / "release-state.txt").read_text(encoding="utf-8").splitlines()
    if state != [lock["product_version"], identity]:
        raise ProductReleaseError("product release state differs from lock")
    checks = (package / "PACKAGE-SHA256SUMS").read_text(encoding="utf-8").splitlines()
    if not checks:
        raise ProductReleaseError("product package checksum list is empty")
    for line in checks:
        match = re.fullmatch(r"([0-9a-f]{64})  ([^\s]+)", line)
        if not match or digest(package / match[2]) != match[1]:
            raise ProductReleaseError("product package checksum failed")
    immutable = package / "immutable/kspeeder" / lock["product_version"]
    records = (immutable / "SHA256SUMS").read_text(encoding="utf-8").splitlines()
    if len(records) != 11:
        raise ProductReleaseError("immutable product checksum set is incomplete")
    for line in records:
        match = re.fullmatch(r"([0-9a-f]{64})  ([^\s]+)", line)
        if not match or digest(immutable / match[2]) != match[1]:
            raise ProductReleaseError("immutable product checksum failed")
    validate_metadata(immutable, lock)
    for pointer in lock["public"]["root_pointers"]:
        if (package / "pointers/kspeeder" / pointer).read_bytes() != (immutable / pointer).read_bytes():
            raise ProductReleaseError("root pointer differs from immutable metadata")
    manifest = json.loads((immutable / "release-manifest.json").read_text(encoding="utf-8"))
    if manifest.get("release_id") != identity or manifest.get("product_version") != lock["product_version"]:
        raise ProductReleaseError("immutable release manifest differs from package")
    return manifest


def prepare_release(lock_path: Path = DEFAULT_LOCK, output_root: Path = DEFAULT_OUTPUT,
                    *, fetch=default_fetch, require_clean: bool = True) -> Path:
    lock = load_lock(lock_path)
    identity = release_identity(lock_path)
    if require_clean:
        relative = lock_path.resolve().relative_to(ROOT.resolve())
        status = run(["git", "-C", ROOT, "status", "--porcelain=v1", "--", relative,
                      "scripts/install-kspeeder-product-release.sh"], capture=True).stdout
        if status:
            raise ProductReleaseError("product lock and transaction must be committed and clean")
    output_root.mkdir(parents=True, exist_ok=True)
    destination = output_root / identity
    if destination.exists():
        validate_package(destination, identity, lock)
        return destination
    temporary = Path(tempfile.mkdtemp(prefix=f".{identity}.", dir=output_root))
    try:
        version_dir = temporary / "immutable/kspeeder" / lock["product_version"]
        version_dir.mkdir(parents=True)
        for asset in lock["assets"]:
            fetch(f"{lock['source']['download_base']}/{asset['name']}", version_dir / asset["name"],
                  asset["size"], asset["sha256"])
        validate_metadata(version_dir, lock)
        manifest = {
            "schema_version": 1,
            "release_id": identity,
            "product_version": lock["product_version"],
            "source": lock["source"],
            "lock_sha256": digest(lock_path),
            "public_prefix": lock["public"]["prefix"],
            "assets": lock["assets"],
            "source_commit": run(["git", "-C", ROOT, "rev-parse", "HEAD"], capture=True).stdout.strip(),
            "deletes_existing_files": False,
        }
        (version_dir / "release-manifest.json").write_bytes(canonical_json(manifest))
        immutable_files = sorted(path for path in version_dir.iterdir() if path.is_file())
        (version_dir / "SHA256SUMS").write_text(
            "".join(f"{digest(path)}  {path.name}\n" for path in immutable_files), encoding="ascii"
        )
        pointer_root = temporary / "pointers/kspeeder"
        pointer_root.mkdir(parents=True)
        for pointer in lock["public"]["root_pointers"]:
            shutil.copy2(version_dir / pointer, pointer_root / pointer)
        shutil.copy2(ROOT / "scripts/install-kspeeder-product-release.sh",
                     temporary / "install-kspeeder-product-release.sh")
        (temporary / "install-kspeeder-product-release.sh").chmod(0o755)
        (temporary / "release-state.txt").write_text(
            f"{lock['product_version']}\n{identity}\n", encoding="ascii"
        )
        checks = sorted(path for path in temporary.rglob("*") if path.is_file())
        (temporary / "PACKAGE-SHA256SUMS").write_text(
            "".join(f"{digest(path)}  {path.relative_to(temporary).as_posix()}\n" for path in checks),
            encoding="ascii",
        )
        validate_package(temporary, identity, lock, require_name=False)
        temporary.replace(destination)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)
    return destination


def validate_server(server: str) -> None:
    if not SAFE_SERVER.fullmatch(server) or server.startswith("-"):
        raise ProductReleaseError("unsafe SSH server")


def validate_binary_root(value: str) -> PurePosixPath:
    path = PurePosixPath(value)
    if (not value.startswith("/") or path.name != "binary" or len(path.parts) < 4
            or any(part in {"", ".", ".."} or not SAFE_COMPONENT.fullmatch(part)
                   for part in path.parts[1:])):
        raise ProductReleaseError("binary root must be a safe absolute path ending in /binary")
    return path


def remote_paths(binary_root: str, identity: str) -> tuple[PurePosixPath, PurePosixPath]:
    if not SHA256.fullmatch(identity):
        raise ProductReleaseError("release id must be a lowercase SHA256")
    binary = validate_binary_root(binary_root)
    return (binary / "kspeeder",
            binary.parent.parent / ".zsetup-scripts-releases/kspeeder-products" / identity)


def ssh_command(server: str, *command) -> list[str]:
    validate_server(server)
    return ["ssh", *SSH_OPTIONS, server, *(str(item) for item in command)]


def remote_exists(server: str, path: PurePosixPath) -> bool:
    result = run(ssh_command(server, "test", "-e", path), check=False)
    if result.returncode not in {0, 1}:
        raise ProductReleaseError("cannot inspect remote product release")
    return result.returncode == 0


def upload_release(server: str, binary_root: str, package: Path) -> PurePosixPath:
    _, remote = remote_paths(binary_root, package.name)
    run(ssh_command(server, "mkdir", "-p", remote.parent))
    if not remote_exists(server, remote):
        run(["scp", *SSH_OPTIONS, "-r", package, f"{server}:{remote.parent}/"])
    return remote


def remote_action(server: str, binary_root: str, identity: str, mode: str) -> None:
    if mode not in {"stage", "activate", "verify", "rollback"}:
        raise ProductReleaseError("invalid product release action")
    _, remote = remote_paths(binary_root, identity)
    if not remote_exists(server, remote):
        raise ProductReleaseError("remote product release is missing")
    run(ssh_command(server, "sh", remote / "install-kspeeder-product-release.sh", mode,
                    remote, validate_binary_root(binary_root)))


def require_approval(value: str | None, identity: str) -> None:
    if value != identity:
        raise ProductReleaseError(f"remote mutation requires --approve {identity}")


def fetch_public(url: str, expected: str, expected_size: int, *, timeout: float) -> None:
    request = Request(url, headers={"Cache-Control": "no-cache", "Pragma": "no-cache"})
    value = hashlib.sha256()
    size = 0
    with urlopen(request, timeout=timeout) as response:
        if urlsplit(response.url).scheme != "https":
            raise ProductReleaseError("public check followed a non-HTTPS redirect")
        while block := response.read(1024 * 1024):
            size += len(block)
            if size > expected_size:
                raise ProductReleaseError("public file exceeds candidate size")
            value.update(block)
    if size != expected_size or value.hexdigest() != expected:
        raise ProductReleaseError("public product bytes differ from candidate")


def public_records(package: Path, lock: dict, *, immutable_only: bool) -> list[tuple[str, Path]]:
    version = lock["product_version"]
    immutable = package / "immutable/kspeeder" / version
    records = [(f"kspeeder/{version}/{path.name}", path)
               for path in sorted(immutable.iterdir()) if path.is_file()]
    if not immutable_only:
        records.extend((f"kspeeder/{name}", package / "pointers/kspeeder" / name)
                       for name in lock["public"]["root_pointers"])
    return records


def verify_public(package: Path, lock: dict, *, immutable_only: bool, attempts: int = 6,
                  delay: float = 5, workers: int = 8, timeout: float = 60,
                  fetch=fetch_public) -> int:
    if attempts < 1 or delay < 0 or workers < 1 or timeout <= 0:
        raise ProductReleaseError("invalid public verification retry values")
    validate_package(package, package.name, lock)
    query = urlencode({"kspeeder-release": package.name})
    checks = [(f"{base.rstrip('/')}/{relative}?{query}", path)
              for base in lock["public"]["bases"]
              for relative, path in public_records(package, lock, immutable_only=immutable_only)]

    def check(item):
        url, path = item
        error = None
        for attempt in range(attempts):
            try:
                fetch(url, digest(path), path.stat().st_size, timeout=timeout)
                return url, None
            except Exception as caught:
                error = caught
                if attempt + 1 < attempts:
                    time.sleep(delay)
        return url, error

    failures = []
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = [pool.submit(check, item) for item in checks]
        for future in as_completed(futures):
            url, error = future.result()
            if error is not None:
                failures.append(f"{url}: {error}")
    if failures:
        raise ProductReleaseError(
            f"{len(failures)} of {len(checks)} public product checks failed\n" + "\n".join(failures[:20])
        )
    return len(checks)


def add_remote(parser, *, release_id=False, approve=False, retries=False):
    parser.add_argument("--server", required=True)
    parser.add_argument("--binary-root", required=True)
    parser.add_argument("--output-root", type=Path, default=DEFAULT_OUTPUT)
    if release_id:
        parser.add_argument("--release-id", required=True)
    if approve:
        parser.add_argument("--approve", required=True)
    if retries:
        parser.add_argument("--attempts", type=int, default=6)
        parser.add_argument("--delay", type=float, default=5)
        parser.add_argument("--workers", type=int, default=8)
        parser.add_argument("--timeout", type=float, default=60)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    sub = result.add_subparsers(dest="action", required=True)
    prepare = sub.add_parser("prepare")
    prepare.add_argument("--output-root", type=Path, default=DEFAULT_OUTPUT)
    plan = sub.add_parser("plan")
    add_remote(plan)
    stage = sub.add_parser("stage")
    add_remote(stage, approve=True, retries=True)
    staged = sub.add_parser("verify-staged")
    add_remote(staged, release_id=True, retries=True)
    publish = sub.add_parser("publish")
    add_remote(publish, approve=True, retries=True)
    activate = sub.add_parser("activate")
    add_remote(activate, release_id=True, approve=True)
    verify = sub.add_parser("verify")
    add_remote(verify, release_id=True, retries=True)
    rollback = sub.add_parser("rollback")
    add_remote(rollback, release_id=True, approve=True)
    return result


def main(argv=None) -> int:
    args = parser().parse_args(argv)
    try:
        lock = load_lock()
        if args.action in {"prepare", "plan", "stage", "publish"}:
            package = prepare_release(output_root=args.output_root)
            identity = package.name
        else:
            identity = args.release_id
            package = args.output_root / identity
            validate_package(package, identity, lock)
        if args.action == "prepare":
            print(json.dumps(validate_package(package, identity, lock), indent=2, sort_keys=True))
            return 0
        public, remote = remote_paths(args.binary_root, identity)
        if args.action == "plan":
            print(json.dumps({"release_id": identity, "product_version": lock["product_version"],
                              "server": args.server, "public_root": str(public),
                              "remote_release": str(remote), "deletes_existing_files": False,
                              "remote_mutation": False}, indent=2, sort_keys=True))
            return 0
        if args.action == "stage":
            require_approval(args.approve, identity)
            upload_release(args.server, args.binary_root, package)
            remote_action(args.server, args.binary_root, identity, "stage")
            count = verify_public(package, lock, immutable_only=True, attempts=args.attempts,
                                  delay=args.delay, workers=args.workers, timeout=args.timeout)
            print(f"Staged KSpeeder {lock['product_version']}; {count} immutable public checks passed")
            return 0
        if args.action == "verify-staged":
            count = verify_public(package, lock, immutable_only=True, attempts=args.attempts,
                                  delay=args.delay, workers=args.workers, timeout=args.timeout)
            print(f"Verified staged KSpeeder {lock['product_version']} with {count} public checks")
            return 0
        if args.action == "publish":
            require_approval(args.approve, identity)
            upload_release(args.server, args.binary_root, package)
            remote_action(args.server, args.binary_root, identity, "stage")
            immutable = verify_public(package, lock, immutable_only=True, attempts=args.attempts,
                                      delay=args.delay, workers=args.workers, timeout=args.timeout)
            remote_action(args.server, args.binary_root, identity, "activate")
            remote_action(args.server, args.binary_root, identity, "verify")
            final = verify_public(package, lock, immutable_only=False, attempts=args.attempts,
                                  delay=args.delay, workers=args.workers, timeout=args.timeout)
            print(f"Published KSpeeder {lock['product_version']}; {immutable} immutable and {final} final checks passed")
            return 0
        if args.action == "activate":
            require_approval(args.approve, identity)
            remote_action(args.server, args.binary_root, identity, "activate")
            return 0
        if args.action == "verify":
            remote_action(args.server, args.binary_root, identity, "verify")
            count = verify_public(package, lock, immutable_only=False, attempts=args.attempts,
                                  delay=args.delay, workers=args.workers, timeout=args.timeout)
            print(f"Verified KSpeeder {lock['product_version']} with {count} public checks")
            return 0
        if args.action == "rollback":
            require_approval(args.approve, identity)
            remote_action(args.server, args.binary_root, identity, "rollback")
            return 0
        raise ProductReleaseError("unsupported action")
    except (ProductReleaseError, OSError, ValueError, KeyError, json.JSONDecodeError,
            subprocess.CalledProcessError) as error:
        print(f"KSpeeder product publication: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
