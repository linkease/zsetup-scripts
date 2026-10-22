# Sourced/embedded by main. Caller validates platform/arguments, checks root and
# holds the shared machine lock. This function returns, never exits its caller.
# Inputs: ACTION, TOKEN, package_manager, binary, config, service_path.
# No downloader, package file synthesis, or implicit install/migration here.
# Returns 2 on preflight/config errors, 13 on service failure, 14 when recovery
# needs the retained backup, 15 on incomplete/unverifiable removal; package
# removal failures retain their exit code. Signal exits: 129/130/143.
# Public entries: ddnsto_openwrt_lifecycle and the retained-config wrapper below.
# No marker schema is assumed: lifecycle requires package metadata. Main must
# not treat retained config as an installed native client.
ddnsto_ow_error() { printf 'DDNSTO OpenWrt: %s\n' "$*" >&2; }

ddnsto_ow_safe_path() (
    case "$1" in /*) ;; *) return 1 ;; esac
    case "$1" in /|*/|*//*|*/../*|*/./*|*/..|*/.|*[!a-zA-Z0-9_./-]*) return 1 ;; esac
    ow_path=$1
    while [ "$ow_path" != / ] && [ -n "$ow_path" ]; do
        [ ! -L "$ow_path" ] || return 1
        ow_path=${ow_path%/*}
    done
)

# Read-only state check used by the OpenWrt existing-install policy. Marker
# binds platform/package manager AND all managed paths; it contains no token.
# Root-owned production config directory is the trust boundary, not a basename.
ddnsto_openwrt_retained_state_valid() (
    binary=${DDNSTO_OPENWRT_BIN_PATH:-/usr/sbin/ddnstod}
    config=${DDNSTO_CONFIG_PATH:-/etc/config/ddnsto}
    service_path=${DDNSTO_SERVICE_PATH:-/etc/init.d/ddnsto}
    ow_marker=${config%/*}/.uninstalled-openwrt-v1
    case "${package_manager:-}" in opkg|apk) ;; *) return 1 ;; esac
    for ow_file in "$binary" "$config" "$service_path" "$ow_marker"; do
        ddnsto_ow_safe_path "$ow_file" || return 1
    done
    [ -f "$config" ] && [ -f "$ow_marker" ] || return 1
    ow_expected=$(printf 'ddnsto-openwrt-retained-v1\n%s\n%s\n%s\n%s\n' "$package_manager" "$binary" "$config" "$service_path")
    ow_actual=$(cat "$ow_marker") || return 1
    [ "$ow_expected" = "$ow_actual" ]
)

# Metadata contracts, not basename guesses. opkg search uses fnmatch, hence
# safe_path excludes glob characters. print_pkg emits NAME - VERSION [- DESC].
# https://github.com/openwrt/opkg-lede/blob/master/libopkg/opkg_cmd.c
# APK quiet --who-owns emits exact dependency names (not name-version strings).
# https://github.com/alpinelinux/apk-tools/blob/v2.14.4/src/app_info.c
# https://github.com/alpinelinux/apk-tools/blob/v3.0.0/src/app_info.c
# Unknown CLI output/firmware variants fail closed; these are not integrity
# checks of installed bytes and do not certify third-party package hooks.
ddnsto_ow_owned() (
    if [ "$package_manager" = opkg ]; then
        ow_owner=$(opkg search "$1" 2>/dev/null) || return 1
        case "$ow_owner" in *'
'*) return 1 ;; esac
        case "$ow_owner" in 'ddnsto - '?*) return 0 ;; *) return 1 ;; esac
    else
        ow_owner=$(apk -q info --who-owns "$1" 2>/dev/null) || return 1
        [ "$ow_owner" = ddnsto ]
    fi
)

ddnsto_ow_packages() (
    if [ "$package_manager" = opkg ]; then
        ow_listing=$(opkg list-installed 2>/dev/null) || return 1
        printf '%s\n' "$ow_listing" | while read -r ow_name ow_dash ow_version ow_rest; do
            [ -n "$ow_name" ] || continue
            [ "$ow_dash" = - ] && [ -n "$ow_version" ] || exit 1
            case "$ow_name" in *[!a-zA-Z0-9+_.-]*) exit 1 ;; esac
            printf '%s\n' "$ow_name"
        done
    else
        ow_listing=$(apk info 2>/dev/null) || return 1
        printf '%s\n' "$ow_listing" | while IFS= read -r ow_name; do
            [ -n "$ow_name" ] || continue
            case "$ow_name" in *[!a-zA-Z0-9+_.-]*) exit 1 ;; esac
            printf '%s\n' "$ow_name"
        done
    fi
)

ddnsto_ow_has_package() {
    printf '%s\n' "$ow_packages" | grep -Fqx "$1"
}

ddnsto_ow_restore() {
    ddnsto_ow_safe_path "$config" &&
        { [ ! -e "$config" ] || [ -f "$config" ]; } || return 1
    cp -p "$ow_work/original" "$ow_work/restore" &&
        mv -f "$ow_work/restore" "$config"
}

ddnsto_ow_finish() {
    ow_rc=$?
    trap - 0 HUP INT TERM
    if [ "$ow_dirty" = 1 ]; then
        if ! ddnsto_ow_restore; then
            ddnsto_ow_error "configuration restore failed; backup retained at $ow_work/original"
            exit 14
        fi
        ddnsto_ow_error 'operation failed; configuration restored; service state requires inspection'
    elif [ "$ow_rc" != 0 ]; then
        ddnsto_ow_error 'operation failed; original configuration preserved'
    fi
    rm -f "$ow_work/original" "$ow_work/restore" "$ow_work/marker" "$ow_work/config/ddnsto" "$ow_work/delta/ddnsto"
    rmdir "$ow_work/config" "$ow_work/delta" "$ow_work" 2>/dev/null
    exit "$ow_rc"
}

# Main-only integration seam for reinstall of previously retained configuration.
# Caller holds the machine lock, has validated retained ownership/platform/root,
# and supplies its existing pinned-package install callback. Callback MUST NOT
# explicitly start services or overwrite this wrapper's private backup. Pinned
# package hooks may call start: all checked Standard/Lite IPK/APK init scripts
# gate procd startup on enabled=1, and shipped defaults have enabled=0. Disable
# UCI before hooks, stop the old service, restore only after all hooks complete.
# New product pins must revalidate this init/default-config contract. Runs in a
# subshell, so exports/variables/traps do not propagate back. Output is suppressed
# because package hooks can print credentials. No implicit downloads here.
# Restore completes before return, including callback failure. On return 0 main
# may invoke ACTION=repair with TOKEN empty to enable/start the restored config.
# Wrapper emits no operation-success record. Main owns the full reinstall result.
ddnsto_openwrt_with_retained_config() (
    set +x
    set +e
    umask 077
    [ "$#" -gt 0 ] || { ddnsto_ow_error 'package-only reinstall callback required'; return 2; }
    ddnsto_ow_safe_path "$config" && [ -f "$config" ] && [ "${config##*/}" = ddnsto ] || {
        ddnsto_ow_error 'safe retained UCI configuration required'; return 2
    }
    ow_pending=$(uci -c "${config%/*}" -q changes ddnsto 2>/dev/null) && [ -z "$ow_pending" ] || {
        ddnsto_ow_error 'pending UCI changes or unreadable configuration'; return 2
    }
    for ow_file in "$binary" "$service_path"; do
        ddnsto_ow_safe_path "$ow_file" || return 2
        if [ -e "$ow_file" ]; then
            [ -f "$ow_file" ] && [ -x "$ow_file" ] && ddnsto_ow_owned "$ow_file" || {
                ddnsto_ow_error 'existing program/service is not package owned'; return 2
            }
        fi
    done
    ow_work=$(mktemp -d "${config%/*}/.ddnsto-lifecycle.XXXXXX") || return 2
    ow_dirty=0
    trap ddnsto_ow_finish 0
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    mkdir "$ow_work/config" "$ow_work/delta" || return 2
    cp -p "$config" "$ow_work/original" || return 2
    cp -p "$config" "$ow_work/config/ddnsto" || return 2
    ow_section=$(uci -c "$ow_work/config" -t "$ow_work/delta" -q get 'ddnsto.@ddnsto[0]' 2>/dev/null)
    [ "$ow_section" = ddnsto ] && ! uci -c "$ow_work/config" -t "$ow_work/delta" -q get 'ddnsto.@ddnsto[1]' >/dev/null 2>&1 || {
        ddnsto_ow_error 'exactly one ddnsto UCI section required before package hooks'; return 2
    }
    uci -c "$ow_work/config" -t "$ow_work/delta" -q set 'ddnsto.@ddnsto[0].enabled=0' >/dev/null 2>&1 &&
        uci -c "$ow_work/config" -t "$ow_work/delta" -q commit ddnsto >/dev/null 2>&1 || return 2
    ow_dirty=1
    mv -f "$ow_work/config/ddnsto" "$config" || return 2
    if [ -f "$service_path" ]; then
        "$service_path" stop >/dev/null 2>&1 && ddnsto_ow_wait_service stopped || {
            ddnsto_ow_error 'could not stop existing client; package changes not attempted'; return 13
        }
    fi
    ow_callback_rc=0
    ( "$@" ) >/dev/null 2>&1 || ow_callback_rc=$?
    if ! ddnsto_ow_restore; then
        ddnsto_ow_error 'reinstall may be partial; configuration restore failed'; return 14
    fi
    ow_dirty=0
    if [ "$ow_callback_rc" != 0 ]; then
        ddnsto_ow_error 'reinstall callback failed; packages may be partial; configuration retained'
    fi
    return "$ow_callback_rc"
)

ddnsto_ow_wait_service() {
    ow_attempt=0
    while :; do
        ow_status=0
        "$service_path" status >/dev/null 2>&1 || ow_status=$?
        case "$1:$ow_status" in running:0|stopped:1|stopped:3) return 0 ;; esac
        case "$ow_status" in 0|1|3) ;; *) return 13 ;; esac
        ow_attempt=$((ow_attempt + 1))
        [ "$ow_attempt" -lt 10 ] || return 13
        sleep 1
    done
}

# Resume only after the original UCI bytes have been restored. Disabled installs
# stay disabled; this does not rewrite Token, enabled, index or identity fields.
ddnsto_openwrt_resume_config() (
    set +x
    set +e
    for ow_file in "$binary" "$config" "$service_path"; do
        ddnsto_ow_safe_path "$ow_file" && [ -f "$ow_file" ] && ddnsto_ow_owned "$ow_file" || {
            ddnsto_ow_error 'package installation incomplete; configuration retained'; return 15
        }
    done
    ow_enabled=$(uci -c "${config%/*}" -q get 'ddnsto.@ddnsto[0].enabled' 2>/dev/null) || ow_enabled=0
    case "$ow_enabled" in
        1|on|true|yes|enabled)
            "$service_path" enable >/dev/null 2>&1 && "$service_path" restart >/dev/null 2>&1 &&
                ddnsto_ow_wait_service running || { ddnsto_ow_error 'packages installed; service restart failed; configuration retained'; return 13; }
            ;;
        *)
            "$service_path" disable >/dev/null 2>&1 && "$service_path" stop >/dev/null 2>&1 &&
                ddnsto_ow_wait_service stopped || { ddnsto_ow_error 'packages installed; service stop failed; configuration retained'; return 13; }
            ;;
    esac
)

ddnsto_ow_uninstall() {
    # Client internal/identity/openwrt_uci.go stores index/router_id/mode/UUID
    # in /etc/config/ddnsto. Native /etc/ddnsto state is never deleted here.
    # Package Makefile declares this conffile. Its postinst runs uci-defaults;
    # OpenWrt lib/functions.sh default_prerm disables/stops package init files.
    # Read-only archive inspection (2026-10-21) matched product-pins.sh:
    # standard/4.2.6 x86_64 IPK a7d868da... and APK 470e4ea4... both invoke
    # default_prerm; Lite 4.2.2 and LuCI/language IPKs do likewise. APK's ADB
    # metadata also declares /etc/config/ddnsto. These hooks do not remove
    # additional identity files. This is not validation of every vendor build.
    # Snapshot BEFORE any service/package hooks, restore AFTER all hooks even
    # if removal fails. No --force, autoremove, purge or recursive file deletion.
    set --
    for ow_package in app-meta-ddnsto luci-i18n-ddnsto-zh-cn luci-app-ddnsto ddnsto; do
        if ddnsto_ow_has_package "$ow_package"; then set -- "$@" "$ow_package"; fi
    done
    ow_dirty=1
    if [ -f "$service_path" ]; then
        "$service_path" disable >/dev/null 2>&1 && "$service_path" stop >/dev/null 2>&1 || {
            ddnsto_ow_error 'service stop/disable failed; packages were not removed'; return 13
        }
    fi
    ow_remove_rc=0
    if [ "$package_manager" = opkg ]; then
        opkg remove "$@" >/dev/null 2>&1 || ow_remove_rc=$?
    else
        apk del "$@" >/dev/null 2>&1 || ow_remove_rc=$?
    fi
    if ! ddnsto_ow_restore; then
        ddnsto_ow_error 'uninstall may be partial; configuration restore failed'; return 14
    fi
    ow_dirty=0
    if [ "$ow_remove_rc" != 0 ]; then
        ddnsto_ow_error 'uninstall failed or partial; configuration retained; inspect package state before retry'
        return "$ow_remove_rc"
    fi
    ow_packages=$(ddnsto_ow_packages) || {
        ddnsto_ow_error 'uninstall may be partial; cannot verify remaining packages'; return 15
    }
    for ow_package do
        if ddnsto_ow_has_package "$ow_package"; then
            ddnsto_ow_error 'uninstall partial; requested package remains installed; configuration retained'; return 15
        fi
    done
    # Publish retained ownership only after verified removal and config restore.
    ddnsto_ow_safe_path "$ow_marker" && { [ ! -e "$ow_marker" ] || [ -f "$ow_marker" ]; } || {
        ddnsto_ow_error 'packages removed; configuration retained; marker destination became unsafe'; return 15
    }
    printf 'ddnsto-openwrt-retained-v1\n%s\n%s\n%s\n%s\n' "$package_manager" "$binary" "$config" "$service_path" > "$ow_work/marker" &&
        mv -f "$ow_work/marker" "$ow_marker" || {
        ddnsto_ow_error 'packages removed and configuration retained, but retained marker write failed'; return 15
    }
    printf 'operation=uninstall config=retained identity=retained cloud_status=unverified\n'
}

ddnsto_openwrt_lifecycle() (
    set +x
    set +e
    umask 077
    export LC_ALL=C
    case "${ACTION:-}" in configure|repair|uninstall) ;; *) ddnsto_ow_error 'unsupported lifecycle action'; return 2 ;; esac
    case "${package_manager:-}" in opkg|apk) ;; *) ddnsto_ow_error 'opkg or apk required'; return 2 ;; esac
    [ "${REQUESTED_METHOD:-auto}" != docker ] || { ddnsto_ow_error 'container migration is not supported'; return 2; }
    if [ "$ACTION" = configure ]; then
        case "${TOKEN:-}" in ''|*[!a-zA-Z0-9_-]*) ddnsto_ow_error 'invalid or missing token'; return 2 ;; esac
    elif [ -n "${TOKEN:-}" ]; then
        ddnsto_ow_error 'credentials are only accepted for configure'; return 2
    fi
    ow_marker=${config%/*}/.uninstalled-openwrt-v1
    if [ -e "$ow_marker" ] || [ -L "$ow_marker" ]; then
        ddnsto_openwrt_retained_state_valid || {
            ddnsto_ow_error 'unrecognized or unsafe retained marker'; return 2
        }
    fi
    for ow_file in "$binary" "$config" "$service_path"; do
        ddnsto_ow_safe_path "$ow_file" || {
            ddnsto_ow_error 'unsafe or symlink installation path'; return 2
        }
        if [ "$ACTION" = uninstall ] && [ "$ow_file" != "$config" ] && [ ! -e "$ow_file" ]; then
            continue
        fi
        [ -f "$ow_file" ] || {
            ddnsto_ow_error 'regular files and non-symlink paths required; use explicit update for missing package files'
            return 2
        }
    done
    [ "${config##*/}" = ddnsto ] || { ddnsto_ow_error 'UCI config filename must be ddnsto'; return 2; }
    if [ "$ACTION" != uninstall ]; then
        [ -x "$binary" ] && [ -x "$service_path" ] || {
            ddnsto_ow_error 'valid OpenWrt config and executable package files required'; return 2
        }
    elif [ -e "$service_path" ] && [ ! -x "$service_path" ]; then
        ddnsto_ow_error 'package init script is not executable'; return 2
    fi
    ow_packages=$(ddnsto_ow_packages) && ddnsto_ow_has_package ddnsto || {
        ddnsto_ow_error 'installed ddnsto package metadata unavailable'; return 2
    }
    for ow_file in "$binary" "$config" "$service_path"; do
        ddnsto_ow_owned "$ow_file" || {
            ddnsto_ow_error 'package ownership not verified; external/native/container migration refused'; return 2
        }
    done
    ow_pending=$(uci -c "${config%/*}" -q changes ddnsto 2>/dev/null) && [ -z "$ow_pending" ] || {
        ddnsto_ow_error 'pending UCI changes or unreadable UCI state; commit or revert them first'; return 2
    }
    ow_work=$(mktemp -d "${config%/*}/.ddnsto-lifecycle.XXXXXX") || return 2
    ow_dirty=0
    trap ddnsto_ow_finish 0
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    mkdir "$ow_work/config" "$ow_work/delta" || return 2
    cp -p "$config" "$ow_work/original" || return 2
    if [ "$ACTION" = uninstall ]; then
        ddnsto_ow_uninstall
        return $?
    fi
    cp -p "$config" "$ow_work/config/ddnsto" || return 2
    ow_section=$(uci -c "$ow_work/config" -t "$ow_work/delta" -q get 'ddnsto.@ddnsto[0]' 2>/dev/null)
    [ "$ow_section" = ddnsto ] && ! uci -c "$ow_work/config" -t "$ow_work/delta" -q get 'ddnsto.@ddnsto[1]' >/dev/null 2>&1 || {
        ddnsto_ow_error 'exactly one ddnsto UCI section required'; return 2
    }
    if [ "$ACTION" = configure ]; then
        uci -c "$ow_work/config" -t "$ow_work/delta" -q set "ddnsto.@ddnsto[0].token=$TOKEN" >/dev/null 2>&1 || return 2
    else
        ow_token=$(uci -c "$ow_work/config" -t "$ow_work/delta" -q get 'ddnsto.@ddnsto[0].token' 2>/dev/null)
        [ -n "$ow_token" ] || { ddnsto_ow_error 'existing token required; use configure first'; return 2; }
        unset ow_token
    fi
    uci -c "$ow_work/config" -t "$ow_work/delta" -q set 'ddnsto.@ddnsto[0].enabled=1' >/dev/null 2>&1 || return 2
    uci -c "$ow_work/config" -t "$ow_work/delta" -q commit ddnsto >/dev/null 2>&1 || return 2
    ow_dirty=1
    mv -f "$ow_work/config/ddnsto" "$config" || return 2
    "$service_path" enable >/dev/null 2>&1 || return 13
    "$service_path" restart >/dev/null 2>&1 || return 13
    ow_attempt=0
    while ! "$service_path" status >/dev/null 2>&1; do
        ow_attempt=$((ow_attempt + 1))
        [ "$ow_attempt" -lt 10 ] || {
            ddnsto_ow_error 'service failed to reach running state'; return 13
        }
        sleep 1
    done
    ow_dirty=0
    printf 'operation=%s local_service=running cloud_status=unverified\n' "$ACTION"
)
