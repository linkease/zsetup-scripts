# Apps migration M9 complete application set

Date: 2026-11-22 UTC. No public server was changed.

DDNSTO, LinkEase, jq, Kai Skills and Scoop complete the ten-application tree.
The generated Linux configuration has 125 records and the Windows
configuration has 5 records. Versioned payloads are byte-identical to their
canonical installers; tests and fixtures remain outside `apps/`.

All old DDNSTO fixtures were aligned with client 4.2.8, the explicit/current
Token rules and the fixed Linux/OpenWrt zsetup 0.5.0 identity. The fixed native
used for acceptance had SHA256
`9563b8442a75957792bb82a2d98a736142fc52be57dd2dc42005490096897617`
and was executed only from a private, non-writable ancestor path.

The remediation also restored the missing Linux lifecycle marker contract:
root ownership, non-writable mode, one hard link, exact schema/path binding and
atomic retained-marker publication. DDNSTO's 18-group POSIX cross-platform
aggregate, isolated service/package transactions, LinkEase shared regressions
and `scripts/check.sh --native-bin ...` all passed. PowerShell runtime behavior
was explicitly skipped because `pwsh` is unavailable; static PowerShell
contracts passed.
