# Apps migration M7 FastNet pilot

Date: 2026-11-22 UTC.  No public server was changed.

FastNet is the first complete application under `apps/`: its public source is
present, the 0.1.9 immutable payload is byte-identical to the previously
generated standalone installer, and its standard `install.sh` plus historical
`fastnet-install.sh` alias are generated from the common template.  The local
candidate config contains exactly three measured FastNet records.

All M1-M7 contracts passed.  The first aggregate check exposed an older M3
fixture that lacked the M4 base configuration; the complete fixture was fixed.
A published zsetup 0.6.4 binary was downloaded and verified by its fixed SHA256,
then the existing FastNet HTTPS/bootstrap and native zsetup integration suites
passed, including cache reuse, literal arguments and explicit HTTP consent.

