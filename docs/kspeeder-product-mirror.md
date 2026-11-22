# KSpeeder 0.9.1 product mirror

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

## Reproducible workflow

`scripts/publish-kspeeder-products.py` owns preparation and production
coordination. `prepare` downloads every locked GitHub asset over HTTPS, rejects
any size/SHA mismatch, checks the Linux hashes inside both metadata files, and
creates an independently checksummed package below
`dist/kspeeder-products/RELEASE_ID/`.

```sh
python3 -B scripts/publish-kspeeder-products.py prepare
python3 -B scripts/publish-kspeeder-products.py plan \
  --server SSH_CONFIG_HOST --binary-root /ABSOLUTE/WEB/ROOT/binary
```

Production requires the exact ID printed by `prepare`:

```sh
python3 -B scripts/publish-kspeeder-products.py publish \
  --server SSH_CONFIG_HOST --binary-root /ABSOLUTE/WEB/ROOT/binary \
  --approve RELEASE_ID
```

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
