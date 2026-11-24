# `apps/` publication layout v2

Status: accepted standard. DDNSTO is the reference implementation. The literal
`apps/` directory is the complete release artifact copied to
`/binary/zsetup-scripts/apps/`.

## Application interface

```text
apps/APP/
  app.json
  install.sh                         # POSIX standard entry, when supported
  install.ps1                       # Windows standard entry, when supported
  versions/
    VERSION/
      install.sh                    # immutable POSIX version installer
      install.ps1                  # immutable Windows version installer
```

An application root contains no other names. Platform support belongs in
`app.json`, not filenames. Linux, macOS, OpenWrt, ASUSWRT and Synology share the
POSIX runtime family. Windows uses PowerShell. Standard entries bootstrap the
latest compatible stable zsetup and call `zsetup install APP`; generated zsetup
configuration references only immutable version installers.

Schema v2 fixes entry names and forbids compatibility aliases. Every application
manifest lives in its public application directory and is its only registration
source. Maintained implementation lives in `sources/APP/`; tests and fixtures
live in `tests/apps/APP/`.

## Website runtime

Domain-specific runtime content is not an application interface:

```text
apps/_sites/run.ddnsto.com/
  install.sh
  install.ps1
  current/
  agent/
```

Operations maps `/i` and `/i.ps1` to the two standard website files and maps
`/ddnsto-install/*` to the same site root. URL spelling does not dictate stored
filenames. Server connection data and routing configuration remain outside this
repository.

## Release rules

- Version installer bytes are immutable while present in a release.
- A behavior or payload change requires a new application version.
- Activation makes the managed public tree match the candidate: files recorded
  by the previous `SHA256SUMS` but absent from the candidate are retired, checked
  against their old digest, snapshotted and deleted. Rollback restores them.
- Product artifacts remain in their owning `/binary/PRODUCT/` namespace.
- Unknown application-root files, aliases, source, tests, credentials and local
  deployment metadata fail candidate validation.

## DDNSTO reference

DDNSTO v0.3.0 proves the complete contract: POSIX covers Linux, OpenWrt and
macOS; PowerShell covers Windows; both configuration families reference
`apps/ddnsto/versions/0.3.0/install.*`. Its former `i`, `i.ps1`,
`ddnsto-install.sh`, `ddnsto-install/`, `0.2.4/` and `0.2.5/` application paths
are intentionally absent. Recommendation website content is generated under
`apps/_sites/run.ddnsto.com/`.

Schema-v1 applications are existing migration work, not examples for new code.
Each must move to v2 in a new application version; no new schema-v1 application
or compatibility alias is allowed.
