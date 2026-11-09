# kai-skills Business Installer

This module binds one immutable schema-3 `kai-skills` release to a verified
Business Installer. The target needs zsetup 0.6.0, POSIX shell, jq (the OpenWrt
build without Oniguruma is supported) and the
base file operations required by the managed lifecycle. zsetup owns HTTPS
download, size/SHA-256 verification and safe bounded archive extraction.

Generate a release-specific script:

```sh
python3 -B kai-skills/build.py \
  --release /path/to/kai-skills-release \
  --output /new/path/kai-skills-install.sh \
  --entrypoints-dir /new/path/entrypoints \
  --channel-entrypoint /new/path/install.sh
```

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
