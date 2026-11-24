#!/usr/bin/env python3
"""Application ownership lives only in apps; tests and history remain separate."""

import hashlib
import json
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
IDS = {
    "ddnsto", "fastnet", "fastpve", "jq", "kai-skills", "ks-cli",
    "kspeeder", "linkease", "linkspace", "scoop",
}
OUTER = IDS - {"ks-cli"}

assert not [name for name in sorted(OUTER) if (ROOT / name).exists()]
assert {path.parent.name for path in (ROOT / "apps").glob("*/app.json")} == IDS
for app in IDS:
    directory = ROOT / "apps" / app
    manifest = json.loads((directory / "app.json").read_text(encoding="utf-8"))
    version = manifest["version"]
    extensions = (["sh" if family == "posix" else "ps1"
                   for family in manifest["entrypoints"]]
                  if manifest["schema_version"] == 2 else manifest["entrypoints"])
    for extension in extensions:
        payload = (directory / "versions" / version / f"install.{extension}"
                   if manifest["schema_version"] == 2
                   else directory / version / f"installer.{extension}")
        assert payload.is_file()
        assert (directory / f"install.{extension}").is_file()
    assert not (directory / "tests").exists()
    assert ((ROOT / "tests/apps" / app).is_dir()
            or app == "ks-cli" and (ROOT / "tests/apps/kspeeder").is_dir())

expected_history = {
    "fastpve-install.sh": "5a8babfcfe46c341cde7c35ebda47bafaa19b5b72d95653843e7d595f2445a97",
    "fastnet-install.sh": "21aa238f92e491887e9b7d3e7f2845796891844fce035cf4da4cdb8fe5cbc2a1",
    "install_ddnsto.sh": "1f137a4f5ec0f76aadbf3d3dbdc8193ec93eb71f095e9110ce3881d5ef3e7707",
    "install_ddnsto_business.sh": "ddcb69decce88ba6544b268c3bb2f8d8adde533f9c197479932bd46a99d4deeb",
    "install_ddnsto_linux.sh": "0dbb19088fd4aae18c597c8f5455eaf28b4ef3bbd5adac7f551b85077c572c86",
    "install_linkease_linux.sh": "19e38713db5155b00f73470c918fff6f3430ca200daa92f45063e29f861e2b87",
    "install_linkease_openwrt.sh": "efdf86db8947790ce64af67d475916d68416aed9eeb627f976089b5b9b1c0d6c",
    "setup_ddnsto.sh": "53b69f9d7a6d287405c6ba88fb891f78ab362cdbb964dbf73c62d0bc83a8ff52",
}
# Preserve exact historical fixtures without making them current sources.
for filename, digest in expected_history.items():
    path = ROOT / "legacy" / filename
    assert path.is_file() and not path.is_symlink()
    assert hashlib.sha256(path.read_bytes()).hexdigest() == digest

for catalog_name in ("catalog.json", "catalog-windows.json"):
    catalog = json.loads((ROOT / catalog_name).read_text(encoding="utf-8"))
    for record in catalog["installers"]:
        assert record["script"].startswith("apps/")
        assert (ROOT / record["script"]).is_file()

subprocess.run(["python3", "-B", str(ROOT / "scripts/build-entrypoints.py"), "--check"], check=True)
print("Module layout: apps-only ownership, external tests, history and generated entries passed")
