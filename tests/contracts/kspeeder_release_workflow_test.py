#!/usr/bin/env python3
"""Latest discovery and apps validation gate the standard KSpeeder workflow."""

import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "release_kspeeder", ROOT / "scripts/release-kspeeder.py"
)
workflow = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(workflow)


def sha(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


version = "1.2.3"
bodies = {
    f"iStoreEnhance-binary-{version}.tar.gz": b"kspeeder bundle",
    "iStoreEnhance-linux.amd64": b"kspeeder amd64",
    "iStoreEnhance-linux.arm": b"kspeeder arm",
    "iStoreEnhance-linux.arm64": b"kspeeder arm64",
    f"ks-cli-binary-{version}.tar.gz": b"ks-cli bundle",
    "ks-cli-linux-amd64": b"ks-cli amd64",
    "ks-cli-linux-arm": b"ks-cli arm",
    "ks-cli-linux-arm64": b"ks-cli arm64",
}
desktop_bodies = {
    "iStoreEnhance-mac.amd64": b"kspeeder mac amd64",
    "iStoreEnhance-mac.arm64": b"kspeeder mac arm64",
    "iStoreEnhance-win.exe.amd64": b"kspeeder windows amd64",
    "iStoreEnhance-win.exe.arm64": b"kspeeder windows arm64",
    "ks-cli-mac-amd64": b"ks-cli mac amd64",
    "ks-cli-mac-arm64": b"ks-cli mac arm64",
    "ks-cli-win-amd64.exe": b"ks-cli windows amd64",
    "ks-cli-win-arm64.exe": b"ks-cli windows arm64",
}
bodies["version.txt"] = (
    f"VERSION={version}\n"
    f"SHA256_linux_amd64={sha(bodies['iStoreEnhance-linux.amd64'])}\n"
    f"SHA256_linux_arm={sha(bodies['iStoreEnhance-linux.arm'])}\n"
    f"SHA256_linux_arm64={sha(bodies['iStoreEnhance-linux.arm64'])}\n"
    f"SHA256_mac_amd64={sha(desktop_bodies['iStoreEnhance-mac.amd64'])}\n"
    f"SHA256_mac_arm64={sha(desktop_bodies['iStoreEnhance-mac.arm64'])}\n"
    f"SHA256_win_amd64={sha(desktop_bodies['iStoreEnhance-win.exe.amd64'])}\n"
    f"SHA256_win_arm64={sha(desktop_bodies['iStoreEnhance-win.exe.arm64'])}\n"
).encode()
bodies["ks-cli-version.txt"] = (
    f"VERSION={version}\n"
    f"SHA256_linux_amd64={sha(bodies['ks-cli-linux-amd64'])}\n"
    f"SHA256_linux_arm={sha(bodies['ks-cli-linux-arm'])}\n"
    f"SHA256_linux_arm64={sha(bodies['ks-cli-linux-arm64'])}\n"
    f"SHA256_openwrt_bundle={sha(bodies[f'ks-cli-binary-{version}.tar.gz'])}\n"
).encode()

download_base = f"https://github.com/kspeeder/docker_kspeeder/releases/download/v{version}"
release = {
    "tag_name": f"v{version}",
    "draft": False,
    "prerelease": False,
    "published_at": "2027-01-02T03:04:05Z",
    "assets": [
        {
            "name": name,
            "size": len(body),
            "digest": f"sha256:{sha(body)}",
            "browser_download_url": f"{download_base}/{name}",
        }
        for name, body in reversed(list(bodies.items()))
    ],
}


def metadata_fetch(url, size, expected):
    body = bodies[url.rsplit("/", 1)[1]]
    assert len(body) == size and sha(body) == expected
    return body


def official_inspect(url):
    body = desktop_bodies[url.rsplit("/", 1)[1]]
    return len(body), sha(body)


locked = workflow.lock_from_release(
    release, metadata_fetch=metadata_fetch, official_inspect=official_inspect
)
assert locked["product_version"] == version
assert [item["name"] for item in locked["assets"]] == sorted(bodies)
assert locked["public"]["bases"] == workflow.PUBLIC_BASES

for mutation, message in (
    (lambda value: value.update(draft=True), "draft"),
    (lambda value: value["assets"].pop(), "missing asset"),
    (lambda value: value["assets"][0].update(digest=None), "missing digest"),
):
    invalid = copy.deepcopy(release)
    mutation(invalid)
    try:
        workflow.lock_from_release(
            invalid, metadata_fetch=metadata_fetch, official_inspect=official_inspect
        )
    except workflow.WorkflowError:
        pass
    else:
        raise AssertionError(f"accepted {message}")

invalid_metadata = dict(bodies)
invalid_metadata["version.txt"] = bodies["version.txt"].replace(b"VERSION=1.2.3", b"VERSION=9.9.9")
def wrong_metadata(url, _size, _expected):
    return invalid_metadata[url.rsplit("/", 1)[1]]
try:
    workflow.lock_from_release(
        release, metadata_fetch=wrong_metadata, official_inspect=official_inspect
    )
except workflow.publisher.ProductReleaseError:
    pass
else:
    raise AssertionError("accepted metadata that identifies another product version")

with tempfile.TemporaryDirectory(prefix="kspeeder-workflow-") as folder:
    work = Path(folder)
    old = copy.deepcopy(locked)
    old_version = "1.2.2"
    old["product_version"] = old_version
    old["source"]["tag"] = f"v{old_version}"
    old["source"]["download_base"] = (
        f"https://github.com/kspeeder/docker_kspeeder/releases/download/v{old_version}"
    )
    for asset in old["assets"]:
        asset["name"] = asset["name"].replace(version, old_version)
    lock_path = work / "lock.json"
    lock_path.write_text(json.dumps(old, indent=2) + "\n")
    assert workflow.update_lock(locked, lock_path, require_clean=False)
    assert workflow.publisher.load_lock(lock_path) == locked
    assert not workflow.update_lock(locked, lock_path, require_clean=False)
    changed_same_version = copy.deepcopy(locked)
    changed_same_version["published_at"] = "2027-01-02T03:04:06Z"
    try:
        workflow.update_lock(changed_same_version, lock_path, require_clean=False)
    except workflow.WorkflowError:
        pass
    else:
        raise AssertionError("accepted changed bytes/metadata under an immutable version tag")

    fixture = work / "repo"
    for relative in (
        "kspeeder/ks-cli/ks-cli-install.sh", "kspeeder/ks-cli/ks-cli-install.ps1",
        "kspeeder/kspeeder/kspeeder-install.sh", "kspeeder/kspeeder/kspeeder-install.ps1",
        "kspeeder/lib/binary.sh", "kspeeder/lib/binary.ps1",
        "apps/_shared/kspeeder-binary.sh", "apps/_shared/kspeeder-binary.ps1",
        "apps/ks-cli/app.json", "apps/ks-cli/0.1.2/installer.sh",
        "apps/ks-cli/0.1.2/installer.ps1", "apps/ks-cli/ks-cli-install.sh",
        "apps/ks-cli/ks-cli-install.ps1", "apps/ks-cli/install.sh", "apps/ks-cli/install.ps1",
        "apps/kspeeder/app.json", "apps/kspeeder/0.1.2/installer.sh",
        "apps/kspeeder/0.1.2/installer.ps1", "apps/kspeeder/kspeeder-install.sh",
        "apps/kspeeder/kspeeder-install.ps1", "apps/kspeeder/install.sh",
        "apps/kspeeder/install.ps1", "apps/zsetup/config.json",
        "apps/zsetup/config-windows.json",
    ):
        source = ROOT / relative
        destination = fixture / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
    result = workflow.validate_apps(root=fixture, command_runner=lambda _command: None)
    assert set(result["applications"]) == {"ks-cli", "kspeeder"}
    (fixture / "apps/kspeeder/0.1.2/installer.sh").write_text("tampered\n")
    try:
        workflow.validate_apps(root=fixture, command_runner=lambda _command: None)
    except workflow.WorkflowError:
        pass
    else:
        raise AssertionError("accepted an apps/kspeeder payload that differs from its source")

called = []
original_latest = workflow.latest_lock
original_validate = workflow.validate_apps
original_delegate = workflow.delegate
workflow.latest_lock = lambda: locked
workflow.validate_apps = lambda **_kwargs: (_ for _ in ()).throw(workflow.WorkflowError("stale apps"))
workflow.delegate = lambda *_args: called.append(True) or 0
try:
    assert workflow.main(["prepare", "--native-bin", "/not-used"]) == 1
    assert not called
finally:
    workflow.latest_lock = original_latest
    workflow.validate_apps = original_validate
    workflow.delegate = original_delegate

print("KSpeeder standard workflow: latest lock, exact metadata, apps gate and safe delegation passed")
