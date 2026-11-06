# Included at build time; only ddnsto-install.sh is a public installer.
ddnsto_error() { printf 'DDNSTO: %s\n' "$*" >&2; }

# CLI/platform helpers are composed from managed-cli.sh in both entry programs.

ddnsto_download() { installer_download "$@"; }

# Markers are written only after zsetup has verified and committed an artifact.
ddnsto_verified_download() {
    verified_relative=$1
    verified_output=$2
    verified_sha=$3
    verified_marker="$verified_output.verified"
    installer_package_immutable "$verified_marker" "$verified_sha" || return $?
    ddnsto_download "$verified_relative" "$verified_output" "$verified_sha" || return $?
    verified_size=$(wc -c < "$verified_output" | tr -d '[:space:]')
    printf '%s:%s\n' "$verified_sha" "$verified_size" > "$transaction_dir/verified"
    mv -f "$transaction_dir/verified" "$verified_marker"
}

ddnsto_checksum() {
    "$ZSETUP_BIN" metadata sha256 "$1" "$2" || {
        ddnsto_error "invalid, missing or duplicate SHA256 for $2"; return 11;
    }
}

ddnsto_package_restore() {
    if [ "${deprecated_config:-0}" = 1 ] && [ -f "$transaction_dir/deprecated-config" ]; then
        [ "$("$ZSETUP_BIN" storage "$config_path" get system_protected)" = true ] || return 1
        installer_exec_native "$ZSETUP_BIN" run -- cp -p "$transaction_dir/deprecated-config" "$config_path" || return 1
    fi
}

ddnsto_register() {
    if [ "${ACTION:-install}" = update ]; then
        SERVICE_CONFIG_TOUCHED=0
        ddnsto_managed_rewrite_unit
        return $?
    fi
    # Rebinding requires explicit configure, never a repeated install.
    if [ "$SERVICE_HAD_UNIT" = 1 ]; then
        ddnsto_error 'already installed; use update to preserve identity or configure to change Token'
        return 2
    fi
    installer_exec_native "$ZSETUP_BIN" run -- "$SERVICE_EXEC" -u "$TOKEN" -daemon
}

ddnsto_openwrt() {
    case "$package_manager" in opkg) pkg_ext=ipk ;; apk) pkg_ext=apk ;; *) ddnsto_error 'OpenWrt requires opkg or apk'; return 2 ;; esac
    case "$arch" in
        x86_64|aarch64|mipsel) package_arch=$arch ;;
        armv7|arm) package_arch=arm ;;
        *) ddnsto_error "unsupported OpenWrt architecture: $arch"; return 2 ;;
    esac
    SELECTED_VERSION=$FORCE_VERSION
    if [ -z "$SELECTED_VERSION" ]; then
        mem_mb=${DDNSTO_MEM_MB:-${ZSETUP_MEMORY_TOTAL_MB:-$("$ZSETUP_BIN" context get memory_total_mb)}}
        case "$mem_mb" in ''|*[!0123456789]*) mem_mb=0 ;; esac
        if [ "$mem_mb" -gt 0 ] && [ "$mem_mb" -lt 900 ]; then SELECTED_VERSION=lite; else SELECTED_VERSION=standard; fi
    fi
    status "[2/4] Checking DDNSTO $SELECTED_VERSION version ($package_manager/$arch)..."
    version_num=$(ddnsto_pinned_version "$SELECTED_VERSION") || return $?
    version_folder=$SELECTED_VERSION
    [ "$pkg_ext" != apk ] || version_folder="$version_folder-apk"
    relative_folder="openwrt/$version_folder/$version_num"
    status "      DDNSTO $version_num ($SELECTED_VERSION; Lite below 900 MB)"
    status '[3/4] Downloading and verifying DDNSTO packages...'
    installer_package_cache "$version_num-$version_folder" "$arch" || return $?
    package_cache=$PACKAGE_CACHE
    main_package="ddnsto_$package_arch.$pkg_ext"
    ui_package="luci-app-ddnsto.$pkg_ext"
    language_package="luci-i18n-ddnsto-zh-cn.$pkg_ext"
    for package in "$main_package" "$ui_package" "$language_package"; do
        case "$package" in ddnsto_*) product_path="$relative_folder/$package" ;; *) product_path="openwrt/$package" ;; esac
        digest=$(ddnsto_pinned_sha "$product_path") || return $?
        ddnsto_verified_download "$product_path" "$package_cache/$package" "$digest" || return $?
    done
    status '[4/4] Installing DDNSTO packages...'
    ddnsto_openwrt_apply
}

# Package hooks run while the retained-config wrapper has disabled the service.
# Do not remove existing packages first: opkg upgrade preserves dependency state.
ddnsto_openwrt_apply_packages() {
    if [ "$package_manager" = opkg ]; then
        if [ -f /www/luci-static/resources/luci.js ] && [ ! -f /usr/lib/lua/luci/cbi.lua ]; then
            installer_package_command update update && installer_package_command install install luci-compat || status 'DDNSTO: luci-compat installation failed'
        fi
        ddnsto_has_runtime=0
        if installer_package_command query "$transaction_dir/pm-query" list-installed luci-lua-runtime; then
            while IFS= read -r ddnsto_query_line; do
                case "$ddnsto_query_line" in 'luci-lua-runtime '*) ddnsto_has_runtime=1 ;; esac
            done < "$transaction_dir/pm-query"
        fi
        if [ "$ddnsto_has_runtime" = 0 ]; then
            installer_package_command update update && installer_package_command install install luci-lua-runtime || status 'DDNSTO: luci-lua-runtime installation failed'
        fi
        for package in "$main_package" "$ui_package" "$language_package"; do installer_package_command install install --force-reinstall "$package_cache/$package" || return $?; done
    else
        if [ -f /www/luci-static/resources/luci.js ] && [ ! -f /usr/lib/lua/luci/cbi.lua ]; then
            installer_package_command update update && installer_package_command add add luci-compat || status 'DDNSTO: luci-compat installation failed'
        fi
        if ! installer_package_command query "$transaction_dir/pm-query" info -e luci-lua-runtime >/dev/null 2>&1; then
            installer_package_command update update && installer_package_command add add luci-lua-runtime || status 'DDNSTO: luci-lua-runtime installation failed'
        fi
        for package in "$main_package" "$ui_package" "$language_package"; do installer_package_command add add --allow-untrusted "$package_cache/$package" || return $?; done
    fi

    installer_exec_native "$ZSETUP_BIN" run -- "${DDNSTO_OPENWRT_BIN_PATH:-/usr/sbin/ddnstod}" -v || return $?
}

ddnsto_linux_metadata() {
    case "$arch" in x86_64|aarch64) ;; *) ddnsto_error "unsupported Linux architecture: $arch"; return 2 ;; esac
    [ "$FORCE_VERSION" != lite ] || { ddnsto_error 'Linux only supports standard'; return 2; }
    [ "$VERIFY_STATUS" = 0 ] || { ddnsto_error '--verify-status is for OpenWrt'; return 2; }
    if [ -z "$TOKEN" ] && [ "${ACTION:-install}" != update ]; then
        if [ -t 0 ]; then
            printf 'DDNSTO token: ' >&2
            IFS= read -r TOKEN
        else
            ddnsto_error 'Linux needs --token TOKEN for noninteractive installation'; return 2
        fi
    fi
    [ -n "$TOKEN" ] || [ "${ACTION:-install}" = update ] || { ddnsto_error 'empty token'; return 2; }
    version_num=${DDNSTO_VERSION:-4.2.8}
    case "$version_num" in ''|*[!0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._+-]*) ddnsto_error 'invalid DDNSTO_VERSION'; return 2 ;; esac
    status "[2/4] Checking DDNSTO standard $version_num ($arch)..."
    archive_name="ddnsto-standard-$version_num.tar.gz"
    if [ "$version_num" = 4.2.8 ]; then
        digest=$(ddnsto_pinned_sha "linux-binary/$archive_name") || return $?
        return 0
    fi
    # Explicit historical DDNSTO_VERSION keeps the upstream metadata contract.
    ddnsto_download linux-binary/SHA256SUMS "$transaction_dir/sums" '' 1 || return $?
    digest=$(ddnsto_checksum "$transaction_dir/sums" "$archive_name") || return $?
}

ddnsto_linux() {
    ddnsto_linux_metadata || return $?
    installer_service_cached "$version_num" "$digest" || return $?
    if [ "$SERVICE_CACHED" = 0 ]; then
        archive_path="$transaction_dir/product.tar.gz"
        status '[3/4] Downloading DDNSTO with bounded staging...'
        ddnsto_download "linux-binary/$archive_name" "$archive_path" "$digest" || return $?
        mkdir -p "$transaction_dir/products"
        installer_extract_member "$transaction_dir/products/ddnsto" tar -xOzf "$archive_path" "ddnsto-standard-$version_num/ddnsto.$arch" || return $?
        chmod 0755 "$transaction_dir/products/ddnsto"
        installer_exec_native "$ZSETUP_BIN" run -- "$transaction_dir/products/ddnsto" -v || return $?
        installer_service_stage || return $?
        installer_service_copy ddnsto || return $?
        installer_service_commit_version || return $?
    else
        installer_exec_native "$ZSETUP_BIN" run -- "$SERVICE_EXEC" -v || return $?
    fi
    status '[4/4] Installing and checking the DDNSTO system service...'
    installer_service_activate || return $?
    status 'DDNSTO installation completed'
}

ddnsto_install() {
    ddnsto_parse_args "$@" || return $?
    if [ "$PLAN_ONLY" = 1 ]; then ddnsto_plan; return $?; fi
    : "${ZSETUP_BIN:?zsetup is required}"
    os=${ZSETUP_OS:-$("$ZSETUP_BIN" context get os)}
    package_manager=${ZSETUP_PACKAGE_MANAGER:-$("$ZSETUP_BIN" context get package_manager)}
    arch=${ZSETUP_ARCH:-$("$ZSETUP_BIN" context get arch)}
    ddnsto_detect_platform || return $?
    ddnsto_validate_platform_options || return $?
    [ "$REQUESTED_METHOD" != docker ] || { ddnsto_error 'Docker requires the public entry'; return 2; }
    case "$detected_platform" in linux|openwrt) business_platform=$detected_platform ;; *) ddnsto_error 'native installation unavailable for this device'; return 2 ;; esac
    case "$ACTION" in
        status|start|stop|restart|repair|configure|uninstall) ddnsto_managed_action; return $? ;;
    esac
    : "${ZSETUP_SOURCE_BASES:?source group is required}"
    INSTALLER_REMOTE_APP=ddnsto
    if [ "$business_platform" = linux ]; then
        [ -z "${DDNSTO_BIN_PATH:-}" ] || { ddnsto_error 'DDNSTO_BIN_PATH is retired; use --installer-prefix for the protected installation root'; return 2; }
        [ ! -e "${DDNSTO_DOCKER_STATE_DIR:-/etc/ddnsto-docker}" ] && [ ! -L "${DDNSTO_DOCKER_STATE_DIR:-/etc/ddnsto-docker}" ] || { ddnsto_error 'Docker state conflicts with native installation'; return 2; }
        if [ "$ACTION" = update ]; then ddnsto_managed_owned || return $?; fi
        ip_uid=$("$ZSETUP_BIN" storage / get effective_uid) || return 12
        if [ "$ip_uid" != 0 ]; then installer_privilege_install ddnsto "$@"; return $?; fi
        installer_service_prepare ddnsto || return $?
        if [ "$ACTION" = install ] && { [ -n "$SERVICE_OLD" ] || [ "$SERVICE_HAD_UNIT" = 1 ]; }; then
            ddnsto_error 'already installed; use update to preserve identity or configure to change Token'
            return 2
        fi
        if [ "$ACTION" = update ]; then
            [ -n "$SERVICE_OLD" ] && [ "$SERVICE_HAD_UNIT" = 1 ] && [ "$SERVICE_HAD_CONFIG" = 1 ] || { ddnsto_error 'update requires a complete managed installation'; return 2; }
        fi
        ddnsto_linux || return $?
        installer_transaction_finish
        return $?
    fi
    case "$ACTION" in install|update) ;; *) return 2 ;; esac
    ddnsto_openwrt_preflight || return $?
    installer_package_prepare ddnsto || return $?
    # Recheck installed/config state under the machine lease before downloads.
    ddnsto_openwrt_preflight || return $?
    INSTALLER_PACKAGE_CLEANUP=ddnsto_package_restore
    ddnsto_openwrt || return $?
    PACKAGE_PHASE=complete
    installer_transaction_finish
}
