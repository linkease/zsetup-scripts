# Public applications

This directory is the public release tree.  The complete directory is copied
to the download site's `/binary/zsetup-scripts/apps/` namespace. Application
tests, fixtures, build tools, credentials and production connection data do
not belong here.

The layout and publication contract are defined in
`docs/apps-layout-v1.md`. Production releases use the repository's
`scripts/publish-apps.py` coordinator; do not copy this tree to the `/binary/`
root or invoke the bundled low-level transaction with a hand-written target.

