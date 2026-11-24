#!/usr/bin/env python3
"""Build the versioned DDNSTO installer from its apps-owned sources."""

import json
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def shared(root: Path, name: str) -> str:
    return (root / "lib" / name).read_text().rstrip() + "\n\n"


def compose(root: Path, app: Path) -> str:
    source = root / 'sources/ddnsto'
    foundation = "".join(
        shared(root, name)
        for name in ("install-storage.sh", "install-bounds.sh", "install-transaction.sh")
    )
    dispatch = shared(root, "install-launcher.sh").split("installer_launcher_prepare()", 1)[0]
    common = shared(root, "bootstrap.sh") + foundation + dispatch
    common += "".join(
        shared(root, name)
        for name in ("install-service.sh", "install-package.sh", "install-privilege.sh")
    )
    common = (
        '#!/bin/sh\nif [ "$(uname -s)" = Darwin ]; then\n(\n'
        + (source / "install-macos.sh").read_text().rstrip()
        + '\n)\nexit "$?"\nfi\n\n'
        + common
    )
    business = "".join(
        (source / name).read_text().rstrip() + "\n\n"
        for name in ("portable-files.sh", "managed-cli.sh", "managed-service.sh", "business.sh")
    )
    business += "".join(
        (source / name).read_text().rstrip() + "\n\n"
        for name in (
            "product-pins.sh", "docker-probe.sh", "docker-lifecycle.sh",
            "method-selection.sh", "synology-download.sh", "extra-platforms.sh",
            "openwrt-lifecycle.sh", "openwrt-adapter.sh", "auto-install.sh",
            "auto-linux.sh", "auto-openwrt.sh", "auto-synology.sh",
            "auto-synology-fresh.sh", "asus-platform.sh", "asus-storage.sh",
            "asus-package.sh", "asus-service.sh", "asus-transaction.sh", "auto-asus.sh",
        )
    )
    # Preserve the historical header bytes of the published 0.2.4 payload.
    content = common + "\n# Business logic: maintained in apps/ddnsto/source/business.sh\n" + business

    program = "set -eu\nstatus() { printf '%s\\n' \"$*\" >&2; }\n"
    program += foundation + dispatch + shared(root, "install-service.sh") + business
    program = "\n".join(
        line for line in program.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ) + "\n"
    delimiter = "ZSETUP_PRIVATE_ROOT_PROGRAM"
    if delimiter in program or len(program.encode()) > 1048576:
        raise ValueError("DDNSTO privileged program is invalid or too large")
    content += f"installer_privileged_program() {{\ncat <<'{delimiter}'\n{program}{delimiter}\n}}\n"
    content += """
bootstrap_and_run() {
    status "[1/4] Checking zsetup..."
    # bootstrap_zsetup_path isolates cleanup traps in a subprocess; retain the
    # selected architecture in this shell for installer-mode context.
    bootstrap_arch || return $?
    ACTIVE_ZSETUP=$(bootstrap_zsetup_path) || {
        bootstrap_rc=$?
        ddnsto_flow_error E_BOOTSTRAP 'zsetup 最新稳定版下载、校验或缓存检查失败，尚未安装客户端' '请检查下载连通性、系统时间及缓存权限；不要删除客户端配置' || :
        return "$bootstrap_rc"
    }
    status "      $("$ACTIVE_ZSETUP" --version) is ready"
    ZSETUP_BIN=$ACTIVE_ZSETUP
    ZSETUP_SOURCE_BASES=${ZSETUP_SOURCE_BASES:-$DIRECT_PRIMARY_BASES}
    ZSETUP_SOURCE_FALLBACK=${ZSETUP_SOURCE_FALLBACK-$DIRECT_FALLBACK_BASE}
    export ZSETUP_BIN ZSETUP_ARCH ZSETUP_SOURCE_BASES ZSETUP_SOURCE_FALLBACK
    installer_dispatch ddnsto "$@"
}

"""
    content += (source / "main.sh").read_text()
    if len(content.encode()) > 1048576:
        raise ValueError("DDNSTO standalone installer exceeds file budget")
    return content


def generate(root: Path = ROOT, apps: Path | None = None, check: bool = False) -> None:
    apps = apps or root / "apps"
    app = apps / "ddnsto"
    if not app.is_dir() or not (apps.parent / 'sources/ddnsto').is_dir():
        return
    manifest = json.loads((apps.parent / 'sources/ddnsto/app.json').read_text())
    output = app / manifest["version"] / "installer.sh"
    content = compose(root, app)
    if check:
        if not output.is_file() or output.read_text() != content:
            raise ValueError(f"stale DDNSTO installer: {output}")
    else:
        output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=output.parent,
            prefix=".installer-", delete=False,
        ) as stream:
            stream.write(content)
            temporary = Path(stream.name)
        try:
            temporary.chmod(0o755)
            temporary.replace(output)
        finally:
            temporary.unlink(missing_ok=True)
    subprocess.run(["sh", "-n", str(output)], check=True)


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    generate(check=args.check)
