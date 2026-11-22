#!/usr/bin/env python3
"""Compatibility entrypoint for the apps-owned build interface.

Application payloads are canonical immutable files below apps/; this command
only delegates standard entry/config generation and maintains the shared
offline removal helper.  It never reads an application directory at repo root.
"""

import argparse
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def shared(name: str) -> str:
    return (ROOT / "lib" / name).read_text(encoding="utf-8").rstrip() + "\n\n"


def maintain_remove_helper(*, check: bool) -> None:
    output = ROOT / "scripts/remove-managed.sh"
    content = (
        "#!/bin/sh\nset -eu\n"
        + shared("install-storage.sh")
        + shared("install-transaction.sh")
        + shared("remove-managed.sh")
    ).rstrip() + "\n"
    if check:
        if not output.is_file() or output.read_text(encoding="utf-8") != content:
            raise SystemExit(f"stale generated entry: {output}")
    else:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=output.parent,
            prefix=".entry-", delete=False,
        ) as stream:
            stream.write(content)
            temporary = Path(stream.name)
        try:
            temporary.chmod(0o755)
            temporary.replace(output)
        finally:
            temporary.unlink(missing_ok=True)
    subprocess.run(["sh", "-n", str(output)], check=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    command = [sys.executable, "-B", str(ROOT / "scripts/build.py")]
    if args.check:
        command.append("--check")
    subprocess.run(command, check=True)
    maintain_remove_helper(check=args.check)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
