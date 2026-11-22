#!/usr/bin/env python3
"""The production coordinator fixes the namespace and packages all apps."""

import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "publish_apps", ROOT / "scripts/publish-apps.py"
)
publish_apps = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(publish_apps)


with tempfile.TemporaryDirectory(prefix="apps-coordinator-") as folder:
    output = Path(folder) / "releases"
    release = publish_apps.prepare_release(ROOT, output, require_clean=False)
    identity = hashlib.sha256((ROOT / "apps/SHA256SUMS").read_bytes()).hexdigest()
    assert release == output / identity
    metadata = publish_apps.validate_release(release, identity)
    assert metadata["public_subpath"] == "zsetup-scripts/apps"
    assert metadata["applications"] == [
        "ddnsto", "fastnet", "fastpve", "jq", "kai-skills", "ks-cli",
        "kspeeder", "linkease", "linkspace", "scoop",
    ]
    assert metadata["linux_installer_records"] == 129
    assert metadata["windows_installer_records"] == 9
    assert metadata["published"] is False
    assert (release / "apps/SHA256SUMS").read_bytes() == (ROOT / "apps/SHA256SUMS").read_bytes()
    assert not list((release / "apps").rglob("tests"))

    # Re-preparing the same clean candidate reuses and revalidates its immutable release.
    assert publish_apps.prepare_release(ROOT, output, require_clean=False) == release

    public, remote = publish_apps.deployment_paths(
        "/srv/istore-data/public_html/binary", identity
    )
    assert str(public) == "/srv/istore-data/public_html/binary/zsetup-scripts/apps"
    assert str(remote) == f"/srv/istore-data/.zsetup-scripts-releases/{identity}"
    command = publish_apps.ssh_command(
        "release-host", "env", f"ZSETUP_PUBLISH_PREVALIDATED_RELEASE_ID={identity}",
        "sh", remote / "publish.sh", "stage", remote / "apps", public,
    )
    assert command[-1] == str(public)
    assert "/binary/zsetup-scripts/apps" in command[-1]

    for unsafe in ("/", "/binary", "/srv/public_html", "relative/binary", "/srv/../binary"):
        try:
            publish_apps.deployment_paths(unsafe, identity)
        except publish_apps.PublicationError:
            pass
        else:
            raise AssertionError(f"unsafe binary root accepted: {unsafe}")
    try:
        publish_apps.require_approval("0" * 64, identity)
    except publish_apps.PublicationError:
        pass
    else:
        raise AssertionError("wrong release approval was accepted")

    manifest = publish_apps.read_manifest(release / "apps")
    immutable = [relative for _, relative in manifest if publish_apps.is_immutable(relative)]
    assert immutable and all("/" in relative for relative in immutable)
    assert not publish_apps.is_immutable("ddnsto/install.sh")

    # Public verification covers every configured mirror and checks exact bytes.
    fetched = []
    def exact_fetch(url, expected, size, *, timeout):
        fetched.append((url, expected, size, timeout))
    count = publish_apps.verify_public(
        release, immutable_only=True, attempts=1, delay=0, workers=4,
        timeout=1, fetch=exact_fetch,
    )
    bases = publish_apps.public_bases(release / "apps")
    assert count == len(immutable) * len(bases)
    assert len(fetched) == count
    assert all("/binary/zsetup-scripts/apps/" in url for url, *_ in fetched)

print("Publish coordinator: complete candidate, fixed namespace, approval and mirror plan passed")
