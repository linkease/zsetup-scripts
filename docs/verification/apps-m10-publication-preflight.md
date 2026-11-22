# Apps migration M10 publication preflight

Date: 2026-11-22 UTC. No public server was changed.

`tests/contracts/publication_preflight_test.py` published the complete real
`apps/` tree to an isolated server directory. Stage left mutable files
unchanged, activation and byte verification passed, rollback restored the old
configuration and DDNSTO entry, immutable payloads remained available, and an
unrelated server-owned product was preserved. No tests directory appeared in
the published tree.

Candidate identities after the final build:

- Linux config: `apps-fccce07c051a`, 125 records, stable zsetup 0.6.4,
  SHA256 `ab2597b792c037f643208d6a74780b81212d0f013b2cb09201d743cf41e166d3`.
- Windows config: `apps-ee17d0f7b511`, 5 records, stable zsetup 0.6.5,
  SHA256 `d01598737c4e07cdf0a6f78550b1a9d8321dc71a0ac03a430f468e3a68467012`.
- Public tree checksum manifest SHA256:
  `67112af8c8ea5a7cbc03a0affe6f93ffd9b1cba94bffc81f922cfa91a2c76e32`.

Read-only HTTPS checks found all four existing Linux public sources on stable
0.6.4 with the same current `config.json` SHA256
`2a5813f9b367fb437453f3bfa0fb77b989918e555f369104bba7a87e6e1f4ce0`.
`dl.istoreos.com` redirects to `fw.koolcenter.com`; redirects were restricted
to HTTPS. This confirms the candidate differs and therefore requires an
explicit production rollout decision. No upload, activation or remote mutation
was attempted during the local preflight.

## Incorrect production activation and rollback

Later on 2026-11-22, the committed `apps/` tree from
`6e9899ab1f64c77e518919fa912ecd7a64f9f79e` was activated at the confirmed
`/binary/` Web root with release id
`67112af8c8ea5a7cbc03a0affe6f93ffd9b1cba94bffc81f922cfa91a2c76e32`.
The server verified all 138 manifest entries. Four public download domains
then passed 552 complete-file digest checks; 24 final critical checks covered
the public manifest, both generated configs and the DDNSTO entries/payload.

This target interpretation was incorrect: zsetup-scripts must be released as
one business namespace, with DDNSTO as an application inside it. The complete
mutable transaction was therefore rolled back after checking that no later
release had changed its files. The previous `/binary/zsetup/config.json` was
restored. The newly uploaded DDNSTO entry, manifest, source tree and immutable
`0.2.4` installer were removed explicitly; all four public domains returned
404 for those paths and the previous config digest. The private release bundle
and rolled-back snapshot remain as audit evidence.

## Corrected complete-business development candidate

After rollback, the user selected the literal directory mapping
`apps/` → `/binary/zsetup-scripts/apps/` and explicitly deferred publication.
The corrected complete-business source commit is
`527b3ceae26f79b9e3f97a2bc633e8a9902dbdc9`.
The generator now prefixes all 130 installer records with
`zsetup-scripts/apps/`. Standard Shell and PowerShell entries download their
platform configuration from the nested business namespace, while native
zsetup and business product resources continue to use the existing `/binary`
source group.

Corrected candidate identities:

- Linux: `apps-21d445da18b1`, 125 records, SHA256
  `dadc68f4ad46157a9a12518357052207caeb41ec424fc4510b67a0cebad23fb8`.
- Windows: `apps-c779c40c7a27`, 5 records, SHA256
  `21dcbaa47c0a0af14c75164983d83c17d366a0bef44d6f08873dedc2858fd8c1`.
- Complete `apps/SHA256SUMS` identity after documenting the canonical release
  coordinator inside the public tree:
  `f0bdc493992caa7d2fc61a9c4ec7ceb5996f0adec2534a01e3490cb0e8943e0d`.

All contract and application migration suites passed against the corrected
layout. The standard `scripts/check.sh --native-bin ...` aggregate also exited
0, including DDNSTO and LinkEase isolated service/package transactions. No
production upload or activation is authorized by this result.

The repository now owns the production coordinator `scripts/publish-apps.py`.
It accepts only a physical `binary` root and always derives the public target
as `binary/zsetup-scripts/apps`; the earlier incorrect `/binary/` mapping is
not expressible through its interface. The coordinator's local release,
approval, remote transaction and HTTPS byte-verification contracts are covered
by `tests/contracts/publish_coordinator_test.py`. This remains development
evidence only; no production command was run.
