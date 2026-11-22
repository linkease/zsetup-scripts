# Complete apps publication coordinator verification

Date: 2026-11-22 UTC. Status: development complete; not published.

## Candidate

- Source commit: `38e62b8f418cce2a079ae7dad1b4beec3d730844`.
- Applications: 10 (`ddnsto`, `fastnet`, `fastpve`, `jq`, `kai-skills`,
  `ks-cli`, `kspeeder`, `linkease`, `linkspace`, `scoop`).
- Linux installer records: 125; config version `apps-21d445da18b1`.
- Windows installer records: 5; config version `apps-c779c40c7a27`.
- Public files including `SHA256SUMS`: 139.
- Release ID: `f0bdc493992caa7d2fc61a9c4ec7ceb5996f0adec2534a01e3490cb0e8943e0d`.

`scripts/publish-apps.py prepare` created the complete local review bundle at
`dist/apps-releases/RELEASE_ID/`. Its `release.json`, bundled low-level
transaction and complete literal `apps/` copy passed their independent
checksums. The metadata remains `published=false`.

## Fixed deployment plan

The read-only `plan` action was evaluated with the known deployment metadata.
It did not open SSH or mutate a server and produced these derived paths:

```text
binary root:    /mnt/sata3-1/istore-data/public_html/binary
public apps:    /mnt/sata3-1/istore-data/public_html/binary/zsetup-scripts/apps
private release:/mnt/sata3-1/istore-data/.zsetup-scripts-releases/RELEASE_ID
```

There is no coordinator option for an arbitrary public destination. An input
must be a safe absolute path ending in `/binary`, and the public suffix is
always `zsetup-scripts/apps`. Each remote mutation additionally requires
`--approve RELEASE_ID`; SSH is batch-only with strict host-key checking.

## Acceptance

- All nine apps contract tests passed, including the new coordinator contract,
  100-app scale generation and complete stage/activate/verify/rollback sandbox.
- FastNet, ordinary and complex migrations passed for all 10 apps and all 130
  Linux/Windows records.
- `scripts/build-entrypoints.py --check`, `scripts/build.py --check`, public-tree
  policy, Python compilation, Shell syntax and `git diff --check` passed.
- The complete `scripts/check.sh --native-bin ...` standard exited successfully.
  It covered DDNSTO and LinkEase maintained package/service regressions plus the
  remaining business installers and shared transactions.
- No `stage`, `publish`, `activate` or `rollback` production action was run. No
  file was uploaded, no public URL was changed and no Git push was performed.
