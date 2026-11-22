#!/usr/bin/env python3
"""KSpeeder product mirror is versioned, verified, rollbackable and no-delete."""

import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "publish_kspeeder_products", ROOT / "scripts/publish-kspeeder-products.py"
)
publisher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(publisher)


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


version = "0.9.1"
bodies = {
    f"iStoreEnhance-binary-{version}.tar.gz": b"kspeeder bundle fixture",
    "iStoreEnhance-linux.amd64": b"kspeeder amd64 fixture",
    "iStoreEnhance-linux.arm": b"kspeeder arm fixture",
    "iStoreEnhance-linux.arm64": b"kspeeder arm64 fixture",
    f"ks-cli-binary-{version}.tar.gz": b"ks-cli bundle fixture",
    "ks-cli-linux-amd64": b"ks-cli amd64 fixture",
    "ks-cli-linux-arm": b"ks-cli arm fixture",
    "ks-cli-linux-arm64": b"ks-cli arm64 fixture",
}
bodies["version.txt"] = (
    f"VERSION={version}\n"
    f"SHA256_linux_amd64={sha(bodies['iStoreEnhance-linux.amd64'])}\n"
    f"SHA256_linux_arm={sha(bodies['iStoreEnhance-linux.arm'])}\n"
    f"SHA256_linux_arm64={sha(bodies['iStoreEnhance-linux.arm64'])}\n"
).encode()
bodies["ks-cli-version.txt"] = (
    f"VERSION={version}\n"
    f"SHA256_linux_amd64={sha(bodies['ks-cli-linux-amd64'])}\n"
    f"SHA256_linux_arm={sha(bodies['ks-cli-linux-arm'])}\n"
    f"SHA256_linux_arm64={sha(bodies['ks-cli-linux-arm64'])}\n"
    f"SHA256_openwrt_bundle={sha(bodies[f'ks-cli-binary-{version}.tar.gz'])}\n"
).encode()

lock = {
    "schema_version": 1,
    "product_version": version,
    "source": {
        "repository": "kspeeder/docker_kspeeder",
        "tag": f"v{version}",
        "published_at": "2026-11-18T14:45:15Z",
        "download_base": f"https://github.com/kspeeder/docker_kspeeder/releases/download/v{version}",
    },
    "public": {
        "prefix": "kspeeder",
        "bases": [
            "https://one.invalid/binary", "https://two.invalid/binary",
            "https://three.invalid/binary", "https://four.invalid/binary",
        ],
        "root_pointers": ["version.txt", "ks-cli-version.txt"],
    },
    "assets": [
        {"name": name, "size": len(body), "sha256": sha(body)}
        for name, body in sorted(bodies.items())
    ],
}


with tempfile.TemporaryDirectory(prefix="kspeeder-product-release-") as folder:
    work = Path(folder)
    lock_path = work / "lock.json"
    lock_path.write_text(json.dumps(lock, indent=2) + "\n")

    def fetch(url, destination, expected_size, expected_sha):
        name = url.rsplit("/", 1)[1]
        body = bodies[name]
        assert len(body) == expected_size and sha(body) == expected_sha
        destination.write_bytes(body)

    package = publisher.prepare_release(lock_path, work / "releases", fetch=fetch,
                                        require_clean=False)
    identity = publisher.release_identity(lock_path)
    assert package == work / "releases" / identity
    manifest = publisher.validate_package(package, identity, lock)
    assert manifest["product_version"] == version
    assert manifest["deletes_existing_files"] is False
    immutable = package / "immutable/kspeeder" / version
    assert len(list(immutable.iterdir())) == 12
    assert (package / "pointers/kspeeder/version.txt").read_bytes() == bodies["version.txt"]

    binary = work / "binary"
    product = binary / "kspeeder"
    product.mkdir(parents=True)
    (product / "historical-file.tar.gz").write_bytes(b"must survive")
    (product / "version.txt").write_bytes(b"VERSION=0.8.2\n")
    (product / "ks-cli-version.txt").write_bytes(b"VERSION=0.8.2\n")
    transaction = package / "install-kspeeder-product-release.sh"

    def action(mode, expected=0):
        result = subprocess.run(["sh", str(transaction), mode, str(package), str(binary)],
                                text=True, capture_output=True)
        assert result.returncode == expected, result.stdout + result.stderr
        return result

    action("stage")
    assert (product / version / "version.txt").read_bytes() == bodies["version.txt"]
    assert (product / "version.txt").read_bytes() == b"VERSION=0.8.2\n"
    assert (product / "historical-file.tar.gz").read_bytes() == b"must survive"
    action("activate")
    action("verify")
    assert (product / "version.txt").read_bytes() == bodies["version.txt"]
    action("rollback")
    assert (product / "version.txt").read_bytes() == b"VERSION=0.8.2\n"
    assert (product / version).is_dir()
    assert (product / "historical-file.tar.gz").read_bytes() == b"must survive"

    seen = []
    def public_fetch(url, expected, size, *, timeout):
        seen.append(url)
    checks = publisher.verify_public(package, lock, immutable_only=False, attempts=1,
                                     delay=0, workers=4, timeout=1, fetch=public_fetch)
    assert checks == 14 * 4 and len(seen) == checks
    assert all("/binary/kspeeder/" in url for url in seen)

    public, remote = publisher.remote_paths("/srv/public_html/binary", identity)
    assert str(public) == "/srv/public_html/binary/kspeeder"
    assert str(remote) == f"/srv/.zsetup-scripts-releases/kspeeder-products/{identity}"

    payload = b"retried release asset"
    calls = []
    original_urlopen = publisher.urlopen
    class Response(io.BytesIO):
        url = "https://github.com/fixture/asset"
    def flaky_urlopen(*_args, **_kwargs):
        calls.append(1)
        if len(calls) == 1:
            raise OSError("transient TLS EOF")
        return Response(payload)
    publisher.urlopen = flaky_urlopen
    try:
        downloaded = work / "retried-asset"
        publisher.default_fetch("https://github.com/fixture/asset", downloaded,
                                len(payload), sha(payload))
        assert downloaded.read_bytes() == payload and len(calls) == 2
    finally:
        publisher.urlopen = original_urlopen

print("KSpeeder product release: locked assets, immutable stage, activation, verification, rollback and no-delete passed")
