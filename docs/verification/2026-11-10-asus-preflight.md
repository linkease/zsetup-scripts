# ASUS six-channel adaptation: preflight and candidate routing

Status: integrated controlled-adapter candidate. RT-AX86U installation and
software-center stop/start canary passed. Published to test `/i`; public-command
canary passed. Production unchanged; changes not committed or pushed.
The initial investigation below is historical; see current evidence at the end.

## Agreed scope

- One copied command, automatic rogsoft/armsoft/mtksoft/ipq32soft/ipq64soft/qcasoft selection.
- Existing compatible ASUS software center required; no firmware flashing or software-center bootstrap.
- Install the complete plugin, preserve same-account configuration, never silently rebind or downgrade.
- Reuse released zsetup, without core changes. A verified HTTPS legacy download path is authorized when armsoft cannot run the released core.
- Local stable startup is the success criterion, not cloud online status.
- RT-AX86U canary: preserve current account, back up before mutations; brief DDNSTO stop/start allowed. No uninstall, clean install, or router reboot in this phase.
- Test environment only; distinguish per-channel real-device evidence from simulated tests.

## Read-only device evidence

SSH host identity was explicitly confirmed by the operator before connection.
No credentials or Token values are recorded here.

| Fact | Observed value |
| --- | --- |
| Model | productid RT-AX86U; odmpid empty |
| Kernel / architecture | Linux 4.1.52 / aarch64 |
| Firmware buildno / extendno | 388.12 / 2 |
| Software center | 1.9.61; sc_url https://rogsoft.ddnsto.com |
| DDNSTO | plugin/client 4.2.8; enabled; Token present (not printed) |
| Autostart | /koolshare/init.d/S70ddnsto.sh links to native config script |
| Process observation | two PIDs resolve to /.koolshare/bin/ddnsto; health/roles not yet established |
| Shell | BusyBox 1.25.1; /bin/sh and /bin/bash both point to BusyBox |
| Missing facilities | command builtin, id and stat, including BusyBox id/stat applets |
| Available transport/hash | curl 8.17.0 and openssl under /usr/sbin |
| Filesystem permissions | /, /tmp, /jffs/.koolshare root-owned 0777 without sticky bit |
| Persistent mount | /jffs root-owned 0755, ext4 /dev/sda5 mounted directly on /jffs |
| Software-center path | /koolshare is symlink jffs/.koolshare |

No device files, service state, account configuration, filesystem permissions or mounts were changed during this phase.

## CDN inspection

All six supplied HTTPS URLs were downloaded with bounded curl into an isolated
local temporary directory. Archives were listed/read, not executed. Each has
plugin version 4.2.8. The exact sizes and SHA-256 pins are in
`ddnsto/asus-platform.sh`; these are reviewed bytes, not a claim of dynamic latest.

Modern channels contain both ARM32/ARM64 binaries; their install scripts match.
armsoft contains a single binary and its own Linux 2.6 installer. Markers are
hnd, arm384, mtk, ipq32, ipq64, qca respectively. Channel cannot be inferred from
CPU alone; conflicting known model/source hints fail closed.

## Candidate work and checks

- `ddnsto/asus-platform.sh`: pure fact-to-channel selection and exact package pins.
- `ddnsto/tests/asus_platform_test.py`: 13 tests, new behavior red before implementation, green after; includes malformed kernel validation and vendor suffixes.
- `sh -n ddnsto/asus-platform.sh`: passed.
- Pins compared against all six actual archive hashes and sizes.

The module is intentionally not embedded into generated entries yet. These
tests do not establish installation, upgrade, startup, or armsoft core compatibility.

## Integration issues requiring resolution

The existing recommendation cache assumes stat/id/command and safe ancestors;
the observed firmware cannot satisfy that policy unchanged. A private directory
alone under non-sticky /tmp is not sufficient. Investigate a narrowly scoped
verified persistent mount anchor, without weakening generic Linux/NAS policy.

Both vendor install scripts hard-code /tmp/ddnsto and clean /tmp/ddnsto* with a
wildcard. They source the existing software-center base.sh. Before integrating,
resolve local writable-parent trust, extraction/execution isolation, bounded
cleanup, backup and failure recovery. Do not bypass checks or silently chmod
system directories to make the canary pass.

Independent read-only review confirmed that the missing-tool and cache-anchor
issues are engineering work, not a reason to weaken generic checks. It also
confirmed that protecting staging alone does not protect executable/plugin
paths beneath writable `.koolshare`. Unchanged vendor execution remains blocked.
Proceeding with a controlled installer requires reconsidering the agreed native
plugin execution/lifecycle integration; alternatively trusting all local writers
would explicitly weaken the local-attacker threat model. Neither change has been
silently made. Router and test-site mutation is held pending that design decision.

## Authorized implementation and current evidence

The operator subsequently authorized a controlled adapter instead of executing
vendor scripts. Firmware permissions and zsetup core remain unchanged.

- All six channels are embedded in the generated installer. Firmware/model/source
  facts determine the channel; contradictory or unknown facts are refused.
- ASUS-only storage verifies a live local /jffs mount and private 0700 directory,
  accommodating missing command/id/stat/mktemp/od without weakening generic checks.
- Modern channels use pinned released zsetup 0.5.0. armsoft uses the authorized
  bounded HTTPS path. Both enforce reviewed package SHA256 and exact size.
- Strict archive extraction copies selected binary/page/icon only; vendor
  install.sh, uninstall.sh and base.sh are never executed.
- Protected runtime integrates software-center lifecycle through controlled
  bridges. Exact plugin files are backed up before replacement; PID identity,
  account/version checks, locking and guarded recovery protect the transaction.
- A healthy verified same-version installation is reused without restart/download.

### RT-AX86U canary

Private backup: `/jffs/.ddnsto-installer/before-canary-20261110`.
It contains configuration credentials and must not be published.

Initial successful candidate SHA256:
`c9d489e42c093cf869d7d4fb6a7c3da94bc602aec18c8600a0f292aa95db60a1`.

- Wrong-account invocation returned E_ACCOUNT without changing original config/PIDs.
- Matching-account install completed; diagnostic file:
  `/jffs/.ddnsto-installer/tmp.b54eb304a4e7a11634e88981/events.log`.
  States: checking → installing → installed → starting → started, exit_code=0.
- Token, enabled flag, client/plugin versions and captured WebDAV settings match
  the pre-canary snapshot. Software-center title/description changed to adapter
  metadata; installed/version metadata remained unchanged.
- Main PPid 1 and its WebDAV child run from protected runtime; they are not duplicate
  daemons. Repeated ensure kept both PIDs, confirming no reinstall or restart.
- Config bridge stop removed both processes; S70 start bridge restored stable
  service. No reboot, uninstall or clean install was performed.

### Explicit limitations

- Only rogsoft RT-AX86U has real-device acceptance. The other five channels,
  including armsoft, have package validation and simulated coverage only.
- At least 96 MiB free JFFS, supported local mount and HTTPS/hash tools are required.
- Legacy binaries differing from the reviewed candidate are refused before stop
  because safe rollback is not established. This canary is 4.2.8 migration, not
  proof of arbitrary older-version upgrades.
- Firmware dbus has no atomic compare-and-set. Controlled lifecycle shares the
  installer lock, but direct privileged dbus/firmware-UI writes cannot be fully
  serialized. Do not edit account settings during installation. Existing nonempty
  Token is never rewritten; empty-account initialization is not atomic against
  concurrent admin writes. Before/after-start checks detect observed changes;
  recovery does not knowingly overwrite a later account value.
- Protected runtime does not secure the whole inherited writable software-center
  directory tree or protect against root/mount changes.
- Migration/failure backups are retained privately, not automatically deleted.
- Full repository checks have a known environment uid_map restriction; optional
  Windows-runtime/local BusyBox skips are not counted as passed acceptance.

## Final regression and test publication

- ASUS suite: 97 tests, 95 passed and 2 optional environment skips.
- Outer-entry cancellation suite: 5 passed, including forwarding/joining, repeated
  SIGTERM, keeping verified files until recovery finishes, stdin/argv/exit status.
  Recovery join deliberately has no forced timeout; SIGKILL cannot be recovered.
- Default workflow 11, Synology 13 and OpenWrt 6 tests passed.
- Recommendation suite: 33 tests, 22 passed and 11 Windows-runtime skips.
- Generator consistency, module layout and git whitespace checks passed.
- Earlier actual six-archive extraction validation passed; BusyBox extraction also
  succeeded independently on the router. Full repository suite is not claimed.

Final Shell SHA256 (500716 bytes):
`bc7c349c95a623dfaf2431e1cd53b0648e1b03bad1f49b9d073362201be829ad`.
Thin wrapper SHA256 (21516 bytes):
`9be760cb4a6d3f6e28d7e4285801816dbf439ef3b0d644a9cb88aa955568191b`.

Updated only the Shell immutable payload, wrapper, Shell recommendation and
review inventory in `/home/ddnsto/installer-test/ddnsto-install/0.2.4/recommendation-short-20261109`.
Old immutable files remain. PowerShell files were compared before/after and are
unchanged. No Nginx, frontend, production or CDN publication was required.

Activation checked the previous wrapper and recommendation hashes, staged and
verified new files, then replaced the recommendation last. Backup is
`/home/ddnsto/installer-test/.pre-asus-bc7c349c95a6`.
Rollback: check there has been no later deployment; restore its wrapper,
recommended-shell.txt and review.json atomically, retaining immutable payloads.

Public HTTPS readback matches local hashes; `/i` returns HTTP 200, UTF-8 and
no-store. On the actual router, public short-entry `--plan` reported ASUS/rogsoft/
aarch64/4.2.8. Public short-entry ensure with the existing account succeeded:
`/jffs/.ddnsto-installer/tmp.831cb6285816d5bc0fbefa82/events.log`.
Final candidate was also run directly before activation and passed.
