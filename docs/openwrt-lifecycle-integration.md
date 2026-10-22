# OpenWrt lifecycle integration

This is local development evidence, not device acceptance or a published release.
No real package installation or host service operation was used for testing.

## Entrypoints and ownership

`main.sh` initializes `binary`, `config`, `service_path`, `package_manager` and
checks root before calling `ddnsto_openwrt_lifecycle` under the shared operation
lock. Supported actions are `configure`, `repair`, and `uninstall`. Interactive
configure with no Token uses the existing visible terminal prompt; unattended
configure requires `--token` or `--token-file`. Configure does not reuse the old
Token as an implicit answer.

Configure accepts a nonempty Token consisting of ASCII letters, digits, `_` and
`-` (including UUID Tokens). Spaces, tabs, CR/LF and other characters are rejected
with a generic error, without echoing the supplied value. Tests assert this
non-disclosure. Interactive terminal input is deliberately visible as requested;
the installer does not additionally log it.

Lifecycle checks exact package ownership using `opkg search PATH` or
`apk -q info --who-owns PATH`, plus installed package metadata. Paths and their
ancestors must not be symlinks. It does not infer ownership from a basename or
accept an external/native/container migration. Unsupported metadata formats fail
closed. Metadata ownership does not establish integrity of locally modified files.

The tested output contracts are in upstream
[opkg_cmd.c](https://github.com/openwrt/opkg-lede/blob/master/libopkg/opkg_cmd.c)
(`print_pkg`, `opkg_search_cmd`) and APK
[v2.14.4](https://github.com/alpinelinux/apk-tools/blob/v2.14.4/src/app_info.c) /
[v3.0.0](https://github.com/alpinelinux/apk-tools/blob/v3.0.0/src/app_info.c)
(`info_who_owns`). The tests use fixtures for these outputs.

## Configuration and identity

The client source `clients/ddns-client/internal/identity/openwrt_uci.go` stores
`router_id`, `identity_mode`, and `device_uuid` in `/etc/config/ddnsto`; the init
script also uses `index`. Configure changes only Token and enabled through UCI.
Repair uses the existing executable init and preserves Token/identity. Missing
package files require explicit update; repair does not synthesize package files.
Changing Token can change the client-derived v2 router ID on the next run; retaining
stored UUID/index is not a promise of the same cloud identity across accounts.

Configuration is backed up in a private directory beside the config and restored
by rename. Tool output that might contain Token is suppressed. Failure to restore
returns 14 and retains the backup path. Pending UCI changes and multiple ddnsto
sections are rejected. The installer lock does not coordinate manual UCI/package
operations, so concurrent external edits are outside this transaction boundary.

Uninstall snapshots before service/package hooks, requests removal only of
installed `app-meta-ddnsto`, `luci-i18n-ddnsto-zh-cn`, `luci-app-ddnsto`, and
`ddnsto`, restores configuration after hooks, and verifies removal. It never
recursively deletes state directories. Native `/etc/ddnsto` state is untouched.
Only verified success writes `.uninstalled-openwrt-v1` beside the config. Its
contents bind the package manager, binary, config, and init paths without Token.
The production root-owned configuration directory is the marker trust boundary.

## Why update remains supported

The initial concern was real, but did not justify disabling update:
OpenWrt's `default_postinst` calls init enable/start while packages are being
installed. Restoring configuration only after installation would be too late
if the client had already started with a changed index or missing identity.

Read-only inspection on 2026-10-21 checked these actual pinned x86_64 artifacts
under `https://fw.koolcenter.com/binary/ddnsto/openwrt/` against `product-pins.sh`:

| Artifact | SHA256 |
| --- | --- |
| `standard/4.2.6/ddnsto_x86_64.ipk` | `a7d868da03dea6e6e9b4cb02bc6f2ccfa31d2eeba62f0ac088338bc83e31e9eb` |
| `lite/4.2.2/ddnsto_x86_64.ipk` | `1434d56a8122d4fdb470a744a512373741307631fabde0a31e37733984461ca4` |
| `standard-apk/4.2.6/ddnsto_x86_64.apk` | `470e4ea428f897cc8e38f7528b9387b0dd7373d5c727ef334e1d79c8dead7da2` |
| `lite-apk/4.2.2/ddnsto_x86_64.apk` | `291a24cb1e8e821f127ad08249bcfbc1517501189b895fbad261c950e2aa0abf` |

All four ship `enabled '0'` in `etc/config/ddnsto`, and their
`etc/init.d/ddnsto` returns before `procd_open_instance` unless enabled is 1 and
Token is nonempty. Matching source paths in this workspace are:

- `clients/ddnsto-openwrt-package/ddnsto/files/ddnsto.config`
- `clients/ddnsto-openwrt-package/ddnsto/files/ddnsto.init`: `start_service`
- `clients/ddnsto-openwrt-package/ddnsto/Makefile`: `postinst`, `conffiles`, `install`
- OpenWrt [lib/functions.sh](https://github.com/openwrt/openwrt/blob/master/package/base-files/files/lib/functions.sh): `default_postinst`, `default_prerm`

The actual main-package removal hooks delegate to `default_prerm`. The inspected
LuCI/language IPKs use that same removal wrapper and do not remove extra client
identity files. APK archives were inspected as data, without executing apk or
their scripts. Other architectures share the package recipe; their path/digest
selection has fixture coverage, not individual archive or real-device acceptance.
Changing package pins or supporting vendor-modified init/hooks requires reviewing
this enabled/default-config assumption again.

The implementation therefore preserves update and retained reinstall:

1. Verify/download all pinned artifacts before stopping services.
2. Snapshot the complete existing UCI config, stage `enabled=0`, commit it, and
   stop/verify the old service if present.
3. Execute the existing package-manager dependency/removal/install path. Hooks
   can call start, but both the retained config and shipped defaults are disabled.
4. Restore the original config bytes, including Token, enabled, index, and identity.
5. Resume according to the original enabled value. Originally disabled installs
   remain stopped. Remove a retained marker only after successful completion.

`ddnsto_openwrt_with_retained_config CALLBACK [ARGS...]` owns steps 2–4. Callbacks
must explicitly propagate errors and must not explicitly start services; the
verified package hooks are permitted to attempt their guarded startup.
`ddnsto_openwrt_resume_config` owns step 5's service operation.
`ddnsto_openwrt_retained_state_valid` is the read-only marker check used by the
OpenWrt branch of `ddnsto_existing_policy`.

Package rollback remains non-atomic. A failed dependency/removal/install can
leave packages partially changed; configuration is restored, the error propagates,
and no install success is reported. Restart failure also reports failure without
claiming package rollback. An unsafe recovery destination retains the backup.
Automatic conversion of a legacy `config global` format is refused rather than
discarding its index/identity; it needs a separate explicit migration.

## Validation and integration boundary

`python3 -B ddnsto/tests/openwrt_lifecycle_test.py` covers local actions, root/path
initialization, visible configure input, exact ownership, config rollback, signals,
partial uninstall, unsafe restore/marker targets, early postinst start, enabled
and disabled updates, retained reinstall, and failed package installation.

`python3 -B ddnsto/tests/pinned_products_test.py` covers all 16 package-manager /
variant / architecture selections with isolated root/package/init fixtures and
retains the same-size tampered-cache regression.

The generator embeds `openwrt-lifecycle.sh` before main. The main agent owns that
generator change and final entrypoint generation. This slice does not generate
`install.sh`, publish artifacts, commit, or push. Bootstrap real-HTTPS fixture
updates remain with the bootstrap agent.
