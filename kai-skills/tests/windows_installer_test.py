"""Windows kai-skills entries are pinned, native and reproducible."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]
KAI_ROOT = Path(sys.argv[1]).resolve()


def run(command):
    result = subprocess.run(command, capture_output=True, text=True, timeout=90)
    if result.returncode:
        raise AssertionError(
            f"command failed: {command}\nstdout={result.stdout}\nstderr={result.stderr}"
        )
    return result


with tempfile.TemporaryDirectory(prefix="kai-skills-windows-") as name:
    work = Path(name)
    release = work / "release"
    run([sys.executable, str(KAI_ROOT / "tools/release/zsetup_release.py"),
         "build", str(release)])
    manifest = json.loads((release / "release-manifest.json").read_text())
    assert manifest["version"] == "1.2.5"

    fixed = work / "kai-skills-install.ps1"
    channel = work / "setup.ps1"
    run([sys.executable, str(ROOT / "kai-skills/build.py"),
         "--release", str(release), "--windows-output", str(fixed),
         "--windows-channel-entrypoint", str(channel)])
    fixed2 = work / "kai-skills-install-2.ps1"
    channel2 = work / "setup-2.ps1"
    run([sys.executable, str(ROOT / "kai-skills/build.py"),
         "--release", str(release), "--windows-output", str(fixed2),
         "--windows-channel-entrypoint", str(channel2)])
    assert fixed.read_bytes() == fixed2.read_bytes()
    assert channel.read_bytes() == channel2.read_bytes()

    fixed_source = fixed.read_text(encoding="utf-8")
    channel_source = channel.read_text(encoding="utf-8")
    digest = hashlib.sha256((release / "release-manifest.json").read_bytes()).hexdigest()
    for value in ("KaiSkillsRelease = '1.2.5'", digest,
                  "archive extract", "install.ps1", "--max-files"):
        assert value in fixed_source, value
    for value in ("Get-ZsetupBootstrap", "install kai-skills", "kai-software", "all",
                  ".agents\\skills"):
        assert value in channel_source, value
    for source in (fixed_source, channel_source):
        lowered = source.lower()
        for forbidden in ("git.exe", "node.exe", "npm.cmd", "npx.cmd", "jq.exe",
                          "bash.exe", "tar.exe"):
            assert forbidden not in lowered, forbidden

    catalog = json.loads((ROOT / "catalog-windows.json").read_text())
    kai = [item for item in catalog["installers"]
           if item["application"] == "kai-skills"]
    assert len(kai) == 1
    assert kai[0]["os"] == "windows" and kai[0]["arch"] == "x86_64"
    assert kai[0]["path"] == (
        "kai/kai-skills/installers/1.2.5/kai-skills-install.ps1"
    )

print("kai-skills: reproducible native Windows installer and channel contract passed")
