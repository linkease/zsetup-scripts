# kai-skills Business Installer

This module binds one immutable schema-3 `kai-skills` release to a verified
Business Installer. Linux targets need zsetup 0.6.0, POSIX shell, jq (the
OpenWrt build without Oniguruma is supported) and the base file operations
required by the managed lifecycle. Windows 10/11 x64 targets need PowerShell
5.1 and the i686 zsetup binary; they do not need Git, Node.js, Bash, jq or an
external archive tool. zsetup owns HTTPS download, size/SHA-256 verification
and safe bounded archive extraction on both paths.

Generate a release-specific script:

```sh
python3 -B kai-skills/build.py \
  --release /path/to/kai-skills-release \
  --output /new/path/kai-skills-install.sh \
  --entrypoints-dir /new/path/entrypoints \
  --channel-entrypoint /new/path/install.sh
```

Add `--windows-output /new/path/kai-skills-install.ps1` and
`--windows-channel-entrypoint /new/path/setup.ps1` to generate the pinned
Windows Business Installer and its version-free public channel.

The generated Business Installer pins the exact manifest. Product Configuration
must in turn pin this generated script's exact size and SHA-256. In installer
mode the script never downloads itself.

The separately generated `--channel-entrypoint` is the stable, version-free
public `/binary/kai/kai-skills/setup.sh`; `install.sh` is published as a
byte-identical compatibility alias. It embeds the shared zsetup shell
bootstrap, caches the selected core below `ZSETUP_ROOT` (by default the user's
data directory), then invokes the `kai-skills` Product Configuration
application. It deliberately does not export `KAI_SKILLS_REQUESTED_RELEASE`:
Product Configuration is the current-channel pointer and the immutable
Business Installer remains the release trust boundary.

The normal user selects only one skill or `all`:

```sh
curl -fsSL https://fw.koolcenter.com/binary/kai/kai-skills/setup.sh | \
  sh -s -- kai-software
curl -fsSL https://fw.koolcenter.com/binary/kai/kai-skills/setup.sh | \
  sh -s -- all
```

On Windows PowerShell, the equivalent version-free commands are:

```powershell
& ([scriptblock]::Create((irm 'https://fw.koolcenter.com/binary/kai/kai-skills/setup.ps1'))) kai-software
& ([scriptblock]::Create((irm 'https://fw.koolcenter.com/binary/kai/kai-skills/setup.ps1'))) all
```

Both default to `$HOME\.agents\skills`; advanced options can follow the first
argument.

The first form expands to `--skill kai-software`. The second reads the local
OS identity and expands Ubuntu to `--system ubuntu`, or iStoreOS/OpenWrt to
`--system istoreos`. Both rely on the Business Installer defaults of Codex,
user scope and `~/.agents/skills`; users do not need to choose those concepts.
No arguments and `--help` return before the zsetup bootstrap. Existing
`--skill`/`--system`, `--consumer`, `--scope` and `--target-skills` arguments
remain available as the advanced recovery interface.

It can be generated independently for a mutable-channel-only rollout:

```sh
python3 -B kai-skills/build.py --channel-only \
  --channel-entrypoint /new/path/install.sh
```

The optional immutable entrypoint directory contains a generic `install.sh`, one fixed
script per published skill under `skills/`, and the exact iStoreOS/Ubuntu
system scripts under `systems/`. They require an installed zsetup, reject
selection overrides, and carry the expected immutable release identity into
the verified Business Installer. They are diagnostic/version-pinned entries,
not the command users need to copy.
