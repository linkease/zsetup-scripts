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
