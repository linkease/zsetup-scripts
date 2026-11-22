# Apps migration M2 application manifest

Date: 2026-11-22 UTC.  No application or public server was changed.

`scripts/build.py --validate-only` now discovers application directories and
enforces the accepted v1 `app.json` contract: directory identity, safe ids,
plain versioned payload directories, minimum zsetup, supported entrypoint
types, safe compatibility aliases, complete target dimensions and expanded
selector uniqueness.  Windows selectors require PowerShell and other selectors
require POSIX shell payloads.

`tests/contracts/app_manifest_test.py` exercises the valid public CLI and nine
independent rejection classes.  The first self-check exposed a fixture whose
Shell alias correctly failed before its intended missing-PowerShell assertion;
the fixture was corrected and the complete milestone then passed.

