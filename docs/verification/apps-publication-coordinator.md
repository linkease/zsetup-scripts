# Complete apps publication coordinator verification

Date: 2026-11-22 UTC. Status: published and independently verified.

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
- The development acceptance above preceded production activation. No Git push
  was performed.

## Production publication

After explicit user authorization, the canonical coordinator was run with the
exact release ID, SSH server `root@192.168.3.1` and binary root
`/mnt/sata3-1/istore-data/public_html/binary`. Read-only preflight confirmed
that the binary root was a real directory and both the correct public apps path
and private release path were absent.

The coordinator then completed all gates in order:

1. uploaded the immutable release to
   `/mnt/sata3-1/istore-data/.zsetup-scripts-releases/RELEASE_ID`;
2. staged versioned files without changing mutable entries;
3. passed 48 immutable-file HTTPS byte checks across four configured sources;
4. activated the complete mutable tree and verified all server bytes;
5. passed 556 final HTTPS byte checks (139 public files × four sources).

The transaction phase is `activated`. Its rollback snapshot is
`/mnt/sata3-1/istore-data/public_html/binary/zsetup-scripts/apps/zsetup/.apps-rollback-RELEASE_ID`.
An independent post-publication `verify` repeated all 556 public checks and
passed.

Final server identities:

- `apps/SHA256SUMS`: `f0bdc493992caa7d2fc61a9c4ec7ceb5996f0adec2534a01e3490cb0e8943e0d`;
- nested Linux config: `dadc68f4ad46157a9a12518357052207caeb41ec424fc4510b67a0cebad23fb8`;
- nested Windows config: `21dcbaa47c0a0af14c75164983d83c17d366a0bef44d6f08873dedc2858fd8c1`.

The pre-existing `/binary/zsetup/config.json` remained
`2a5813f9b367fb437453f3bfa0fb77b989918e555f369104bba7a87e6e1f4ce0`.
The mistakenly targeted `/binary/ddnsto/install.sh` and
`/binary/ddnsto/0.2.4/installer.sh` remained absent. This proves the correct
business namespace was activated without repeating the earlier root-level
publication mistake.
