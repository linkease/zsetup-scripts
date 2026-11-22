# Apps migration M3 standard POSIX entry

Date: 2026-11-22 UTC.  No application or public server was changed.

`templates/install.sh.in` and `scripts/build.py` generate one executable
`install.sh` per POSIX application and byte-identical Shell compatibility
aliases.  The shared, already reviewed zsetup bootstrap is embedded; the final
process is exactly `zsetup install APP --foreground -- "$@"`.

`tests/contracts/standard_entry_test.py` proves deterministic generation,
drift detection, alias identity, existing-zsetup bootstrap, literal argument
preservation and exact exit-status propagation through the process boundary.

