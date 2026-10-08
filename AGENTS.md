# zsetup-scripts Agent Notes

- Business installation belongs to `APP/business.sh`; zsetup owns download/context/run/install and its existing configuration schema. Do not copy runtime-zig or invent a second downloader.
- Read `docs/inventory.md`, `docs/release.md`, `docs/ai-contract.md`, and the owning zsetup product principles/config/lifecycle/release documents before changing behavior.
- `lib/bootstrap.sh` is the shared shell bootstrap source extracted from tested FastNet. `scripts/build-entrypoints.py` embeds it; generated `APP/install.sh` is the only public entry. Edit maintained sources, regenerate, then use `--check`.
- Root legacy names are symlinks. The source DDNSTO repository and existing live URLs must remain until explicit migration verification.
- Scripts 0.1.3 require zsetup >=0.2.4 for native metadata/memory, preserving the 0.2.3 Race/DNS fixes, three HTTPS primaries and the final fallback. Only shell bootstrap may prompt for HTTP after exhausting HTTPS. Do not add unattended downgrade or external SHA dependencies to normal installation.
- Test with local HTTPS fixtures, fake package managers and isolated work/install paths. Never execute a real OpenWrt package or change a host service as a test.
- Add behavior tests before production edits; keep test-only and implementation commits separate. Run `sh scripts/check.sh ZSETUP_ROOT` after meaningful changes.
- Do not rewrite a running shell script in place. Generated entries and package pointers must be installed atomically.
- The user has authorized continuing the proven DDNSTO installer/CDN sources. Collect existing bytes through zsetup with ddnsto/collect-artifacts.py and compute release digests; absent upstream SHA256SUMS is not an artifact blocker or an extra approval requirement. Production candidates still preserve immutable paths, matching config/size/SHA256 and device canary. Local test success is not production publication evidence.

- Each root business folder owns its scripts, tests and business release rules. Public files live under binary/APP/; never publish internal main/business sources, Python tools or tests. Root catalog and packaging remain the complete shared index/release.
