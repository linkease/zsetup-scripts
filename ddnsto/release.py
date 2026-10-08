"""DDNSTO artifact validation and release staging; owned by this business."""
import json
from pathlib import Path
import re
import shutil
import sys
import tarfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from release_common import digest, copy_immutable


def copy_ddnsto_artifacts(source, destination):
    """Require complete business-owned bytes plus an approved digest inventory."""
    inventory = json.loads((source / "artifacts.json").read_text())
    if set(inventory) != {"schema_version", "provenance", "files"} or inventory["schema_version"] != 1 or not inventory["provenance"]:
        raise ValueError("DDNSTO artifacts.json requires schema_version, provenance and files")
    approved = {}
    for record in inventory["files"]:
        if set(record) != {"path", "sha256"}:
            raise ValueError("invalid DDNSTO artifact record")
        name = record["path"]
        if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9_./+-]+", name) or any(part in {"", ".", ".."} for part in name.split("/")):
            raise ValueError("invalid DDNSTO artifact path")
        if name in approved or not re.fullmatch(r"[a-f0-9]{64}", record["sha256"]):
            raise ValueError("duplicate path or invalid approved SHA256")
        file = (source / name).resolve()
        if not file.is_relative_to(source.resolve()) or not file.is_file() or digest(file) != record["sha256"]:
            raise ValueError(f"DDNSTO approved digest mismatch: {name}")
        approved[name] = file
    versions = {}
    mutable = set()
    for variant, pointer in (("lite", "VERSION_LITE"), ("standard", "VERSION")):
        pointer_path = "openwrt/" + pointer
        if pointer_path not in approved:
            raise ValueError(f"missing DDNSTO version pointer: {pointer_path}")
        version = approved[pointer_path].read_text().strip()
        if not re.fullmatch(r"[A-Za-z0-9._+-]{1,64}", version):
            raise ValueError("invalid DDNSTO version")
        versions[variant] = version
        mutable.add(pointer_path)
        for ext in ("ipk", "apk"):
            folder = f"openwrt/{variant}{'-apk' if ext == 'apk' else ''}/{version}"
            names = [f"ddnsto_{arch}.{ext}" for arch in ("x86_64", "aarch64", "arm", "mipsel")]
            names += [f"luci-app-ddnsto.{ext}", f"luci-i18n-ddnsto-zh-cn.{ext}"]
            for name in names:
                if f"{folder}/{name}" not in approved:
                    raise ValueError(f"missing DDNSTO artifact: {folder}/{name}")
    linux_name = "linux-binary/ddnsto-standard-4.2.3.tar.gz"
    if linux_name not in approved:
        raise ValueError("Linux default 4.2.3 artifact missing")
    with tarfile.open(approved[linux_name], "r:gz") as archive:
        for arch in ("x86_64", "aarch64"):
            member = archive.getmember(f"ddnsto-standard-4.2.3/ddnsto.{arch}")
            if not member.isfile():
                raise ValueError("Linux tar member must be a regular binary")
    # Stage all approved files, then generate the digest metadata consumed by business.sh.
    for name, file in approved.items():
        target = destination / name
        if name in mutable:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(file, target)
        else:
            copy_immutable(file, target)
    for parent in sorted({Path(name).parent for name in approved if name not in mutable}):
        files = sorted((name, file) for name, file in approved.items() if Path(name).parent == parent)
        target = destination / parent / "SHA256SUMS"
        content = "".join(f"{digest(file)}  {Path(name).name}\n" for name, file in files)
        if str(parent) != "linux-binary" and target.exists() and target.read_text() != content:
            raise ValueError(f"immutable DDNSTO digest metadata changed: {parent}")
        target.write_text(content)
    return inventory["provenance"]



def copy_compat_installers(installer, destination):
    """Historical DDNSTO URLs publish the same standalone entry bytes."""
    for relative in ("openwrt/install_ddnsto.sh", "openwrt/install_ddnsto_business.sh", "openwrt/setup_ddnsto.sh", "linux-binary/install_ddnsto_linux.sh"):
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(installer, target)
