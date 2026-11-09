"""Generated kai-skills installer against a real schema-3 release and zsetup archive command."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]
NATIVE = Path(sys.argv[1]).resolve()
KAI_ROOT = Path(sys.argv[2]).resolve()


def run(command, **kwargs):
    result = subprocess.run(command, capture_output=True, text=True, timeout=90, **kwargs)
    if result.returncode != 0:
        raise AssertionError(f"command failed: {command}\nstdout={result.stdout}\nstderr={result.stderr}")
    return result


with tempfile.TemporaryDirectory(prefix="kai-skills-installer-") as name:
    work = Path(name)
    release = work / "release"
    run([sys.executable, str(KAI_ROOT / "tools/release/zsetup_release.py"), "build", str(release)])
    installer = work / "kai-skills-install.sh"
    entrypoints = work / "entrypoints"
    channel = work / "channel-install.sh"
    run([sys.executable, str(ROOT / "kai-skills/build.py"),
         "--release", str(release), "--output", str(installer),
         "--entrypoints-dir", str(entrypoints),
         "--channel-entrypoint", str(channel)])
    run(["sh", "-n", str(installer)])
    run(["sh", "-n", str(channel)])
    entries = sorted(path.relative_to(entrypoints).as_posix()
                     for path in entrypoints.rglob("*.sh"))
    manifest = json.loads((release / "release-manifest.json").read_text())
    assert len(entries) == 1 + len(manifest["artifacts"])
    assert entries[0] == "install.sh"
    assert "skills/kai-software.sh" in entries
    assert entries[-3:] == ["systems/istoreos.sh", "systems/ubuntu.sh", "systems/windows.sh"]
    for entry in entries:
        run(["sh", "-n", str(entrypoints / entry)])

    installer2 = work / "kai-skills-install-2.sh"
    entrypoints2 = work / "entrypoints-2"
    channel2 = work / "channel-install-2.sh"
    run([sys.executable, str(ROOT / "kai-skills/build.py"),
         "--release", str(release), "--output", str(installer2),
         "--entrypoints-dir", str(entrypoints2),
         "--channel-entrypoint", str(channel2)])
    assert installer.read_bytes() == installer2.read_bytes()
    assert channel.read_bytes() == channel2.read_bytes()
    for entry in entries:
        assert (entrypoints / entry).read_bytes() == (entrypoints2 / entry).read_bytes()

    fake_dir = work / "bin"
    fake_dir.mkdir()
    log = work / "zsetup.log"
    fake = fake_dir / "zsetup"
    fake.write_text(r"""#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$TEST_ZSETUP_LOG"
case "$1" in
  download)
    shift; output=; relative=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -o|--output) shift; output=$1 ;;
        https://*) relative=${1#*/releases/$TEST_RELEASE_VERSION/} ;;
      esac
      shift
    done
    test -n "$output" && test -n "$relative"
    cp "$TEST_RELEASE/$relative" "$output"
    ;;
  archive|checksum|checksum-tree) exec "$TEST_NATIVE_ZSETUP" "$@" ;;
  install) exit 97 ;;
  *) exit 98 ;;
esac
""")
    fake.chmod(0o755)
    home = work / "home"
    home.mkdir()
    target = work / "agent-skills"
    env = {
        **os.environ,
        "HOME": str(home),
        "PATH": f"{fake_dir}:/usr/bin:/bin",
        "ZSETUP_INSTALLER_MODE": "1",
        "ZSETUP_BIN": str(fake),
        "ZSETUP_SOURCE_BASES": "https://one.invalid/binary/kai/kai-skills https://two.invalid/binary/kai/kai-skills",
        "ZSETUP_SOURCE_FALLBACK": "https://fallback.invalid/binary/kai/kai-skills",
        "KAI_SKILLS_WORK_BASE": str(work),
        "TEST_ZSETUP_LOG": str(log),
        "TEST_RELEASE": str(release),
        "TEST_RELEASE_VERSION": json.loads((release / "release-manifest.json").read_text())["version"],
        "TEST_NATIVE_ZSETUP": str(NATIVE),
    }

    mismatch = subprocess.run(["sh", str(installer), "--skill", "kai-software"],
                              env={**env, "KAI_SKILLS_REQUESTED_RELEASE": "0.0.0-wrong"},
                              capture_output=True, text=True)
    assert mismatch.returncode == 2
    assert "does not match configured release" in mismatch.stderr

    entry_log = work / "entrypoints.log"
    entry_fake = fake_dir / "entry-zsetup"
    entry_fake.write_text("#!/bin/sh\nprintf '%s|%s\\n' \"$KAI_SKILLS_REQUESTED_RELEASE\" \"$*\" >> \"$ENTRY_LOG\"\n")
    entry_fake.chmod(0o755)
    entry_env = {**os.environ, "ZSETUP_BIN": str(entry_fake), "ENTRY_LOG": str(entry_log)}
    run(["sh", str(entrypoints / "skills/kai-software.sh"),
         "--consumer", "claude", "--scope", "project"], env=entry_env)
    run(["sh", str(entrypoints / "systems/ubuntu.sh"), "--consumer", "codex"],
        env=entry_env)
    run(["sh", str(entrypoints / "install.sh"), "--skill", "kai-software"],
        env=entry_env)
    before_override = entry_log.read_text()
    override = subprocess.run(["sh", str(entrypoints / "skills/kai-software.sh"),
                               "--skill", "kai-download-acceleration"],
                              env=entry_env, capture_output=True, text=True)
    assert override.returncode == 2
    assert entry_log.read_text() == before_override
    entry_calls = entry_log.read_text().splitlines()
    release_version = manifest["version"]
    assert entry_calls == [
        f"{release_version}|install kai-skills --foreground -- --skill kai-software --consumer claude --scope project",
        f"{release_version}|install kai-skills --foreground -- --system ubuntu --consumer codex",
        f"{release_version}|install kai-skills --foreground -- --skill kai-software",
    ]

    # The public channel has no release in its URL or bytes.  With no zsetup in
    # PATH it obtains the current core once, stores it below the user data
    # directory, and offers a short skill/all interface while retaining the
    # complete installer arguments as an advanced fallback.
    bootstrap = work / "bootstrap-source"
    (bootstrap / "zsetup/0.6.4").mkdir(parents=True)
    bootstrap_bin = bootstrap / "zsetup/0.6.4/zsetup-linux-x86_64"
    bootstrap_log = work / "bootstrap-install.log"
    bootstrap_bin.write_text(
        "#!/bin/sh\n"
        "if [ \"${1:-}\" = --version ]; then echo 'zsetup 0.6.4'; exit 0; fi\n"
        "printf '%s\\n' \"$*\" >> \"$BOOTSTRAP_INSTALL_LOG\"\n"
    )
    bootstrap_bin.chmod(0o755)
    (bootstrap / "zsetup/stable").write_text("0.6.4\n")
    bootstrap_digest = __import__("hashlib").sha256(bootstrap_bin.read_bytes()).hexdigest()
    (bootstrap / "zsetup/0.6.4/SHA256SUMS").write_text(
        f"{bootstrap_digest}  zsetup-linux-x86_64\n"
    )
    bootstrap_tools = work / "bootstrap-tools"
    bootstrap_tools.mkdir()
    curl = bootstrap_tools / "curl"
    curl.write_text(
        "#!/bin/sh\nset -eu\nout=\nurl=\n"
        "while [ \"$#\" -gt 0 ]; do\n"
        "  case \"$1\" in -o) shift; out=$1 ;; https://*) url=$1 ;; esac\n"
        "  shift\n"
        "done\n"
        "test -n \"$out\" && test -n \"$url\"\n"
        "cp \"$BOOTSTRAP_SOURCE/${url#https://fixture.invalid/binary/}\" \"$out\"\n"
    )
    curl.chmod(0o755)
    channel_home = work / "channel-home"
    channel_home.mkdir()
    channel_env = {
        **os.environ,
        "HOME": str(channel_home),
        "PATH": f"{bootstrap_tools}:/usr/bin:/bin",
        "ZSETUP_BOOTSTRAP_BASES": "https://fixture.invalid/binary",
        "BOOTSTRAP_SOURCE": str(bootstrap),
        "BOOTSTRAP_INSTALL_LOG": str(bootstrap_log),
    }

    help_result = run(["sh", str(channel), "--help"], env=channel_env)
    assert "sh -s -- SKILL_ID" in help_result.stdout
    assert "sh -s -- all" in help_result.stdout
    assert "~/.agents/skills" in help_result.stdout
    assert not bootstrap_log.exists(), "help bootstrapped zsetup"

    missing = subprocess.run(["sh", str(channel)], env=channel_env,
                             capture_output=True, text=True)
    assert missing.returncode == 2
    assert "choose a skill or all" in missing.stderr
    assert not bootstrap_log.exists(), "missing selection bootstrapped zsetup"

    run(["sh", str(channel), "kai-software"], env=channel_env)
    assert bootstrap_log.read_text().splitlines() == [
        "install kai-skills --foreground -- --skill kai-software"
    ]

    ubuntu_release = work / "ubuntu-os-release"
    ubuntu_release.write_text('NAME="Ubuntu"\nID=ubuntu\nID_LIKE=debian\n')
    run(["sh", str(channel), "all"],
        env={**channel_env, "KAI_SKILLS_OS_RELEASE_FILE": str(ubuntu_release)})
    assert bootstrap_log.read_text().splitlines()[-1] == (
        "install kai-skills --foreground -- --system ubuntu"
    )

    openwrt_release = work / "openwrt-os-release"
    openwrt_release.write_text('NAME="iStoreOS"\nID="openwrt"\n')
    run(["sh", str(channel), "all", "--dry-run"],
        env={**channel_env, "KAI_SKILLS_OS_RELEASE_FILE": str(openwrt_release)})
    assert bootstrap_log.read_text().splitlines()[-1] == (
        "install kai-skills --foreground -- --system istoreos --dry-run"
    )

    unknown_release = work / "unknown-os-release"
    unknown_release.write_text("NAME=Unknown\nID=unknown\n")
    unknown = subprocess.run(["sh", str(channel), "all"],
                             env={**channel_env,
                                  "KAI_SKILLS_OS_RELEASE_FILE": str(unknown_release)},
                             capture_output=True, text=True)
    assert unknown.returncode == 2
    assert "--system ubuntu" in unknown.stderr
    assert len(bootstrap_log.read_text().splitlines()) == 3

    run(["sh", str(channel), "--skill", "kai-software", "--consumer", "claude",
         "--scope", "project"], env=channel_env)
    assert bootstrap_log.read_text().splitlines()[-1] == (
        "install kai-skills --foreground -- --skill kai-software --consumer claude --scope project"
    )
    durable = channel_home / ".local/share/zsetup/rescue/0.6.4/zsetup"
    assert durable.is_file() and os.access(durable, os.X_OK)
    assert "KAI_SKILLS_REQUESTED_RELEASE=" not in channel.read_text()

    invalid = subprocess.run(["sh", str(installer), "--skill", "kai-software", "--system", "istoreos"],
                             env=env, capture_output=True, text=True)
    assert invalid.returncode == 2
    assert not log.exists(), "invalid selection reached zsetup"

    common = ["--skill", "kai-software", "--consumer", "codex", "--scope", "user",
              "--target-skills", str(target)]
    plan = run(["sh", str(installer), *common, "--dry-run", "--json"], env=env)
    receipt = json.loads(plan.stdout)
    assert [item["id"] for item in receipt["packages"]] == ["kai-software"]
    assert not target.exists()
    run(["sh", str(installer), *common], env=env)
    assert (target / "kai-software/SKILL.md").is_file()
    run(["sh", str(installer), *common, "--upgrade"], env=env)
    run(["sh", str(installer), *common, "--uninstall"], env=env)
    assert not (target / "kai-software").exists()

    system_target = work / "system-skills"
    system = run(["sh", str(installer), "--system", "ubuntu", "--consumer", "codex",
                  "--target-skills", str(system_target), "--dry-run", "--json"], env=env)
    members = {item["id"] for item in json.loads(system.stdout)["packages"]}
    lock = json.loads((KAI_ROOT / "bundles/ubuntu-all-on-device.json").read_text())
    assert members == {item["id"] for item in lock["members"]}
    assert not system_target.exists()

    calls = log.read_text().splitlines()
    assert any("release-manifest.json" in line and "--sha256" in line and "--size" in line for line in calls)
    assert any("skills/kai-software.tar.gz" in line and "--sha256" in line for line in calls)
    assert any(line.startswith("archive extract ") and "--max-bytes" in line and "--max-files" in line
               for line in calls), calls
    source = (ROOT / "kai-skills/business.sh").read_text()
    for forbidden in ("git ", "github.com", "node ", "npm ", "npx ", "ks-cli", "kspeeder",
                      "curl ", "wget ", "tar ", "gzip ", "sha256sum", "shasum"):
        assert forbidden not in source.lower(), forbidden

print("kai-skills: generated installer, pinned manifest/package, native extraction and lifecycle passed")
