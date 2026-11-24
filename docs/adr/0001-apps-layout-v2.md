# Use a minimal cross-platform application interface

DDNSTO is the reference implementation for apps layout v2: every application exposes only `app.json`, `install.sh`, `install.ps1` when applicable, and immutable `versions/VERSION/install.*` implementations. Website routes live under `_sites`, development sources and tests live outside `apps`, and compatibility aliases are deliberately deleted rather than preserved. This trades old URL compatibility for a small uniform interface and makes a literal copy of `apps/` the complete release artifact.
