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

## Production activation

Later on 2026-11-22, the committed `apps/` tree from
`6e9899ab1f64c77e518919fa912ecd7a64f9f79e` was activated at the confirmed
`/binary/` Web root with release id
`67112af8c8ea5a7cbc03a0affe6f93ffd9b1cba94bffc81f922cfa91a2c76e32`.
The server verified all 138 manifest entries. Four public download domains
then passed 552 complete-file digest checks; 24 final critical checks covered
the public manifest, both generated configs and the DDNSTO entries/payload.

The transaction retains its private release bundle and activated rollback
snapshot. Public files were normalized to the publisher owner and had
group/other write bits removed. No real DDNSTO device was mutated, so product
installation/service canary evidence remains outside this M10 publication
acceptance result.
