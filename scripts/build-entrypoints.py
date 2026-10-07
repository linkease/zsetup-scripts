#!/usr/bin/env python3
"""Embed the one maintained bootstrap into standalone public business entries."""
import argparse
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    common = (ROOT / "lib/bootstrap.sh").read_text()
    for app in ("fastnet", "ddnsto"):
        folder = ROOT / "apps" / app
        content = common + "\n# Business logic: maintained in apps/" + app + "/business.sh\n"
        content += (folder / "business.sh").read_text()
        content += "\nbootstrap_and_run() {\n    status \"[1/4] Checking zsetup...\"\n    bootstrap_zsetup\n"
        content += "    status \"      zsetup $RESCUE_VERSION is ready\"\n    ZSETUP_BIN=$ACTIVE_ZSETUP\n"
        content += "    ZSETUP_SOURCE_BASES=${ZSETUP_SOURCE_BASES:-$DIRECT_PRIMARY_BASES}\n"
        content += "    ZSETUP_SOURCE_FALLBACK=${ZSETUP_SOURCE_FALLBACK-$DIRECT_FALLBACK_BASE}\n"
        content += "    export ZSETUP_BIN ZSETUP_ARCH ZSETUP_SOURCE_BASES ZSETUP_SOURCE_FALLBACK\n"
        content += f"    {app}_install \"$@\"\n}}\n\n"
        content += (folder / "main.sh").read_text()
        output = folder / "install.sh"
        if args.check:
            if not output.is_file() or output.read_text() != content:
                raise SystemExit(f"stale generated entry: {output}")
        else:
            with tempfile.NamedTemporaryFile(mode="w", dir=folder, prefix=".entry-", delete=False) as stream:
                stream.write(content)
                temporary = Path(stream.name)
            try:
                temporary.chmod(0o755)
                temporary.replace(output)
            finally:
                temporary.unlink(missing_ok=True)
        subprocess.run(["sh", "-n", str(output)], check=True)


if __name__ == "__main__":
    main()
