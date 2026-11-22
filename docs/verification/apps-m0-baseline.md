# Apps migration M0 baseline

Date: 2026-11-22 UTC.  This milestone was read-only with respect to public
servers and did not change application behavior.

## Repository baseline

- Local HEAD: `1f26f2c173311b585afd51815efa62c9dc60c38a`.
- Tracked `origin/main`: `111d29166eef472647837a7e6192ea9a23c9a1d2`.
- The worktree was clean at inspection time and the local branch was four
  commits ahead of its tracked remote.
- The union of the POSIX and Windows catalogs contains ten application ids:
  `ddnsto`, `fastnet`, `fastpve`, `jq`, `kai-skills`, `ks-cli`, `kspeeder`,
  `linkease`, `linkspace`, and `scoop`.
- Their complete ownership, source, immutable path and migration class is
  recorded in `docs/apps-migration-inventory.json`.

## Public baseline

The four configured public bases returned the same `zsetup/config.json`:

| Base | Bytes | SHA256 |
| --- | ---: | --- |
| `dl.istoreos.com` | 22345 | `2a5813f9b367fb437453f3bfa0fb77b989918e555f369104bba7a87e6e1f4ce0` |
| `fw.d4ctech.com` | 22345 | `2a5813f9b367fb437453f3bfa0fb77b989918e555f369104bba7a87e6e1f4ce0` |
| `fw20.koolcenter.com` | 22345 | `2a5813f9b367fb437453f3bfa0fb77b989918e555f369104bba7a87e6e1f4ce0` |
| `fw.koolcenter.com` | 22345 | `2a5813f9b367fb437453f3bfa0fb77b989918e555f369104bba7a87e6e1f4ce0` |

The live stable is `0.6.4`, config version is
`kai-skills-1.2.6-core-0.6.4-b15c854d87ea`, and 56 installer records cover
FastNet, Kai Skills, ks-cli, KSpeeder and Linkspace.  DDNSTO, LinkEase,
FastPVE, jq and Scoop remain non-indexed in that Linux public configuration.

## M0 acceptance

- Local and live application sets were reconciled.
- Every catalog application has a migration class and source owner.
- Existing public records are distinguished from local candidates.
- The accepted layout, public boundary, entry/payload distinction and rollback
  contract are written in `docs/apps-layout-v1.md`.
- No publication, device mutation or remote write occurred.

