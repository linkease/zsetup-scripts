# KSpeeder 0.9.1 product mirror

Status: published on 2026-11-22. Production identities and canary evidence are
recorded in
[`verification/2026-11-22-kspeeder-0.9.1-mirror.md`](verification/2026-11-22-kspeeder-0.9.1-mirror.md).

The authoritative input is the ten assets attached to
`kspeeder/docker_kspeeder` release `v0.9.1`. Their names, sizes and GitHub
SHA256 digests are locked in `release/kspeeder-products.json`. The release
contains the Linux KSpeeder and KS-CLI binaries, their two archives and two
metadata files; macOS, Windows and standalone installer executables visible in
`kspeeder.com/bin/` are outside this Docker/Linux release asset set.

## Public layout

```text
/binary/kspeeder/
  0.9.1/                    # immutable
    ten upstream assets
    release-manifest.json
    SHA256SUMS
  version.txt               # mutable pointer, activated last
  ks-cli-version.txt        # mutable pointer, activated last
```

Existing `0.1.0/`, historical tarballs, old unversioned binaries and installer
entries are not deleted by this release. Cleanup is a separate, explicitly
authorized operation after the versioned mirror and both public apps have
passed production canaries.

## Standard latest-release workflow

`scripts/release-kspeeder.py` is the maintained operator entry point. It reads
GitHub's latest stable release API, requires the exact ten Linux/Docker release
assets and GitHub SHA256 digests, verifies both metadata files against the
binary assets, and checks that the canonical KSpeeder sources and generated
`apps/kspeeder` / `apps/ks-cli` payloads are identical.

Check without changing the repository:

```sh
python3 -B scripts/release-kspeeder.py check \
  --native-bin /ABSOLUTE/PATH/zsetup-linux-x86_64
```

When GitHub has a newer stable release, update only the reviewed product lock:

```sh
python3 -B scripts/release-kspeeder.py update-lock
git diff -- release/kspeeder-products.json
```

Review and commit the lock before preparing or publishing. Product upgrades do
not require an apps installer version bump: the 0.1.1 installers deliberately
read the activated root metadata and then download from
`kspeeder/VERSION/`. Change and rebuild the apps only when installer behavior
itself changes.

After committing, prepare and inspect the exact deployment plan:

```sh
python3 -B scripts/release-kspeeder.py prepare \
  --native-bin /ABSOLUTE/PATH/zsetup-linux-x86_64
python3 -B scripts/release-kspeeder.py plan \
  --native-bin /ABSOLUTE/PATH/zsetup-linux-x86_64 \
  --server SSH_CONFIG_HOST --binary-root /ABSOLUTE/WEB/ROOT/binary
```

Production mutation requires the exact Release ID printed by `prepare`:

```sh
python3 -B scripts/release-kspeeder.py publish \
  --native-bin /ABSOLUTE/PATH/zsetup-linux-x86_64 \
  --server SSH_CONFIG_HOST --binary-root /ABSOLUTE/WEB/ROOT/binary \
  --approve RELEASE_ID
```

The wrapper refuses publication when the lock is not GitHub latest, relevant
sources are uncommitted, generated apps are stale, their catalog identities do
not match, shell syntax fails, or the isolated native HTTPS/runtime suite fails.
`GITHUB_TOKEN` may be set to avoid anonymous API rate limits; it is never stored
in the lock.

## Transaction implementation

`scripts/publish-kspeeder-products.py` owns preparation and production
coordination. `prepare` downloads every locked GitHub asset over HTTPS, rejects
any size/SHA mismatch, checks the Linux hashes inside both metadata files, and
creates an independently checksummed package below
`dist/kspeeder-products/RELEASE_ID/`.

The coordinator uploads one private release package, stages the immutable
version directory, verifies every byte through all four configured HTTPS
sources, activates only the two root metadata pointers, verifies server bytes,
then repeats the public checks. Separate `stage`, `verify-staged`, `activate`,
`verify` and `rollback` actions are available. The bundled
`install-kspeeder-product-release.sh` is a low-level server transaction and is
not the production entry point.

KSpeeder and KS-CLI app installers default to the four `/binary` source bases,
read their root metadata pointer, then fetch the matching executable from
`kspeeder/VERSION/`. Explicit `KSPEEDER_PRODUCT_*` overrides retain the old
flat layout only for controlled tests or emergency source selection.

The website changelog is a separate static documentation deployment. Its
public page stopped at 0.8.2 even though GitHub and `kspeeder.com/bin` already
served 0.9.1. Its source is not in this repository or the visible public
KSpeeder organization repositories; updating that page must use its owning
website repository and must not be simulated by editing download-server files.
