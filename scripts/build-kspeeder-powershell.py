#!/usr/bin/env python3
"""Generate standalone Windows KSpeeder and KS-CLI entries from shared sources."""

import argparse
from pathlib import Path
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def content(app: str) -> bytes:
    bootstrap = (ROOT / "lib/bootstrap.ps1").read_text(encoding="utf-8").strip()
    policy = (ROOT / "kspeeder/lib/binary.ps1").read_text(encoding="utf-8").strip()
    text = f"""param(
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$InstallerArguments
)
$ErrorActionPreference = 'Stop'

{bootstrap}

{policy}

if ($InstallerArguments.Count -eq 1 -and $InstallerArguments[0] -ceq '--help') {{
    Write-Output '{app}-install.ps1 [--installer-prefix ABSOLUTE_DIRECTORY] [--installer-work-dir ABSOLUTE_DIRECTORY]'
    exit 0
}}
if (-not $env:ZSETUP_BIN) {{
    $env:ZSETUP_BIN = Get-ZsetupBootstrap
}}
Invoke-KSpeederBinaryInstall '{app}' $InstallerArguments
"""
    return b"\xef\xbb\xbf" + text.encode("utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    for app in ("ks-cli", "kspeeder"):
        output = ROOT / "kspeeder" / app / f"{app}-install.ps1"
        expected = content(app)
        if args.check:
            if not output.is_file() or output.read_bytes() != expected:
                raise SystemExit(f"stale generated KSpeeder PowerShell entry: {output}")
            continue
        with tempfile.NamedTemporaryFile(dir=output.parent, prefix=".entry-", delete=False) as stream:
            stream.write(expected)
            temporary = Path(stream.name)
        try:
            temporary.chmod(0o644)
            temporary.replace(output)
        finally:
            temporary.unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
