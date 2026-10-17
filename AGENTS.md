# zsetup-scripts Agent Notes

- Business installation belongs to `APP/business.sh`; zsetup owns download/context/run/install and its existing configuration schema. Do not copy runtime-zig or invent a second downloader.
- Read `docs/inventory.md`, `docs/release.md`, `docs/ai-contract.md`, and the owning zsetup product principles/config/lifecycle/release documents before changing behavior.
- `lib/bootstrap.sh` is the shared shell bootstrap source extracted from tested FastNet. `scripts/build-entrypoints.py` embeds it; generated `APP/APP-install.sh` is the only public entry. Edit maintained sources, regenerate, then use `--check`.
- Historical source snapshots live in legacy/ with source commit and SHA256 documented in legacy/README.md. Keep old script names out of the root; never build, index or publish the snapshots as current installers. The source DDNSTO repository and existing live URLs must remain until explicit migration verification.
- Scripts 0.1.6 require zsetup >=0.2.4 for native metadata/memory, preserving the 0.2.3 Race/DNS fixes, three HTTPS primaries and the final fallback. Only shell bootstrap may prompt for HTTP after exhausting HTTPS. Do not add unattended downgrade or external SHA dependencies to normal installation.
- Test with local HTTPS fixtures, fake package managers and isolated work/install paths. Never execute a real OpenWrt package or change a host service as a test.
- Add behavior tests before production edits; keep test-only and implementation commits separate. Run `sh scripts/check.sh ZSETUP_ROOT` after meaningful changes.
- Do not rewrite a running shell script in place. Generated entries and package pointers must be installed atomically.
- Product binaries/packages and their version/SHA256 metadata are published ahead of installation by the business server release process. Do not collect, cache or bundle them in this repository's release. Package only installer scripts, canonical zsetup release and the unified configuration. Preserve immutable paths and matching config/size/SHA256; server metadata and device canary remain deployment checks. Local package success is not server availability or publication evidence.

- Each root business folder owns its scripts, tests and business release rules. Public files live under binary/APP/; never publish internal main/business sources, Python tools or tests. Root catalog and packaging remain the complete shared index/release.

- LinkEase owns its Linux multi-file/service transaction and OpenWrt opkg workflow in linkease/business.sh. Reference bytes in legacy/install_linkease_{linux,openwrt}.sh remain unchanged. APK is unproven; do not claim it in the index. Linux recovery copies are retained if rollback fails; tests never touch host services.

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
