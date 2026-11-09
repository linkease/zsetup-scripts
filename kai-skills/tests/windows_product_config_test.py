"""Windows proposal upgrades only the scoped core and kai-skills records."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]
ZSETUP_ROOT = Path(sys.argv[1]).resolve()

with tempfile.TemporaryDirectory(prefix="kai-windows-config-") as name:
    work = Path(name)
    live = {
        "schema_version": 1,
        "config_version": "live-windows",
        "source_groups": [{
            "id": "release",
            "primary_bases": [
                "https://dl.istoreos.com/binary",
                "https://fw.d4ctech.com/binary",
                "https://fw20.koolcenter.com/binary",
            ],
            "fallback_base": "https://fw.koolcenter.com/binary",
        }],
        "stable_zsetup": {
            "version": "0.4.0", "source_group": "release",
            "artifacts": [{"arch": "i686", "path": "zsetup/0.4.0/old.exe",
                           "sha256": "0" * 64, "size": 1}],
        },
        "installers": [{
            "application": "legacy", "os": "windows", "package_manager": "*",
            "arch": "*", "source_group": "release", "path": "legacy/install.ps1",
            "sha256": "1" * 64, "size": 2, "background": False,
            "min_version": "0.4.0",
        }],
    }
    measurements = {
        "version": "0.6.5",
        "records": [{"os": "windows", "arch": "i686",
                     "artifact": "zsetup-windows-i686.exe",
                     "sha256": "2" * 64, "size": 1879040}],
    }
    live_path = work / "live.json"
    measurements_path = work / "measurements.json"
    output = work / "proposed.json"
    live_path.write_text(json.dumps(live))
    measurements_path.write_text(json.dumps(measurements))
    result = subprocess.run([
        sys.executable, str(ROOT / "kai-skills/package-product-config.py"),
        "--platform", "windows", "--live-config", str(live_path),
        "--measurements", str(measurements_path), "--zsetup-root", str(ZSETUP_ROOT),
        "--output", str(output),
    ], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    proposed = json.loads(output.read_text())
    assert proposed["stable_zsetup"] == {
        "version": "0.6.5", "source_group": "release",
        "artifacts": [{"arch": "i686",
                       "path": "zsetup/0.6.5/zsetup-windows-i686.exe",
                       "sha256": "2" * 64, "size": 1879040}],
    }
    assert {item["application"] for item in proposed["installers"]} == {
        "legacy", "kai-skills"
    }
    legacy = next(item for item in proposed["installers"] if item["application"] == "legacy")
    kai = next(item for item in proposed["installers"] if item["application"] == "kai-skills")
    assert legacy["min_version"] == "0.6.5"
    assert kai["path"] == "kai/kai-skills/installers/1.2.5/kai-skills-install.ps1"
    assert kai["source_group"] == "release" and kai["min_version"] == "0.6.5"
    assert len(proposed["source_groups"]) == 1

print("kai-skills: scoped Windows core and Product Configuration proposal passed")
