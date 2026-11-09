# Kai Skills Windows 1.2.5 publication

Date: 2026-11-09 UTC.

This release adds the native Windows path without Git, Node.js, Bash, jq, tar,
`ks-cli` or `kspeeder`. Windows 10/11 x64 uses the i686 zsetup binary under
WOW64 and Windows PowerShell 5.1. The default destination remains
`$HOME\.agents\skills`.

## Published identities

| Item | Version / SHA-256 |
|---|---|
| zsetup Win32 | `0.6.5` / `07d99ebcaae8739e95d92a510891dd729f7f9da52f898bb19a4360fe6f01ac06` |
| kai-skills release manifest | `1.2.5` / `cc62e2e00e75bf76ab6c26c4c49a56e0ee791fa8ebe9186445266148bdd999b7` |
| pinned Windows Business Installer | `4b15fd3e5ff90a361bffef55f77fa1d4fb9f39aeb44bca482bb174f73eeaef6c` |
| version-free `setup.ps1` | `fa67fc063360e2a1ea1d14ae30eb093335106136499118b1f969351568dad0ef` |
| Windows Product Configuration | `b24922fe033e5367f879a97e10c414d3d21ecbcdb39d0a821ec20daf2b584f30` |
| Linux Product Configuration | `b15c854d87ea04378ab1df85bdc9b204233c33831b4d8c5f864bcb973d62c8b7` |

The four source roots are `dl.istoreos.com`, `fw.d4ctech.com`,
`fw20.koolcenter.com`, and final fallback `fw.koolcenter.com`, all below
`/binary`. Old immutable zsetup 0.4.0/0.6.4 and kai-skills 1.2.4 were retained.

## Native and lifecycle evidence

- Source commits: kai-skills `1ac5307`; zsetup-scripts `829972a`; zsetup parent
  `6500b3b`; runtime-rust `1643c03`.
- Full offline Linux `cargo test --locked` passed before the final build.
- The final clean-tree binary was byte-identical to the native-tested build.
- Windows host `admin@192.168.9.199`: Windows `10.0.26200`, PowerShell
  `5.1.26100.9711`; native report SHA-256
  `a5b79b540c1563808cc58ad41976edbccdd3cbba846cf105d43b79596c8ec292`.
- Native report: 21/21 cases passed (context plus 20 test executables). The
  archive gate additionally rejected a junction/reparse output parent with
  exit 12.
- The pinned Business Installer completed single-skill and exact nine-skill
  Windows install/upgrade/uninstall cycles through the four HTTPS sources.
- A clean bootstrap directory obtained zsetup 0.6.5 and installed both
  `kai-software` and the nine-skill Windows system collection.
- Linux public setup remained on zsetup 0.6.4 and installed the 1.2.5
  `kai-software` package successfully.

## Public commands

```powershell
& ([scriptblock]::Create((irm 'https://fw.koolcenter.com/binary/kai/kai-skills/setup.ps1'))) kai-software
& ([scriptblock]::Create((irm 'https://fw.koolcenter.com/binary/kai/kai-skills/setup.ps1'))) all
```

Advanced recovery arguments may follow the first argument, for example
`--target-skills C:\isolated\skills`.

## Activation and rollback

Immutable files were installed first under `zsetup/0.6.5`,
`kai/kai-skills/releases/1.2.5`, `installers/1.2.5`, and
`entrypoints/1.2.5`. Complete Windows and Linux configurations were activated
before the version-free channel files. The source-server rollback snapshot is:

```text
/mnt/sata3-1/istore-data/kai-skills-rollbacks/20261109-windows-1.2.5
```

Rollback restores the complete saved configurations and mutable channel files;
immutable version directories remain retained.

Final four-site `setup.ps1`, publication metadata, Product Configuration and
stable-pointer readback matched the hashes above. The root channel cache became
consistent after approximately 37 minutes. Fresh public-URL canaries installed
one skill and the exact nine-skill Windows collection and reported
`zsetup 0.6.5`.
