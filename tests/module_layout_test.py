#!/usr/bin/env python3
"""Business ownership and generated entries match the formal server namespaces."""
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
for app, tests in (("fastnet", ("fastnet_bootstrap_test.py", "fastnet_zsetup_test.py")), ("ddnsto", ("ddnsto_test.py",))):
    module = ROOT / app
    for filename in ("business.sh", "main.sh", "install.sh", "README.md"):
        assert (module / filename).is_file(), f"missing {app}/{filename}"
    for filename in tests:
        assert (module / "tests" / filename).is_file(), f"missing {app}/tests/{filename}"
    assert not (ROOT / "apps" / app).exists(), "one canonical module directory required"
assert (ROOT / "ddnsto/release.py").is_file()
for filename, app in (("fastnet-install.sh", "fastnet"), ("install_ddnsto.sh", "ddnsto"), ("install_ddnsto_linux.sh", "ddnsto"), ("install_ddnsto_business.sh", "ddnsto"), ("setup_ddnsto.sh", "ddnsto")):
    assert (ROOT / filename).resolve(strict=True) == ROOT / app / "install.sh"
for record in json.loads((ROOT / "catalog.json").read_text())["installers"]:
    app = record["application"]
    assert record["script"] == f"{app}/install.sh"
    assert record["path"] == f"{app}/0.1.3/install.sh"
subprocess.run(["python3", "-B", str(ROOT / "scripts/build-entrypoints.py"), "--check"], check=True)
print("Module layout: business ownership, canonical paths, aliases and generated entries passed")
