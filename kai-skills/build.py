#!/usr/bin/env python3
"""Bind one immutable schema-3 release to the canonical Business Installer."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import tempfile


ROOT = Path(__file__).resolve().parent
BOOTSTRAP = ROOT.parent / "lib/bootstrap.sh"


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def entrypoint(version, kind=None, identity=None):
    selection = ""
    guard = ""
    if kind is not None:
        option = "--skill" if kind == "skill" else "--system"
        guard = (
            "for kai_arg in \"$@\"; do\n"
            "  case \"$kai_arg\" in --skill|--system) "
            "echo 'kai-skills: this entrypoint has a fixed selection' >&2; exit 2 ;; esac\n"
            "done\n"
        )
        selection = f" {option} '{identity}'"
    return (
        "#!/bin/sh\nset -eu\n"
        f"KAI_SKILLS_REQUESTED_RELEASE='{version}'\n"
        "export KAI_SKILLS_REQUESTED_RELEASE\n"
        + guard
        + f"exec \"${{ZSETUP_BIN:-zsetup}}\" install kai-skills --foreground --{selection} \"$@\"\n"
    )


def channel_entrypoint():
    """Return the version-free public current-channel launcher."""
    bootstrap = BOOTSTRAP.read_text(encoding="utf-8")
    if not bootstrap.startswith("#!/bin/sh\n"):
        raise SystemExit("invalid shared zsetup bootstrap")
    # Keep the initial downloader in the shared, tested bootstrap.  This
    # launcher only owns the durable cache default and the application argv.
    bootstrap = bootstrap.removeprefix("#!/bin/sh\n")
    return (
        "#!/bin/sh\nset -eu\n\n"
        "if [ -z \"${ZSETUP_ROOT:-}\" ]; then\n"
        "  if [ -n \"${XDG_DATA_HOME:-}\" ]; then\n"
        "    ZSETUP_ROOT=$XDG_DATA_HOME/zsetup\n"
        "  elif [ -n \"${HOME:-}\" ] && [ \"$HOME\" != / ]; then\n"
        "    ZSETUP_ROOT=$HOME/.local/share/zsetup\n"
        "  else\n"
        "    ZSETUP_ROOT=/tmp/zsetup\n"
        "  fi\n"
        "  export ZSETUP_ROOT\n"
        "fi\n\n"
        + bootstrap.rstrip()
        + "\n\n"
        "bootstrap_zsetup\n"
        "ZSETUP_BIN=$ACTIVE_ZSETUP\n"
        "ZSETUP_SOURCE_BASES=${ZSETUP_SOURCE_BASES:-$DIRECT_PRIMARY_BASES}\n"
        "ZSETUP_SOURCE_FALLBACK=${ZSETUP_SOURCE_FALLBACK-$DIRECT_FALLBACK_BASE}\n"
        "export ZSETUP_BIN ZSETUP_ARCH ZSETUP_SOURCE_BASES ZSETUP_SOURCE_FALLBACK\n"
        "exec \"$ACTIVE_ZSETUP\" install kai-skills --foreground -- \"$@\"\n"
    )


def entrypoint_files(manifest):
    files = {"install.sh": entrypoint(manifest["version"])}
    for artifact in manifest["artifacts"]:
        kind = artifact.get("kind")
        identity = artifact.get("id")
        if kind not in ("skill", "system") or not isinstance(identity, str):
            raise SystemExit("invalid entrypoint artifact")
        directory = "skills" if kind == "skill" else "systems"
        files[f"{directory}/{identity}.sh"] = entrypoint(
            manifest["version"], kind, identity
        )
    return files


def write_entrypoints(directory, files, check):
    if check:
        actual = {
            str(path.relative_to(directory)): path.read_text(encoding="utf-8")
            for path in directory.rglob("*.sh")
        } if directory.is_dir() else {}
        if actual != files:
            raise SystemExit("stale generated kai-skills entrypoints")
        return
    if directory.exists() or directory.is_symlink():
        raise SystemExit("entrypoints directory must be new")
    for relative, content in files.items():
        target = directory / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
        target.chmod(0o755)


def write_file(path, content, check):
    if check:
        if not path.is_file() or path.read_text(encoding="utf-8") != content:
            raise SystemExit("stale generated kai-skills channel entrypoint")
        return
    if path.exists() or path.is_symlink():
        raise SystemExit("channel entrypoint output must be new")
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                     prefix=".kai-skills-channel-", delete=False) as stream:
        stream.write(content)
        temporary = Path(stream.name)
    try:
        temporary.chmod(0o755)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--entrypoints-dir", type=Path)
    parser.add_argument("--channel-entrypoint", type=Path)
    parser.add_argument("--channel-only", action="store_true")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    channel = channel_entrypoint()
    if args.channel_only:
        if args.channel_entrypoint is None or args.release is not None or args.output is not None \
                or args.entrypoints_dir is not None:
            parser.error("--channel-only requires only --channel-entrypoint")
        write_file(args.channel_entrypoint, channel, args.check)
        return
    if args.release is None or args.output is None:
        parser.error("--release and --output are required unless --channel-only is used")
    manifest_path = args.release.resolve() / "release-manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if (manifest.get("schemaVersion"), manifest.get("distribution"),
            manifest.get("minimumZsetupVersion"), manifest.get("archiveFormat")) != (
            3, "kai-skills-zsetup", "0.6.0", "tar.gz"):
        raise SystemExit("invalid kai-skills release manifest")
    version = manifest.get("version")
    if not isinstance(version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?", version):
        raise SystemExit("invalid kai-skills release version")
    prefix = (
        "#!/bin/sh\nset -eu\n\n"
        f"KAI_SKILLS_RELEASE='{version}'\n"
        f"KAI_SKILLS_MANIFEST_PATH='releases/{version}/release-manifest.json'\n"
        f"KAI_SKILLS_MANIFEST_SHA256='{sha(manifest_path)}'\n"
        f"KAI_SKILLS_MANIFEST_SIZE='{manifest_path.stat().st_size}'\n\n"
    )
    content = prefix + (ROOT / "business.sh").read_text(encoding="utf-8")
    entries = entrypoint_files(manifest)
    if args.check:
        if not args.output.is_file() or args.output.read_text(encoding="utf-8") != content:
            raise SystemExit("stale generated kai-skills installer")
        if args.entrypoints_dir is not None:
            write_entrypoints(args.entrypoints_dir, entries, True)
        if args.channel_entrypoint is not None:
            write_file(args.channel_entrypoint, channel, True)
        return
    if args.output.exists() or args.output.is_symlink():
        raise SystemExit("output must be a new file")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=args.output.parent,
                                     prefix=".kai-skills-installer-", delete=False) as stream:
        stream.write(content)
        temporary = Path(stream.name)
    try:
        temporary.chmod(0o755)
        temporary.replace(args.output)
    finally:
        temporary.unlink(missing_ok=True)
    if args.entrypoints_dir is not None:
        write_entrypoints(args.entrypoints_dir, entries, False)
    if args.channel_entrypoint is not None:
        write_file(args.channel_entrypoint, channel, False)


if __name__ == "__main__":
    main()
