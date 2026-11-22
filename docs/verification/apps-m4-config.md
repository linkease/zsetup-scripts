# Apps migration M4 generated zsetup configuration

Date: 2026-11-22 UTC.  No application or public server was changed.

`apps/zsetup/base.json` records the externally owned native zsetup 0.6.4
identity and canonical source group.  `scripts/build.py` expands application
selectors and generates deterministic `apps/zsetup/config.json`; installer
records point only to versioned payloads and contain measured SHA256 and size.
Manifest `min_zsetup` is a capability floor, while native schema `min_version`
is bound to the exact stable runtime identity as required by current zsetup.

Contract tests cover deterministic ordering, config drift, payload identity,
selector expansion and incompatible runtime floors.  A freshly downloaded
published Linux x86_64 zsetup 0.6.4 was checked against its fixed SHA256
`9e87c8bf447cc14eb1a8d2ebfc5cfc2377bed4fcb99539c9175b644f5f10a237`
and successfully parsed the generated configuration with `install --list`.

