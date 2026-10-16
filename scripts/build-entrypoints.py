#!/usr/bin/env python3
"""Embed the one maintained bootstrap into standalone public business entries."""
import argparse
import json
import re
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    def helper(name):
        return (ROOT / "lib" / name).read_text().rstrip() + "\n\n"
    dispatch = helper("install-launcher.sh").split("installer_launcher_prepare()", 1)[0]
    foundation = "".join(helper(name) for name in ["install-storage.sh", "install-bounds.sh", "install-transaction.sh"])
    catalog = json.loads((ROOT / "catalog.json").read_text())
    for app in sorted({entry["application"] for entry in catalog["installers"]}):
        if not re.fullmatch(r"[a-z][a-z0-9_-]{0,63}", app):
            raise ValueError("invalid application id")
        folder = ROOT / app
        common = helper("bootstrap.sh") + foundation
        if app in {"ddnsto", "linkease"}:
            common += dispatch + helper("install-service.sh") + helper("install-package.sh") + helper("install-privilege.sh")
        else:
            common += helper("install-launcher.sh")
        content = common + "\n# Business logic: maintained in " + app + "/business.sh\n"
        content += (folder / "business.sh").read_text().rstrip() + "\n\n"
        # Emit the same maintained sources for the root phase. A running
        # one-key sh -c entry need not be a file and never downloads itself.
        if app in {"ddnsto", "linkease"}:
            # Root phase never bootstraps, prepares as a user, or selects a
            # launcher/package flow. Keep the one-key sh -c argv below Linux's
            # single-argument limit without requiring a second script fetch.
            program = 'set -eu\nstatus() { printf \'%s\\n\' "$*" >&2; }\n'
            program += foundation + dispatch + helper("install-service.sh")
            program += (folder / "business.sh").read_text() + f'\ninstaller_dispatch {app} "$@"\n'
            program = "\n".join(line for line in program.splitlines() if line.strip() and not line.lstrip().startswith("#")) + "\n"
            delimiter = "ZSETUP_PRIVATE_ROOT_PROGRAM"
            assert delimiter not in program
            content += f"installer_privileged_program() {{\ncat <<'{delimiter}'\n{program}{delimiter}\n}}\n"
        content += "\nbootstrap_and_run() {\n    status \"[1/4] Checking zsetup...\"\n    bootstrap_zsetup\n"
        content += "    status \"      zsetup $RESCUE_VERSION is ready\"\n    ZSETUP_BIN=$ACTIVE_ZSETUP\n"
        content += "    ZSETUP_SOURCE_BASES=${ZSETUP_SOURCE_BASES:-$DIRECT_PRIMARY_BASES}\n"
        content += "    ZSETUP_SOURCE_FALLBACK=${ZSETUP_SOURCE_FALLBACK-$DIRECT_FALLBACK_BASE}\n"
        content += "    export ZSETUP_BIN ZSETUP_ARCH ZSETUP_SOURCE_BASES ZSETUP_SOURCE_FALLBACK\n"
        content += f"    installer_dispatch {app} \"$@\"\n}}\n\n"
        content += (folder / "main.sh").read_text()
        if len(content.encode()) >= 131072:
            raise ValueError(f"{app} exceeds Linux sh -c single-argument budget")
        output = folder / f"{app}-install.sh"
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
