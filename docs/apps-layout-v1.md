# `apps/` publication layout v1

Status: superseded by [apps layout v2](apps-layout-v2.md). This document records
the historical schema-v1 contract. The repository `apps/` directory is
the public release tree: every byte below it may be copied to the download
server.  Tests, fixtures, build tools, credentials and production connection
data live outside `apps/`.

## Per-application contract

DDNSTO has migrated to layout v2 and is not an exception to this historical
contract. Remaining schema-v1 applications retain the layout below. Detached
release validation and deployment require only `apps/`, not external source
directories.

Each application owns one directory:

```text
apps/APP/
  app.json
  install.sh                 # generated standard POSIX entry, when supported
  install.ps1                # generated standard Windows entry, when supported
  COMPATIBILITY-ALIAS        # optional generated or frozen legacy entry
  VERSION/
    installer.sh             # immutable POSIX payload, when supported
    installer.ps1            # immutable Windows payload, when supported
```

`app.json` is the sole registration source.  The application id equals its
directory name.  The current payload path is derived from the id, version and
entrypoint type.  Published version directories are immutable; a byte change
requires a new version.

The standard entry bootstraps a verified zsetup and runs
`zsetup install APP --foreground -- "$@"`.  It is never an installer payload.
Generated zsetup configuration may point only at a versioned `installer.sh` or
`installer.ps1`, preventing entry recursion.

## Repository and public mapping

The complete `apps/` directory maps to the zsetup-scripts business namespace.
Existing `/binary/zsetup`, `/binary/ddnsto` and other product directories are
dependencies, not publication targets of this repository:

```text
apps/fastnet/install.sh         -> /binary/zsetup-scripts/apps/fastnet/install.sh
apps/fastnet/0.1.9/installer.sh -> /binary/zsetup-scripts/apps/fastnet/0.1.9/installer.sh
apps/zsetup/config.json         -> /binary/zsetup-scripts/apps/zsetup/config.json
```

Generated configuration paths include the `zsetup-scripts/apps/` prefix while
their source bases remain `/binary`. This lets zsetup fetch the versioned
installer from the business namespace and lets that installer continue using
existing product resources such as `/binary/fastnet/` and `/binary/ddnsto/`.
Standard entries explicitly download the business configuration from the
nested namespace; bootstrap zsetup binaries still come from `/binary/zsetup/`.

`apps/zsetup/config.json`, generated standard entries and compatibility aliases
are committed. `apps/SHA256SUMS` is generated locally, ignored by Git and
bundled by the release coordinator. `scripts/build.py --check` detects drift.
No second release tree is generated.

## Public-tree policy

The tree may contain public application source and documentation.  It must not
contain tests, fixtures, caches, logs, local overrides, tokens, private keys,
authorization data, production SSH information, special files or symlinks.
Production publication requires a clean reviewed Git commit.

Tests mirror applications below `tests/apps/`.  Shared contract and deployment
tests live below `tests/contracts/`; their fixtures live below `tests/fixtures/`.

## Publication and rollback

The only publication input is `apps/`. Test deployments copy that directory to
`BINARY_ROOT/zsetup-scripts/apps` directly.
Production uses `scripts/publish-apps.py`; its full contract is documented in
[`apps-release.md`](apps-release.md). It copies the same bytes to a private,
release-ID staging directory, verifies `SHA256SUMS`, stages immutable version
files, verifies them through every configured HTTPS source, snapshots current
mutable entries and configuration, then activates and verifies the complete
configuration and entries. The coordinator derives the destination as
`BINARY_ROOT/zsetup-scripts/apps`; callers cannot substitute `/binary/` itself.
Publication never uses delete synchronization and never removes business
products, native zsetup releases or historical installers.

Server resources and production rollout metadata do not belong in `apps/`.
They are supplied to the publication command or owned by the production
orchestration repository.
