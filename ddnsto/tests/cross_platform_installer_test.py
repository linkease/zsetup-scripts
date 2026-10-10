#!/usr/bin/env python3
"""Contract tests for the Windows and macOS DDNSTO business installers."""
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]


def read(name):
    path = ROOT / name
    assert path.is_file(), f"missing installer: {path}"
    return path.read_text(encoding="utf-8")


def test_macos_installer_uses_arch_specific_release_and_launchd():
    content = read("install-macos.sh")
    assert "uname -m" in content
    assert "ddnsto_darwin_cli_" in content
    assert "ddnsto_cli.amd64" in content
    assert "ddnsto_cli.arm64" in content
    assert "launchctl" in content
    assert "--token" in content
    assert "shasum -a 256" in content


def test_windows_installer_supports_x64_cli_and_task_lifecycle():
    content = read("install.ps1")
    assert "ddnsto_windows_cli_" in content
    assert "ddnsto_cli.x86_64.exe" in content
    assert "Get-FileHash" in content
    assert "Register-ScheduledTask" in content
    assert "icacls.exe" in content
    assert "token" in content.lower()
    assert "https://fw.koolcenter.com/binary/ddnsto/windows" in content


def test_cross_platform_installers_have_safe_noninteractive_token_contract():
    mac = read("install-macos.sh")
    win = read("install.ps1")
    assert "TOKEN" in mac
    assert "Token" in win or "TOKEN" in win
    assert "token is required" in mac.lower() or "token required" in mac.lower()
    assert "token is required" in win.lower() or "token required" in win.lower()


if __name__ == "__main__":
    for name, test in sorted(globals().items()):
        if name.startswith("test_"):
            test()
    print("Cross-platform installer contracts passed")
