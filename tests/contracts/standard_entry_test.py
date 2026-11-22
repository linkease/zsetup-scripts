#!/usr/bin/env python3
"""Generated one-key entries bootstrap zsetup and preserve its process contract."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / "scripts/build.py"


def write_app(apps: Path):
    app = apps / "demo"
    (app / "1.2.3").mkdir(parents=True)
    (app / "app.json").write_text(json.dumps({
        "schema_version": 1,
        "id": "demo",
        "name": "Demo",
        "version": "1.2.3",
        "min_zsetup": "0.6.4",
        "entrypoints": ["sh"],
        "targets": [{"os": ["linux"], "package_manager": ["*"], "arch": ["x86_64"]}],
        "compatibility_aliases": ["demo-install.sh"],
    }) + "\n")
    (app / "1.2.3/installer.sh").write_text("#!/bin/sh\nexit 0\n")
    (apps / "zsetup").mkdir()
    (apps / "zsetup/base.json").write_text(json.dumps({
        "schema_version": 1,
        "source_groups": [{
            "id": "koolcenter", "primary_bases": ["https://fixture.invalid/binary"],
            "fallback_base": "https://fixture.invalid/binary",
        }],
        "stable_zsetup": {
            "version": "0.6.4", "source_group": "koolcenter",
            "artifacts": [{
                "arch": "x86_64", "path": "zsetup/0.6.4/zsetup-linux-x86_64",
                "sha256": "0" * 64, "size": 1,
            }],
        },
    }) + "\n")


with tempfile.TemporaryDirectory(prefix="apps-entry-") as name:
    work = Path(name)
    apps = work / "apps"
    write_app(apps)
    build = subprocess.run(
        [sys.executable, "-B", str(BUILD), "--apps", str(apps)],
        text=True, capture_output=True,
    )
    assert build.returncode == 0, build.stderr
    entry = apps / "demo/install.sh"
    alias = apps / "demo/demo-install.sh"
    assert entry.is_file() and os.access(entry, os.X_OK)
    assert alias.read_bytes() == entry.read_bytes()
    assert b"APP_ID='demo'" in entry.read_bytes()
    assert b'install "$APP_ID" --foreground -- "$@"' in entry.read_bytes()

    checked = subprocess.run(
        [sys.executable, "-B", str(BUILD), "--apps", str(apps), "--check"],
        text=True, capture_output=True,
    )
    assert checked.returncode == 0, checked.stderr
    original = entry.read_bytes()
    entry.write_bytes(original + b"# drift\n")
    drift = subprocess.run(
        [sys.executable, "-B", str(BUILD), "--apps", str(apps), "--check"],
        text=True, capture_output=True,
    )
    assert drift.returncode != 0 and "stale standard entry" in drift.stderr
    entry.write_bytes(original)

    fake = work / "zsetup"
    log = work / "argv"
    fake.write_text("""#!/bin/sh
if [ "${1:-}" = --version ]; then printf '%s\\n' 'zsetup 0.6.4'; exit 0; fi
: > "$ENTRY_LOG"
for value in "$@"; do printf '%s\\n' "$value" >> "$ENTRY_LOG"; done
exit 37
""")
    fake.chmod(0o755)
    environment = os.environ.copy()
    environment.update({
        "ZSETUP_BIN": str(fake),
        "ZSETUP_BOOTSTRAP_BASES": "https://fixture.invalid/binary",
        "ZSETUP_ROOT": str(work / "state"),
        "ENTRY_LOG": str(log),
    })
    tools = work / "tools"
    tools.mkdir()
    curl = tools / "curl"
    curl.write_text("""#!/bin/sh
destination=
url=
while [ "$#" -gt 0 ]; do
 case "$1" in -o) destination=$2; shift 2 ;; http*) url=$1; shift ;; *) shift ;; esac
done
case "$url" in
 */zsetup/stable) printf '%s\\n' '0.6.4' > "$destination" ;;
 */zsetup/0.6.4/SHA256SUMS) printf '%s  %s\\n' "$FAKE_SHA" 'zsetup-linux-x86_64' > "$destination" ;;
 *) exit 22 ;;
esac
""")
    curl.chmod(0o755)
    environment["FAKE_SHA"] = hashlib.sha256(fake.read_bytes()).hexdigest()
    environment["PATH"] = f"{tools}:{environment['PATH']}"
    result = subprocess.run(
        [str(entry), "literal value", "--flag=$dollar;not-shell"],
        env=environment, text=True, capture_output=True,
    )
    assert result.returncode == 37, result.stderr
    assert log.read_text().splitlines() == [
        "install", "demo", "--foreground", "--", "literal value", "--flag=$dollar;not-shell",
    ]

print("Standard entry: deterministic generation, aliases, bootstrap, argv and exit status passed")

