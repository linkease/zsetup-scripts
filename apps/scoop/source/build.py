#!/usr/bin/env python3
"""Generate the one canonical PowerShell Scoop public entry."""
import argparse
import json
from pathlib import Path
import tempfile

SOURCE = Path(__file__).resolve().parent
APP = SOURCE.parent
ROOT = Path(__file__).resolve().parents[3]


def render():
    parts = [
        "# Generated from lib/bootstrap.ps1, scoop/business.ps1 and scoop/main.ps1.\n",
        "$script:ScoopUtf8NoBom = [Text.UTF8Encoding]::new($false)\n",
        "[Console]::InputEncoding = $script:ScoopUtf8NoBom\n",
        "[Console]::OutputEncoding = $script:ScoopUtf8NoBom\n",
        "$OutputEncoding = $script:ScoopUtf8NoBom\n\n",
        (ROOT / "lib/bootstrap.ps1").read_text(encoding="utf-8").rstrip() + "\n\n",
        (SOURCE / "business.ps1").read_text(encoding="utf-8").rstrip() + "\n\n",
        (SOURCE / "main.ps1").read_text(encoding="utf-8").rstrip() + "\n",
    ]
    content = "".join(parts)
    if len(content.encode("utf-8")) > 131072:
        raise ValueError("Scoop PowerShell entry exceeds native installer bound")
    return content


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    output_dir = args.output_dir
    name = "scoop-install.ps1"
    if output_dir is None:
        version = json.loads((APP / "app.json").read_text())["version"]
        output_dir = APP / version
        name = "installer.ps1"
    target = output_dir / name
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
