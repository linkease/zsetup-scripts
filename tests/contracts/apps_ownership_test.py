#!/usr/bin/env python3
"""The public apps tree is the sole owner of application runtime sources."""

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
OUTER = {
    "ddnsto", "fastnet", "fastpve", "jq", "kai-skills",
    "kspeeder", "linkease", "linkspace", "scoop",
}

assert not [name for name in sorted(OUTER) if (ROOT / name).exists()]
for catalog_name in ("catalog.json", "catalog-windows.json"):
    catalog = json.loads((ROOT / catalog_name).read_text(encoding="utf-8"))
    for record in catalog["installers"]:
        source = record["script"]
        assert source.startswith("apps/"), (catalog_name, source)
        path = ROOT / source
        assert path.is_file() and not path.is_symlink(), source

for application in (ROOT / "apps").glob("*/app.json"):
    directory = application.parent
    assert not (directory / "tests").exists()
    assert not list(directory.rglob("*_test.py"))
    assert not list(directory.rglob("test_*.py"))

print("Apps ownership: one runtime source tree, no outer business directories or published tests passed")
