#!/usr/bin/env python3
"""Generate the one canonical PowerShell Scoop public entry."""
import argparse
from pathlib import Path
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def render():
    parts = [
        "# Generated from lib/bootstrap.ps1, scoop/business.ps1 and scoop/main.ps1.\n",
        "$script:ScoopUtf8NoBom = [Text.UTF8Encoding]::new($false)\n",
        "[Console]::InputEncoding = $script:ScoopUtf8NoBom\n",
        "[Console]::OutputEncoding = $script:ScoopUtf8NoBom\n",
        "$OutputEncoding = $script:ScoopUtf8NoBom\n\n",
        (ROOT / "lib/bootstrap.ps1").read_text(encoding="utf-8").rstrip() + "\n\n",
        (ROOT / "scoop/business.ps1").read_text(encoding="utf-8").rstrip() + "\n\n",
        (ROOT / "scoop/main.ps1").read_text(encoding="utf-8").rstrip() + "\n",
    ]
    content = "".join(parts)
    if len(content.encode("utf-8")) > 131072:
        raise ValueError("Scoop PowerShell entry exceeds native installer bound")
    return content


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path, default=ROOT / "scoop")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    target = args.output_dir / "scoop-install.ps1"
    content = render()
    if args.check:
        if not target.is_file() or target.read_text(encoding="utf-8") != content:
            raise SystemExit("stale generated entry: " + str(target))
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", newline="\n", dir=target.parent, prefix=".entry-", delete=False) as stream:
        stream.write(content)
        temporary = Path(stream.name)
    try:
        temporary.chmod(0o755)
        temporary.replace(target)
    finally:
        temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
