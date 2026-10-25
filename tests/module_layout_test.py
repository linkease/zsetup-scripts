#!/usr/bin/env python3
"""Business ownership and generated entries match the formal server namespaces."""
import json
import hashlib
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
for app, tests in (("fastnet", ("fastnet_bootstrap_test.py", "fastnet_zsetup_test.py")), ("ddnsto", ("ddnsto_test.py",)), ("linkease", ("linkease_test.py",)), ("fastpve", ("fastpve_test.py",)), ("linkspace", ("linkspace_test.py",))):
    module = ROOT / app
    for filename in ("business.sh", "main.sh", f"{app}-install.sh", "README.md"):
        assert (module / filename).is_file(), f"missing {app}/{filename}"
    assert not (module / "install.sh").exists(), "one maintained installer filename per business"
    for filename in tests:
        assert (module / "tests" / filename).is_file(), f"missing {app}/tests/{filename}"
    assert not (ROOT / "apps" / app).exists(), "one canonical module directory required"
assert (ROOT / "ddnsto/release.py").is_file()
for filename, app in (("fastnet-install.sh", "fastnet"), ("install_ddnsto.sh", "ddnsto"), ("install_ddnsto_linux.sh", "ddnsto"), ("install_ddnsto_business.sh", "ddnsto"), ("setup_ddnsto.sh", "ddnsto")):
    assert not (ROOT / filename).exists() and not (ROOT / filename).is_symlink(), "legacy names must not occupy the root"
    archived = ROOT / "legacy" / filename
    assert archived.is_file() and not archived.is_symlink(), "archive actual historical source"
expected = {
    "fastpve-install.sh": "5a8babfcfe46c341cde7c35ebda47bafaa19b5b72d95653843e7d595f2445a97",
    "fastnet-install.sh": "21aa238f92e491887e9b7d3e7f2845796891844fce035cf4da4cdb8fe5cbc2a1",
    "install_ddnsto.sh": "1f137a4f5ec0f76aadbf3d3dbdc8193ec93eb71f095e9110ce3881d5ef3e7707",
    "install_ddnsto_business.sh": "ddcb69decce88ba6544b268c3bb2f8d8adde533f9c197479932bd46a99d4deeb",
    "install_ddnsto_linux.sh": "0dbb19088fd4aae18c597c8f5455eaf28b4ef3bbd5adac7f551b85077c572c86",
    "install_linkease_linux.sh": "19e38713db5155b00f73470c918fff6f3430ca200daa92f45063e29f861e2b87",
    "install_linkease_openwrt.sh": "efdf86db8947790ce64af67d475916d68416aed9eeb627f976089b5b9b1c0d6c",
    "setup_ddnsto.sh": "53b69f9d7a6d287405c6ba88fb891f78ab362cdbb964dbf73c62d0bc83a8ff52",
}
for filename, digest in expected.items():
    assert hashlib.sha256((ROOT / "legacy" / filename).read_bytes()).hexdigest() == digest
catalog = json.loads((ROOT / "catalog.json").read_text())
script_version = catalog["config_version"].removeprefix("scripts-")
for record in catalog["installers"]:
    app = record["application"]
    assert record["script"] == f"{app}/{app}-install.sh"
    version = "0.1.0" if app == "linkspace" else script_version
    assert record["path"] == f"{app}/{version}/{app}-install.sh"
subprocess.run(["python3", "-B", str(ROOT / "scripts/build-entrypoints.py"), "--check"], check=True)
print("Module layout: business ownership, canonical paths, historical snapshots and generated entries passed")
