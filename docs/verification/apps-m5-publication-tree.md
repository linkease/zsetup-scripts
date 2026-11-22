# Apps migration M5 publication tree

Date: 2026-11-22 UTC.  No public server was changed.

`scripts/build.py` now writes a deterministic `apps/SHA256SUMS` over every
regular public file except the checksum list itself.  The checksum list is
relative to the `apps/` publication root.

`tests/contracts/publication_tree_test.py` creates 100 applications without
changing the generator, builds 100 standard entries and installer records,
verifies all checksums, proves a second build is byte-identical, copies the
tree onto a target containing a server-owned product and proves that product is
unchanged.  Tampering is detected.  The first aggregate self-check invoked the
relative checksum list from the repository root; rerunning it from the actual
publication root passed, matching production semantics.

