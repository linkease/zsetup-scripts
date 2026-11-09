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
WINDOWS_BOOTSTRAP = ROOT.parent / "lib/bootstrap.ps1"


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
        "kai_skills_usage() {\n"
        "  cat <<'KAI_SKILLS_USAGE'\n"
        "Kai Skills installer\n"
        "\n"
        "Install one skill:\n"
        "  curl -fsSL https://fw.koolcenter.com/binary/kai/kai-skills/setup.sh | sh -s -- SKILL_ID\n"
        "\n"
        "Install all skills for this Ubuntu or iStoreOS system:\n"
        "  curl -fsSL https://fw.koolcenter.com/binary/kai/kai-skills/setup.sh | sh -s -- all\n"
        "\n"
        "Default destination: ~/.agents/skills\n"
        "Advanced fallback: use --skill/--system with --consumer, --scope or --target-skills.\n"
        "KAI_SKILLS_USAGE\n"
        "}\n\n"
        "kai_skills_fail() {\n"
        "  echo \"kai-skills: $*\" >&2\n"
        "  exit 2\n"
        "}\n\n"
        "kai_skills_reject_selection_override() {\n"
        "  for kai_arg in \"$@\"; do\n"
        "    case \"$kai_arg\" in\n"
        "      --skill|--system) kai_skills_fail 'the short selection cannot be combined with --skill or --system' ;;\n"
        "    esac\n"
        "  done\n"
        "}\n\n"
        "kai_skills_unquote_os_value() {\n"
        "  kai_value=$1\n"
        "  case \"$kai_value\" in\n"
        "    \\\"*\\\") kai_value=${kai_value#\\\"}; kai_value=${kai_value%\\\"} ;;\n"
        "    \\'*\\') kai_value=${kai_value#\\'}; kai_value=${kai_value%\\'} ;;\n"
        "  esac\n"
        "  printf '%s\\n' \"$kai_value\"\n"
        "}\n\n"
        "kai_skills_detect_system() {\n"
        "  kai_os_release=${KAI_SKILLS_OS_RELEASE_FILE:-/etc/os-release}\n"
        "  kai_os_id= kai_os_like=\n"
        "  if [ -r \"$kai_os_release\" ]; then\n"
        "    while IFS= read -r kai_line || [ -n \"$kai_line\" ]; do\n"
        "      case \"$kai_line\" in\n"
        "        ID=*) kai_os_id=$(kai_skills_unquote_os_value \"${kai_line#ID=}\") ;;\n"
        "        ID_LIKE=*) kai_os_like=$(kai_skills_unquote_os_value \"${kai_line#ID_LIKE=}\") ;;\n"
        "      esac\n"
        "    done < \"$kai_os_release\"\n"
        "  fi\n"
        "  case \"$kai_os_id\" in\n"
        "    ubuntu) printf '%s\\n' ubuntu; return ;;\n"
        "    istoreos|openwrt|lede) printf '%s\\n' istoreos; return ;;\n"
        "  esac\n"
        "  case \" $kai_os_like \" in\n"
        "    *' openwrt '*|*' lede '*) printf '%s\\n' istoreos; return ;;\n"
        "    *' ubuntu '*) printf '%s\\n' ubuntu; return ;;\n"
        "  esac\n"
        "  if [ \"$kai_os_release\" = /etc/os-release ] && [ -r /etc/openwrt_release ]; then\n"
        "    printf '%s\\n' istoreos\n"
        "    return\n"
        "  fi\n"
        "  return 1\n"
        "}\n\n"
        "if [ \"$#\" -eq 0 ]; then\n"
        "  kai_skills_usage >&2\n"
        "  kai_skills_fail 'choose a skill or all'\n"
        "fi\n"
        "case \"$1\" in\n"
        "  -h|--help) kai_skills_usage; exit 0 ;;\n"
        "  all)\n"
        "    shift\n"
        "    kai_skills_reject_selection_override \"$@\"\n"
        "    kai_system=$(kai_skills_detect_system) ||\n"
        "      kai_skills_fail 'cannot detect Ubuntu or iStoreOS; retry with --system ubuntu or --system istoreos'\n"
        "    set -- --system \"$kai_system\" \"$@\"\n"
        "    ;;\n"
        "  -*) ;;\n"
        "  *)\n"
        "    kai_skill=$1\n"
        "    case \"$kai_skill\" in ''|*[!a-z0-9-]*) kai_skills_fail 'invalid skill id' ;; esac\n"
        "    shift\n"
        "    kai_skills_reject_selection_override \"$@\"\n"
        "    set -- --skill \"$kai_skill\" \"$@\"\n"
        "    ;;\n"
        "esac\n\n"
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


def windows_channel_entrypoint():
    bootstrap = WINDOWS_BOOTSTRAP.read_text(encoding="utf-8").rstrip()
    return (
        "param(\n"
        "    [Parameter(Position=0)][string]$Selection,\n"
        "    [Parameter(ValueFromRemainingArguments=$true)][string[]]$InstallerArguments\n"
        ")\n"
        "$ErrorActionPreference = 'Stop'\n"
        "$utf8 = [Text.UTF8Encoding]::new($false)\n"
        "[Console]::InputEncoding = $utf8\n[Console]::OutputEncoding = $utf8\n$OutputEncoding = $utf8\n\n"
        "function Show-KaiSkillsUsage {\n"
        "    Write-Output 'Install one skill:'\n"
        "    Write-Output \"  & ([scriptblock]::Create((irm 'https://fw.koolcenter.com/binary/kai/kai-skills/setup.ps1'))) kai-software\"\n"
        "    Write-Output 'Install all Windows skills: replace kai-software with all'\n"
        "    Write-Output 'Default destination: $HOME\\.agents\\skills'\n"
        "}\n"
        "if (-not $Selection) { Show-KaiSkillsUsage; throw 'kai-skills: choose a skill or all' }\n"
        "if ($Selection -in @('-h', '--help')) { Show-KaiSkillsUsage; return }\n"
        "$business = @()\n"
        "if ($Selection -ceq 'all') { $business += @('--system', 'windows') }\n"
        "elseif ($Selection.StartsWith('-')) { $business += $Selection }\n"
        "elseif ($Selection -cmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') { $business += @('--skill', $Selection) }\n"
        "else { throw 'kai-skills: invalid skill id' }\n"
        "$business += @($InstallerArguments)\n"
        "if (-not $env:ZSETUP_ROOT) {\n"
        "    $data = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { $HOME }\n"
        "    if (-not $data) { throw 'kai-skills: cannot resolve a durable zsetup directory' }\n"
        "    $env:ZSETUP_ROOT = Join-Path $data 'zsetup'\n"
        "}\n\n"
        + bootstrap + "\n\n"
        "$active = Get-ZsetupBootstrap\n"
        "& $active install kai-skills --foreground -- @business\n"
        "exit $LASTEXITCODE\n"
    )


def windows_installer(manifest_path, version):
    return (
        f"$script:KaiSkillsRelease = '{version}'\n"
        f"$script:KaiSkillsManifestPath = 'releases/{version}/release-manifest.json'\n"
        f"$script:KaiSkillsManifestSha256 = '{sha(manifest_path)}'\n"
        f"$script:KaiSkillsManifestSize = {manifest_path.stat().st_size}\n\n"
        + (ROOT / "business.ps1").read_text(encoding="utf-8")
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
    parser.add_argument("--windows-output", type=Path)
    parser.add_argument("--windows-channel-entrypoint", type=Path)
    parser.add_argument("--channel-only", action="store_true")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    channel = channel_entrypoint()
    windows_channel = windows_channel_entrypoint()
    if args.channel_only:
        if (args.channel_entrypoint is None and args.windows_channel_entrypoint is None) or \
                args.release is not None or args.output is not None or args.entrypoints_dir is not None \
                or args.windows_output is not None:
            parser.error("--channel-only requires at least one channel entrypoint")
        if args.channel_entrypoint is not None:
            write_file(args.channel_entrypoint, channel, args.check)
        if args.windows_channel_entrypoint is not None:
            write_file(args.windows_channel_entrypoint, windows_channel, args.check)
        return
    if args.release is None or (args.output is None and args.windows_output is None):
        parser.error("--release and at least one installer output are required unless --channel-only is used")
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
    windows_content = windows_installer(manifest_path, version)
    entries = entrypoint_files(manifest)
    if args.check:
        if args.output is not None and (not args.output.is_file() or args.output.read_text(encoding="utf-8") != content):
            raise SystemExit("stale generated kai-skills installer")
        if args.windows_output is not None and (not args.windows_output.is_file() or args.windows_output.read_text(encoding="utf-8") != windows_content):
            raise SystemExit("stale generated Windows kai-skills installer")
        if args.entrypoints_dir is not None:
            write_entrypoints(args.entrypoints_dir, entries, True)
        if args.channel_entrypoint is not None:
            write_file(args.channel_entrypoint, channel, True)
        if args.windows_channel_entrypoint is not None:
            write_file(args.windows_channel_entrypoint, windows_channel, True)
        return
    if args.output is not None:
        write_file(args.output, content, False)
    if args.windows_output is not None:
        write_file(args.windows_output, windows_content, False)
    if args.entrypoints_dir is not None:
        write_entrypoints(args.entrypoints_dir, entries, False)
    if args.channel_entrypoint is not None:
        write_file(args.channel_entrypoint, channel, False)
    if args.windows_channel_entrypoint is not None:
        write_file(args.windows_channel_entrypoint, windows_channel, False)


if __name__ == "__main__":
    main()
