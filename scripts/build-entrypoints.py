#!/usr/bin/env python3
"""Embed the one maintained bootstrap into standalone public business entries."""
import argparse
import importlib.util
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
        if app == 'jq':
            subprocess.run(['python3', '-B', str(ROOT/'jq/build.py'), *(['--check'] if args.check else [])], check=True)
            continue
        if app == 'kai-skills':
            sources = {entry["script"] for entry in catalog["installers"] if entry["application"] == app}
            if sources != {"kai-skills/kai-skills-install.sh"}:
                raise ValueError("kai-skills requires one release-bound installer")
            subprocess.run(["sh", "-n", str(ROOT / sources.pop())], check=True)
            continue
        sources = {entry["script"] for entry in catalog["installers"] if entry["application"] == app}
        if len(sources) != 1:
            raise ValueError(f"{app} must have one canonical entry")
        source = ROOT / sources.pop()
        folder = source.parent
        if source.name != f"{app}-install.sh" or not folder.resolve().is_relative_to(ROOT.resolve()):
            raise ValueError("invalid canonical entry path")
        common = helper("bootstrap.sh") + foundation
        if app in {"ddnsto", "linkease"}:
            common += dispatch + helper("install-service.sh") + helper("install-package.sh") + helper("install-privilege.sh")
        else:
            common += helper("install-launcher.sh")
        if app in {"ks-cli", "kspeeder"}:
            common += (ROOT / "kspeeder/lib/binary.sh").read_text().rstrip() + "\n\n"
        business = (folder / "business.sh").read_text().rstrip() + "\n\n"
        if app == 'ddnsto':
            business = ((folder / 'managed-cli.sh').read_text().rstrip() + '\n\n'
                        + (folder / 'managed-service.sh').read_text().rstrip() + '\n\n'
                        + business)
            # One shell entry on Linux/NAS/macOS; no sibling source fetch.
            common = ('#!/bin/sh\nif [ "$(uname -s)" = Darwin ]; then\n(\n'
                      + (folder / 'install-macos.sh').read_text().rstrip()
                      + '\n)\nexit "$?"\nfi\n\n' + common
                      + (folder / 'bootstrap-policy.sh').read_text() + '\n')
            for name in ('product-pins.sh', 'docker-probe.sh', 'docker-lifecycle.sh',
                         'method-selection.sh', 'synology-download.sh', 'extra-platforms.sh',
                         'openwrt-lifecycle.sh', 'openwrt-adapter.sh'):
                business += (folder / name).read_text().rstrip() + '\n\n'
        content = common + "\n# Business logic: maintained in " + str(folder.relative_to(ROOT)) + "/business.sh\n"
        content += business
        # Emit the same maintained sources for the root phase. A running
        # one-key sh -c entry need not be a file and never downloads itself.
        if app in {"ddnsto", "linkease"}:
            # Root phase never bootstraps, prepares as a user, or selects a
            # launcher/package flow. Keep the one-key sh -c argv below Linux's
            # single-argument limit without requiring a second script fetch.
            program = 'set -eu\nstatus() { printf \'%s\\n\' "$*" >&2; }\n'
            program += foundation + dispatch + helper("install-service.sh")
            program += business + f'\ninstaller_dispatch {app} "$@"\n'
            program = "\n".join(line for line in program.splitlines() if line.strip() and not line.lstrip().startswith("#")) + "\n"
            delimiter = "ZSETUP_PRIVATE_ROOT_PROGRAM"
            assert delimiter not in program
            if len(program.encode()) > 1048576:
                raise ValueError(f"{app} exceeds verified privileged-program copy budget")
            content += f"installer_privileged_program() {{\ncat <<'{delimiter}'\n{program}{delimiter}\n}}\n"
        content += "\nbootstrap_and_run() {\n    status \"[1/4] Checking zsetup...\"\n"
        content += "    ddnsto_bootstrap_zsetup || return $?\n" if app == 'ddnsto' else "    bootstrap_zsetup\n"
        content += "    status \"      zsetup $RESCUE_VERSION is ready\"\n    ZSETUP_BIN=$ACTIVE_ZSETUP\n"
        content += "    ZSETUP_SOURCE_BASES=${ZSETUP_SOURCE_BASES:-$DIRECT_PRIMARY_BASES}\n"
        content += "    ZSETUP_SOURCE_FALLBACK=${ZSETUP_SOURCE_FALLBACK-$DIRECT_FALLBACK_BASE}\n"
        content += "    export ZSETUP_BIN ZSETUP_ARCH ZSETUP_SOURCE_BASES ZSETUP_SOURCE_FALLBACK\n"
        content += f"    installer_dispatch {app} \"$@\"\n}}\n\n"
        content += (folder / "main.sh").read_text()
        # DDNSTO's multi-platform entry is executed as a verified local file,
        # never as a single shell argument. Other apps retain their sh -c ABI.
        if app == 'ddnsto' and len(content.encode()) > 1048576:
            raise ValueError('ddnsto exceeds standalone file budget')
        if app != 'ddnsto' and len(content.encode()) >= 131072:
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

    windows_catalog = json.loads((ROOT / "catalog-windows.json").read_text())
    if set(windows_catalog) != {"schema_version", "config_version", "installers"} or windows_catalog["schema_version"] != 1:
        raise ValueError("invalid Windows installer catalog")
    windows_apps = {entry["application"] for entry in windows_catalog["installers"]}
    if windows_apps != {"scoop", "kai-skills"}:
        raise ValueError("unsupported Windows generated-entry set")
    subprocess.run([
        "python3", "-B", str(ROOT / "scoop/build.py"),
        *(["--check"] if args.check else []),
    ], check=True)
    kai_build_spec = importlib.util.spec_from_file_location(
        "kai_skills_build", ROOT / "kai-skills/build.py")
    kai_build = importlib.util.module_from_spec(kai_build_spec)
    kai_build_spec.loader.exec_module(kai_build)
    windows_installer = ROOT / "kai-skills/kai-skills-install.ps1"
    windows_channel = ROOT / "kai-skills/setup.ps1"
    maintained = (ROOT / "kai-skills/business.ps1").read_text(encoding="utf-8")
    if not windows_installer.is_file() or not windows_installer.read_text(encoding="utf-8").endswith(maintained):
        raise ValueError("stale generated Windows kai-skills installer")
    if not windows_channel.is_file() or windows_channel.read_text(encoding="utf-8") != kai_build.windows_channel_entrypoint():
        raise ValueError("stale generated Windows kai-skills channel")

    # Owner-provided offline removal resource; no bootstrap or network access.
    output = ROOT / "scripts/remove-managed.sh"
    content = ('#!/bin/sh\nset -eu\n' + helper("install-storage.sh") + helper("install-transaction.sh") + helper("remove-managed.sh")).rstrip() + '\n'
    if args.check:
        if not output.is_file() or output.read_text() != content:
            raise SystemExit(f"stale generated entry: {output}")
    else:
        with tempfile.NamedTemporaryFile(mode="w", dir=output.parent, prefix=".entry-", delete=False) as stream:
            stream.write(content)
            temporary = Path(stream.name)
        temporary.chmod(0o755)
        temporary.replace(output)
    subprocess.run(["sh", "-n", str(output)], check=True)


if __name__ == "__main__":
    main()
