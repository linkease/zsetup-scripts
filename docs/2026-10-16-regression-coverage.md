# Storage regression migration

The historical ddnsto_test.py and linkease_test.py flat-path implementations
remain in git before eb2b001. Their maintained entry names now select app-scoped
service_storage_test.py and package_storage_test.py. Each suite runs in its own
root/mount/PID namespace, uses real native HTTPS/fs/process ownership and fake
business/PM commands. No host service, native package or global business path is
mutated. tests/systemd_native_test.py separately uses the actual manager inside
a disposable server container; tests/sudo_privilege_test.py uses real two UIDs.

| Previous behavior assertions | Current test/evidence |
| --- | --- |
| Direct bootstrap / native install, no self-download | service fixture, launchers, core install_execution |
| Token, special/Chinese paths and argv, missing/bad options | service fixture, sudo fixture, package compatibility alias |
| DDNSTO Lite <900, 900/unknown Standard, force-version and verify | package fixture; unsupported Linux flags rejected |
| DDNSTO four architectures × opkg/apk, LinkEase three × opkg, unsupported APK/MIPS | package fixture mappings; core selector regression |
| LinkEase multi-file archive/library layout and malicious ZIP | service fixture, native bounded extraction tests |
| Cached input/network avoidance | package input SHA cache, service protected installed receipts; metadata still refreshes |
| Pre-version/digest failure before mutation | service version/ZIP refusals, package immutable digest11 before PM |
| Stop failure, registration/start/health false success | service fixture; original exit preserved, current/config restored |
| All old files restored, failed rollback retains backup | immutable version transaction/current restoration; deliberate manager-start failure retains old-unit/leases; fixture operator recovery |
| First install failure | registration failure without old version covered by shared transaction/manager tests; no unknown flat directory overwritten |
| OpenWrt package failure23/no fallback | package fixture with bounded package-result receipt |
| Background result/log | native background install in service fixture, core process tests |
| Waiting download/process TERM and cleanup | transaction/bounds, service registration descendant, package-query descendant, sudo EOF/root rollback |
| Unknown native paths/conflicting installation | service foreign-prefix and definition checks; package ownership probes |
| Primary/fallback policy | core real-HTTPS faults regression18; bootstrap original transport tests |

Flat /usr/local/bin and /usr/sbin raw-overwrite assertions are intentionally
replaced by approved root-protected /opt layout and explicit conflict refusal.
Original SysV behavior is frozen legacy under approved scope A; it is not claimed
as a new systemd adapter success. Native package files retain PM ownership.
The ordinary-user sudo bridge covers Linux systemd raw services; OpenWrt requires
explicit root invocation. Real OpenWrt maintainer scripts/procd and real remote
business service connectivity are deployment canaries, not stub successes.

Each new shared suite is wired into scripts/check.sh. Actual systemd and real
sudo require the separately recorded isolated server environment, and are not
silently skipped or claimed by the local one-UID namespace test.
