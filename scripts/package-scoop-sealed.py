#!/usr/bin/env python3
"""Build a deterministic, fully locked Scoop rescue bundle without networking."""
import argparse
import hashlib
import json
from pathlib import Path
import tempfile
import zipfile

RUNTIME_ID = "0.7.16-08aea475819b8037977684c7fbbde2ae40bb1b96-windows-amd64"
LOCKS = {
    "runtime-bundle.zip": (38021762, "66fa51769556b8d52289f354d3e43952338814b6ef357b04868f829fc1c5c4dc"),
    "scoop-core.zip": (1289426, "fa96b15950f3726d2c9a35493e192eefe56d2eddba718e8121c32f7a19257a0a"),
    "scoop-main.zip": (1266906, "4287b169ce39f3a6566da666ce3c8b73f450c887d9a71481485b2ad2ca951636"),
}
CORE_COMMIT = "e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f"
MAIN_COMMIT = "1eca0759af467b38ae87b9579dd545d35f5b9917"
STAMP = (1980, 1, 1, 0, 0, 0)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(",", ":")) + "\n").encode()


def read_locked(path, name):
    data = path.read_bytes()
    size, sha256 = LOCKS[name]
    if len(data) != size or digest(data) != sha256:
        raise ValueError(f"{name} does not match the immutable lock")
    return data


def add_file(archive, name, data):
    info = zipfile.ZipInfo(name, STAMP)
    info.compress_type = zipfile.ZIP_STORED
    info.external_attr = 0o100600 << 16
    archive.writestr(info, data)


def build(args):
    if args.output.exists() or args.output.is_symlink():
        raise ValueError("output already exists")
    payloads = {
        "runtime-bundle.zip": read_locked(args.runtime_bundle, "runtime-bundle.zip"),
        "scoop-core.zip": read_locked(args.core, "scoop-core.zip"),
        "scoop-main.zip": read_locked(args.main, "scoop-main.zip"),
    }
    plan = {
        "schema_version": 1, "operation": "scoop-bootstrap",
        "required_capabilities": ["download-gateway.v1", "route.github-archive.v1"],
        "artifacts": [
            {"role": "core", "repository": "ScoopInstaller/Scoop", "commit": CORE_COMMIT,
             "url": f"https://github.com/ScoopInstaller/Scoop/archive/{CORE_COMMIT}.zip",
             "sha256": LOCKS["scoop-core.zip"][1], "size": LOCKS["scoop-core.zip"][0]},
            {"role": "main", "repository": "ScoopInstaller/Main", "commit": MAIN_COMMIT,
             "url": f"https://github.com/ScoopInstaller/Main/archive/{MAIN_COMMIT}.zip",
             "sha256": LOCKS["scoop-main.zip"][1], "size": LOCKS["scoop-main.zip"][0]},
        ],
    }
    payloads["bootstrap-plan.json"] = json_bytes(plan)
    payloads["runtime-release.json"] = json_bytes({
        "schema_version": 1, "bundle_id": RUNTIME_ID,
        "bundle_size": LOCKS["runtime-bundle.zip"][0], "bundle_sha256": LOCKS["runtime-bundle.zip"][1],
    })
    manifest = {
        "schema_version": 1, "bundle_type": "linkease-scoop-sealed-v1",
        "runtime_bundle_id": RUNTIME_ID, "core_commit": CORE_COMMIT, "main_commit": MAIN_COMMIT,
        "files": [{"path": name, "size": len(data), "sha256": digest(data)} for name, data in sorted(payloads.items())],
    }
    entries = {"sealed-manifest.json": json_bytes(manifest), **payloads}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=args.output.parent, prefix=".scoop-sealed-", delete=False) as stream:
        temporary = Path(stream.name)
    try:
        with zipfile.ZipFile(temporary, "w", allowZip64=False) as archive:
            for name, data in sorted(entries.items()):
                add_file(archive, name, data)
        temporary.replace(args.output)
    finally:
        temporary.unlink(missing_ok=True)
    print(json.dumps({"status": "passed", "path": str(args.output), "size": args.output.stat().st_size,
                      "sha256": digest(args.output.read_bytes())}, sort_keys=True))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime-bundle", type=Path, required=True)
    parser.add_argument("--core", type=Path, required=True)
    parser.add_argument("--main", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    build(parser.parse_args())


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        raise SystemExit("sealed Scoop bundle: " + str(error))
