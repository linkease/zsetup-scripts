# Apps migration M6 publication transaction

Date: 2026-11-22 UTC. No public server was changed.

`scripts/publish.sh` accepts only an `apps/` source and an explicit public apps
root, normally `BINARY_ROOT/zsetup-scripts/apps`. It verifies the public-tree policy and `SHA256SUMS`, stages
immutable version payloads without replacing conflicting bytes, snapshots only
mutable files, then activates entries and configuration in a fixed order.

`tests/contracts/publish_transaction_test.py` passed stage, activate, verify,
rollback, injected activation failure, immutable conflict, concurrent lock and
later-publication protection. Server-owned files outside the apps manifest
survived every operation. The complete-tree preflight additionally proves that
existing `/binary/zsetup` and `/binary/ddnsto` files are never touched.
