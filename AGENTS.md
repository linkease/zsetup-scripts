# zsetup-scripts Agent Notes

## DDNSTO product configuration (2026-11-17)

- Before changing recommended versions, preparing a candidate, publishing or rolling back DDNSTO,
  read `docs/ddnsto-release-sop.md` and create/update its linked release record. Follow its stage gates;
  the SOP does not authorize commits, device mutations or deployments.

- DDNSTO is the apps-layout-v2 reference implementation. Read `docs/apps-layout-v2.md` and
  preserve its minimal `app.json`, `install.sh`, `install.ps1`, `install.md`,
  `versions/VERSION/install.*`
  interface. Do not restore compatibility aliases or root-level version directories.
- Native DDNSTO product versions/digests are maintained only in `sources/ddnsto/platform-releases.json`.
- If `sources/ddnsto/templates/NAME.in` exists, edit that template for behavior, not the generated
  `sources/ddnsto/NAME`.
  This includes desktop standalone installers and `install-rules.json`. Other modules remain directly maintained.
- `python3 -B scripts/build-ddnsto-products.py` compiles DDNSTO product metadata and `--check` rejects
  drift. Then run `python3 -B scripts/build.py` for the apps tree. Run
  `python3 -B tests/ddnsto_release_config_test.py` after changes.
- Preserve version-specific compatibility gates; a new recommended version is not proof of a new health protocol.
  See `docs/ddnsto-platform-releases.md` for publication and GUI/Docker boundaries.
- When changing console installation distribution, read `docs/ddnsto-install-deployment.md`.
  `scripts/build.py` generates the standard application entries under `apps/ddnsto/`; maintain
  `apps/ddnsto/install.md` beside them and commit the complete interface. `apps/SHA256SUMS` is
  generated locally, ignored by Git and packaged by the release coordinator; never commit it.
  Operations maps `run.ddnsto.com/install.sh`, `/install.ps1` and `/install.md` directly to
  these three files. Build hashes are consistency checks, not release approval.

- DDNSTO sources, templates and release configuration belong only to `sources/ddnsto/`;
  its sole registration manifest is `apps/ddnsto/app.json`. Generate runtime-only application
  entries with build.py; never put source, README or review.json in `apps/ddnsto/`.
  Review evidence belongs in docs/verification/. Other business installation belongs to its owning `apps/APP/` tree (normally `business.sh`, or `source/`
  for complex apps); zsetup owns download/context/run/install and its existing configuration schema.
  Do not copy runtime-zig or invent a second downloader.
- Read `docs/inventory.md`, `docs/release.md`, `docs/ai-contract.md`, and the owning zsetup product principles/config/lifecycle/release documents before changing behavior.
- `lib/bootstrap.sh` is the shared shell bootstrap source. `scripts/build.py` embeds it in generated
  `apps/APP/install.sh` and compatibility aliases. The catalog references the versioned
  `apps/APP/VERSION/installer.*`; edit the owning apps source, regenerate, then use `--check`.
- Historical source snapshots live in legacy/ with source commit and SHA256 documented in legacy/README.md. Keep old script names out of the root; never build, index or publish the snapshots as current installers. The source DDNSTO repository and existing live URLs must remain until explicit migration verification.
- Scripts 0.1.6 require zsetup >=0.2.4 for native metadata/memory, preserving the 0.2.3 Race/DNS fixes, three HTTPS primaries and the final fallback. Only shell bootstrap may prompt for HTTP after exhausting HTTPS. Do not add unattended downgrade or external SHA dependencies to normal installation.
- Test with local HTTPS fixtures, fake package managers and isolated work/install paths. Never execute a real OpenWrt package or change a host service as a test.
- Add behavior tests before production edits; keep test-only and implementation commits separate. Run `sh scripts/check.sh ZSETUP_ROOT` after meaningful changes.
- Do not rewrite a running shell script in place. Generated entries and package pointers must be installed atomically.
- Product binaries/packages and their version/SHA256 metadata are published ahead of installation by the business server release process. Do not collect, cache or bundle them in this repository's release. Package only installer scripts, canonical zsetup release and the unified configuration. Preserve immutable paths and matching config/size/SHA256; server metadata and device canary remain deployment checks. Local package success is not server availability or publication evidence.

- `apps/APP/` is the aggregate publication owner; its standard `install.md` is public application
  guidance, not a test or maintenance source. DDNSTO implementation sources live outside it as above. Tests and fixtures live under
  `tests/apps/` and must never be copied into `apps/`. The complete apps release publishes the full
  `apps/` tree under `/binary/zsetup-scripts/apps/`; independent product namespaces remain separate.

- LinkEase owns its Linux multi-file/service transaction and OpenWrt opkg workflow in
  `apps/linkease/business.sh`. Reference bytes in legacy/install_linkease_{linux,openwrt}.sh remain
  unchanged. APK is unproven; do not claim it in the index. Linux recovery copies are retained if
  rollback fails; tests never touch host services.

- FastPVE owns only its PVE preflight and verified binary launcher; PVE actions/menus belong to FastPVE. Do not infer PVE major-version support or noninteractive flags from the legacy launcher. Keep the user-supplied Bash snapshot unchanged and syntax-check it with bash -n.


## Shared Build Toolchains

- The workspace's canonical toolchain root is `/projects/workspace-linkease-ubuntu/toolchains/`; set `LINKEASE_TOOLCHAIN_ROOT` to this path and inspect existing versions before downloading tools.
- Zig host compilers, verified archives, global caches and target-specific runtime dependencies are separated there. Business scripts must not download compilers or copy runtime into this repository.
- The owning native repository is `/projects/workspace-linkease-ubuntu/linkease-vpn/linkease-tunnel/zsetup`; use its `scripts/prepare-toolchain.py`, `release/toolchains.json`, and `docs/plans/2026-10-09-desktop-portability.md`. The root toolchain README is another discovery entrypoint for future AI.
- Desktop API compile success is not full zsetup/platform release support. Check the native build evidence and release status before publishing a platform installer.

## Unified Rust release path (2026-10-14)

- Future zsetup source owner is linkease-tunnel/zsetup-rust, backed by canonical
  runtime-rust. Zig zsetup is a frozen protocol/history reference. Do not
  implement a second downloader or keep two product feature implementations.
- Run scripts/check.sh ZSETUP_RUST_ROOT RUST_RELEASE_PACKAGE. Package with
  --zsetup-root ZSETUP_RUST_ROOT --zsetup-release RUST_RELEASE_PACKAGE; both
  use canonical Rust integrity/configuration tools. Historical Zig arguments
  are compatibility paths only, not the default future release workflow.
- scripts-0.1.7 is a local candidate. Linux/Darwin bootstrap dispatch does not
  establish a Mac business mapping. Preserve unverified legacy entries.
- Native release readiness and actual business installation remain separate
  from script/package fixtures. Read the owning unified 0.4.0 evidence before
  public activation; current shared-runtime blocker must not be dropped silently.


## Storage source candidate (2026-10-16)

- scripts0.1.8 requires canonical Rust zsetup >=0.5.0 (storage, bounded
  download/capture and coordinator-aware cancellation). Old0.4.0 cannot run
  these scripts. Preserve old immutable paths; do not publish until separately
  authorized and native/server/device gates are satisfied.
- FastNet0.1.8 alone was authorized and published with Linux core0.5.0 on
  2026-10-17. Other apps'0.1.8 entries remain local candidates and must not be
  imported or uploaded by a whole-catalog production deployment.
- New Linux raw services target systemd; SysV legacy is frozen/unported.
  Linux user preparation/sudo -n commit and explicit root flows share generated
  sources. Never redownload a running installer or weaken root path protection.
- Core/site facts, policy and receipts: docs/linux-install-storage.md.
  Regression migration: docs/2026-10-16-regression-coverage.md.
- Real sudo and systemd tests require the isolated lab container; fixture
  success is not native business package/procd or production connectivity proof.

## FastNet independent rollout (2026-10-16)

- Current rollout scope is FastNet only. Do not change DDNSTO, LinkEase,
  FastPVE or other business files on the production server.
- Read docs/fastnet-independent-release.md. release/applications.json enables
  only FastNet; scripts/package-app-release.py reuses canonical Rust catalog
  generation, preserves unrelated live index records/core/source groups, and
  never uploads. The historical live0.4.0 baseline produced an explicitly
  blocked review: FastNet0.1.8 needs0.5.0. The user separately authorized the
  Linux core upgrade and FastNet rollout on2026-10-17; both are now live.
  Regenerate from a fresh actual live configuration for any future release;
  never reuse the old blocked0.4.0 candidate or weaken the runtime floor.
- scripts/install-app-release.sh is a low-level stage/activate/rollback
  transaction. Public HTTPS readback, safe business canary and explicit
  production authorization are coordinator prerequisites. Tests of this
  primitive do not establish public activation readiness.

## Linkspace independent rollout (2026-10-25)

- Linkspace is explicitly authorized alongside its product binaries. Scoped tools
  enable fastnet and linkspace with separate exact public entry lists; all other
  applications remain disabled. Linkspace installer0.1.0 supports Linux x86_64,
  aarch64 and armv7, reusing the user launcher with native SHA/size cache checks.
- Production changes remain per application; do not upload the aggregate package.
  Use fresh live config, immutable staging, four-site HTTPS and isolated real
  product canaries before locked activation. See `apps/linkspace/README.md`.

## KSpeeder binary installer release (2026-10-26)

- Canonical application directories are `apps/ks-cli` and `apps/kspeeder`. Keep public application
  ids/namespaces `ks-cli` and `kspeeder`; their versioned installers are the catalog sources.
- Installer0.1.0 is Linux binary deployment only: official product metadata,
  native SHA verification, selectable persistent user prefix, exact version,
  current/previous. Never automatically register/start a service or invoke the
  old official installers after installing these managed binaries.
- Desktop/OpenWrt mappings are absent. CLI desktop checksums and native platform
  acceptance remain prerequisites; do not substitute server checksums.
- Shared helper changes use new candidate paths (scripts0.1.9, Linkspace0.1.1),
  preserving already published immutable scripts. Scoped release tools can
  prepare each new app independently. Both Linux0.1.0 installers were published
  on2026-10-26; core stable0.5.1, FastNet and Linkspace remain unchanged.
- Actual release/readback/canary/rollback evidence is in
  `docs/verification/2026-10-26-kspeeder-publish.{md,json}`.
- Server layout and subsequent sync procedure: `docs/kspeeder-installers.md`.

## Complete zsetup-scripts apps candidate (2026-11-22)

- The complete repository `apps/` directory is the public source tree and maps
  only to `/binary/zsetup-scripts/apps/`. Existing `/binary/zsetup`,
  `/binary/ddnsto`, `/binary/fastnet` and other product/core directories are
  dependencies, never the destination of this aggregate business release.
- Production coordination belongs to `scripts/publish-apps.py`. It fixes the
  namespace, packages the full clean candidate by release ID, uses the bundled
  `scripts/publish.sh` transaction, and verifies configured HTTPS mirrors. Do
  not invoke the low-level transaction against a hand-written production path.
- Tests and fixtures remain outside `apps/`. Regenerate and check the committed
  entries, configs and `SHA256SUMS` with `scripts/build.py`.
- The first complete release was published on 2026-11-22 with release ID
  `f0bdc493992caa7d2fc61a9c4ec7ceb5996f0adec2534a01e3490cb0e8943e0d`.
  Preparation and `plan` are local/read-only; never run a later `stage`,
  `publish`, `activate` or `rollback` without explicit production authorization
  for that exact release ID. See `docs/apps-release.md` and the coordinator
  evidence.

## KSpeeder 0.9.1 product mirror (2026-11-22)

- `release/kspeeder-products.json` locks the exact ten GitHub assets for
  `kspeeder/docker_kspeeder v0.9.1` plus the eight current macOS/Windows
  binaries inspected from `kspeeder.com/bin`. Do not add the stale standalone
  installer executables or any unlocked file from that mutable directory.
- Product releases use `scripts/publish-kspeeder-products.py` and map only to
  `/binary/kspeeder/releases/RELEASE_ID/` plus root `release.txt`, `version.txt`
  and `ks-cli-version.txt`. This preserves the previously published Linux-only
  `0.9.1/` directory. Stage immutable bytes, verify four HTTPS sources, then
  activate pointers. The low-level shell transaction never deletes history.
- Future latest-version work starts with `scripts/release-kspeeder.py`: run
  `check`, use `update-lock` when GitHub advances, review and commit the exact
  eighteen-asset lock, then use `prepare`, `plan` and exact-ID `publish`. The wrapper
  must pass generated apps identity checks and the native KSpeeder HTTPS suite
  before it delegates any production mutation.
- KSpeeder and KS-CLI app script 0.1.2 read `release.txt`, verify the immutable
  release checksum list, and support Linux, macOS and Windows without installing
  a service. Publish and verify product bytes before publishing the complete apps
  tree that references them. Production 0.1.1 remains valid until that switch.
- Existing `0.1.0/`, historical tarballs and unversioned files are a separate
  cleanup scope. Never delete them as an implicit side effect of product or
  apps publication. Website changelog deployment belongs to its website repo,
  which is not present here.
- Product release
  `480817559978b120aa1538f47f0ef8b6ca3d3b0b5f6e9c2dc41771f95378f593`
  and apps release
  `11b13925c02d0f0775f33657b4a9eaaf33a0cf7470f89a3c964635b500765956`
  are live. Both transaction phases are `activated`; public KSpeeder and KS-CLI
  canaries report 0.9.1. Use the verification record for rollback paths and
  exact evidence before any later change.
- The cross-platform successor product release
  `307a8814882ae13660d824a22d18f94acbcec84d59e846befc1ef58e78e0a9e4`
  and complete apps release
  `417dbd781529dffbbf41f638d7871fa2c8ed7d35da589c0f9a35babb7a9c4902`
  were activated on 2026-11-22. All 96 product and 600 final apps public checks
  passed. The earlier Linux-only releases and immutable directory remain intact.
