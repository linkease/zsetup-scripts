"""kai-skills is one exact, release-bound Product Configuration application."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]
NATIVE = Path(sys.argv[1]).resolve()
ZSETUP_ROOT = Path(sys.argv[2]).resolve()

spec = importlib.util.spec_from_file_location(
    "product_config_generator", ZSETUP_ROOT / "scripts/generate-product-config.py"
)
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)

expected_group = {
    "id": "koolcenter",
    "primary_bases": [
        "https://dl.istoreos.com/binary",
        "https://fw.d4ctech.com/binary",
        "https://fw20.koolcenter.com/binary",
    ],
    "fallback_base": "https://fw.koolcenter.com/binary",
}
assert generator.SOURCE_GROUP == expected_group

native_version = subprocess.run(
    [str(NATIVE), "--version"], check=True, text=True, capture_output=True
).stdout.strip().removeprefix("zsetup ")
version, records = generator.catalog_installers(ROOT / "catalog.json", native_version)
assert version == "scripts-0.3.1"
kai = [record for record in records if record["application"] == "kai-skills"]
assert len(kai) == 2
assert {(record["os"], record["package_manager"], record["arch"])
        for record in kai} == {("ubuntu", "*", "*"), ("openwrt", "*", "*")}
assert {record["path"] for record in kai} == {
    "kai/kai-skills/installers/1.2.5/kai-skills-install.sh"
}
assert all(record["min_version"] == native_version and not record["background"] for record in kai)
installer = ROOT / "kai-skills/kai-skills-install.sh"
digest = hashlib.sha256(installer.read_bytes()).hexdigest()
assert all(record["sha256"] == digest and record["size"] == installer.stat().st_size
           for record in kai)

with tempfile.TemporaryDirectory(prefix="kai-product-config-") as name:
    work = Path(name)
    cached = work / f"kai-skills-{digest}.sh"
    cached.write_bytes(installer.read_bytes())
    cached.chmod(0o755)
    native_digest = hashlib.sha256(NATIVE.read_bytes()).hexdigest()
    config = {
        "schema_version": 1,
        "config_version": version,
        "source_groups": [expected_group],
        "stable_zsetup": {
            "version": native_version,
            "source_group": "koolcenter",
            "artifacts": [{
                "arch": "x86_64", "path": f"zsetup/{native_version}/zsetup-linux-x86_64",
                "sha256": native_digest, "size": NATIVE.stat().st_size,
            }],
        },
        "installers": records,
    }
    config_path = work / "config.json"
    config_path.write_text(json.dumps(config))
    result = subprocess.run([
        str(NATIVE), "install", "kai-skills", "--foreground", "--",
        "--skill", "kai-software", "--system", "ubuntu",
    ], env={**os.environ, "ZSETUP_CONFIG": str(config_path),
            "ZSETUP_CACHE_DIR": str(work), "ZSETUP_MANAGED_ROOT": str(work)},
        text=True, capture_output=True, timeout=30)
    assert result.returncode == 2, result
    assert "choose only one selection" in result.stderr

for forbidden in ("github.com", "ks-cli", "kspeeder", "npm ", "npx "):
    assert forbidden not in installer.read_text().lower()

print("kai-skills: product configuration sources, pins, selector and argv passed")
