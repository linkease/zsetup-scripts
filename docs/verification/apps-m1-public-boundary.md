# Apps migration M1 public boundary

Date: 2026-11-22 UTC.  No application or public server was changed.

- `apps/` is present as the only future public tree.
- `scripts/check-public-tree.py` accepts public source and ordinary version
  directories while rejecting tests, fixtures, credentials, caches, logs,
  production connection assignments, symlinks and special files.
- `tests/contracts/public_tree_test.py` copies a valid tree and compares every
  file byte, then proves each forbidden class fails through the checker CLI.
- The checker passes against the repository `apps/` tree.

Commands:

```sh
python3 -B tests/contracts/public_tree_test.py
python3 -B scripts/check-public-tree.py apps
git diff --check
```

