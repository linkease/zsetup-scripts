# Included at build time; only ddnsto-install.sh is a public installer.
ddnsto_error() { printf 'DDNSTO: %s\n' "$*" >&2; }

ddnsto_usage() {
    printf '%s\n' 'Usage: ddnsto-install.sh [--token TOKEN] [--force-version lite|standard] [--verify-status]' \
        'OpenWrt: token optional; automatic Lite selection below 900 MB.' \
        'Linux x86_64/aarch64: --token required without an interactive terminal.'
    printf '%s\n' 'Linux systemd: root/sudo -H, system scope; --installer-prefix PATH and --installer-work-dir PATH precede business arguments.'
}

ddnsto_parse_args() {
    TOKEN=
    FORCE_VERSION=
    VERIFY_STATUS=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --token|--force-version)
                [ "$#" -ge 2 ] && [ -n "$2" ] || { ddnsto_error "$1 requires a value"; return 2; }
                case "$1" in --token) TOKEN=$2 ;; *) FORCE_VERSION=$2 ;; esac
                shift 2 ;;
            --token=*) TOKEN=${1#--token=}; [ -n "$TOKEN" ] || return 2; shift ;;
            --force-version=*) FORCE_VERSION=${1#--force-version=}; shift ;;
            --verify-status) VERIFY_STATUS=1; shift ;;
            *) ddnsto_error "unknown argument: $1"; return 2 ;;
        esac
    done
    case "$FORCE_VERSION" in ''|lite|standard) ;; *) ddnsto_error 'version must be lite or standard'; return 2 ;; esac
}

ddnsto_download() { installer_download "$@"; }

# Markers are written only after zsetup has verified and committed an artifact.
ddnsto_verified_download() {
    verified_relative=$1
    verified_output=$2
    verified_sha=$3
    verified_marker="$verified_output.verified"
    ddnsto_download "$verified_relative" "$verified_output" "$verified_sha"
    verified_size=$(wc -c < "$verified_output" | tr -d '[:space:]')
    printf '%s:%s\n' "$verified_sha" "$verified_size" > "$transaction_dir/verified"
    mv -f "$transaction_dir/verified" "$verified_marker"
}

ddnsto_checksum() {
    "$ZSETUP_BIN" metadata sha256 "$1" "$2" || {
        ddnsto_error "invalid, missing or duplicate SHA256 for $2"; return 11;
    }
}

ddnsto_rollback() {
    [ "${replacement_started:-0}" = 1 ] || return 0
    if [ "$had_old" = 1 ]; then
        ddnsto_privileged mv -f "$backup" "$bin_path" || {
            ddnsto_error "rollback failed; backup retained at $backup"; return 1;
        }
        replacement_started=0
        ddnsto_privileged "$bin_path" -u "$TOKEN" -daemon || status 'DDNSTO: previous service could not be restarted; manual recovery needed'
    else
        ddnsto_privileged rm -f "$bin_path"
        replacement_started=0
    fi
}

ddnsto_cleanup() {
    ddnsto_rollback || true
    [ -z "${install_candidate:-}" ] || ddnsto_privileged rm -f "$install_candidate"
    if [ "${replacement_started:-0}" = 0 ] && [ -n "${backup:-}" ]; then
        ddnsto_privileged rm -f "$backup"
    fi
    if [ "${deprecated_config:-0}" = 1 ] && [ -f "${transaction_dir:-}/deprecated-config" ]; then
        cp -p "$transaction_dir/deprecated-config" "$config_path"
    fi
    [ -z "${transaction_dir:-}" ] || rm -rf "$transaction_dir"
}

ddnsto_privileged() {
    if [ -n "${SUDO:-}" ]; then "$SUDO" "$@"; else "$@"; fi
}

ddnsto_register() {
    # DDNSTO reports OK but keeps an existing unit's executable path. Only
    # remove the already-proven managed definition, with rollback owned by
    # installer_service_cleanup; never uninstall a foreign service.
    if [ "$SERVICE_HAD_UNIT" = 1 ]; then
        installer_service_manager disable || return $?
        rm -f "$SERVICE_UNIT" || return 12
        installer_service_manager reload || return $?
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
    version_pointer=VERSION
    [ "$SELECTED_VERSION" != lite ] || version_pointer=VERSION_LITE
    ddnsto_download "openwrt/$version_pointer" "$transaction_dir/version" '' 1
    version_num=$("$ZSETUP_BIN" metadata version "$transaction_dir/version")
    case "$version_num" in ''|*[!0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._+-]*) ddnsto_error 'invalid version metadata'; return 11 ;; esac
    version_folder=$SELECTED_VERSION
    [ "$pkg_ext" != apk ] || version_folder="$version_folder-apk"
    relative_folder="openwrt/$version_folder/$version_num"
    ddnsto_download "$relative_folder/SHA256SUMS" "$transaction_dir/sums" '' 1
    status "      DDNSTO $version_num ($SELECTED_VERSION; Lite below 900 MB)"
    status '[3/4] Downloading and verifying DDNSTO packages...'
    package_cache="$work_dir/cache/$version_folder/$version_num/$arch"
    mkdir -p "$package_cache"
    main_package="ddnsto_$package_arch.$pkg_ext"
    ui_package="luci-app-ddnsto.$pkg_ext"
    language_package="luci-i18n-ddnsto-zh-cn.$pkg_ext"
    for package in "$main_package" "$ui_package" "$language_package"; do
        digest=$(ddnsto_checksum "$transaction_dir/sums" "$package")
        ddnsto_verified_download "$relative_folder/$package" "$package_cache/$package" "$digest"
    done
    status '[4/4] Installing DDNSTO packages...'
    # All packages are verified before touching dependencies or installed packages.
    config_path=${DDNSTO_CONFIG_PATH:-/etc/config/ddnsto}
    deprecated_config=0
    if [ -f "$config_path" ] && grep -Eqi 'global' "$config_path"; then
        cp -p "$config_path" "$transaction_dir/deprecated-config"
        deprecated_config=1
        rm -f "$config_path"
    fi
    if [ "$package_manager" = opkg ]; then
        if [ -f /www/luci-static/resources/luci.js ] && [ ! -f /usr/lib/lua/luci/cbi.lua ]; then
            opkg update && opkg install luci-compat || status 'DDNSTO: luci-compat installation failed'
        fi
        if ! opkg list-installed | grep -q '^luci-lua-runtime '; then
            opkg update && opkg install luci-lua-runtime || status 'DDNSTO: luci-lua-runtime installation failed'
        fi
        opkg remove app-meta-ddnsto luci-i18n-ddnsto-zh-cn luci-app-ddnsto ddnsto || true
        for package in "$main_package" "$ui_package" "$language_package"; do opkg install "$package_cache/$package"; done
    else
        if [ -f /www/luci-static/resources/luci.js ] && [ ! -f /usr/lib/lua/luci/cbi.lua ]; then
            apk update && apk add luci-compat || status 'DDNSTO: luci-compat installation failed'
        fi
        if ! apk info -e luci-lua-runtime >/dev/null 2>&1; then
            apk update && apk add luci-lua-runtime || status 'DDNSTO: luci-lua-runtime installation failed'
        fi
        apk del app-meta-ddnsto luci-i18n-ddnsto-zh-cn luci-app-ddnsto ddnsto || true
        for package in "$main_package" "$ui_package" "$language_package"; do apk add --allow-untrusted "$package_cache/$package"; done
    fi
    ddnsto -v
    deprecated_config=0
    if [ -n "$TOKEN" ]; then
        uci set "ddnsto.@ddnsto[0].token=$TOKEN"
        uci set 'ddnsto.@ddnsto[0].enabled=1'
        uci commit ddnsto
        "${DDNSTO_SERVICE_PATH:-/etc/init.d/ddnsto}" restart
    else
        status 'DDNSTO: get a token at https://www.ddnsto.com and configure it in LuCI'
    fi
    if [ "$VERIFY_STATUS" = 1 ]; then
        pgrep -x ddnstod >/dev/null || { ddnsto_error 'DDNSTO process not found'; return 1; }
        ddnsto -w
    fi
    status 'DDNSTO installation completed; refresh LuCI if its menu is missing'
}

ddnsto_linux() {
    case "$arch" in x86_64|aarch64) ;; *) ddnsto_error "unsupported Linux architecture: $arch"; return 2 ;; esac
    [ "$FORCE_VERSION" != lite ] || { ddnsto_error 'Linux only supports standard'; return 2; }
    [ "$VERIFY_STATUS" = 0 ] || { ddnsto_error '--verify-status is for OpenWrt'; return 2; }
    if [ -z "$TOKEN" ]; then
        if [ -t 0 ]; then
            printf 'DDNSTO token: ' >&2
            IFS= read -r TOKEN
        else
            ddnsto_error 'Linux needs --token TOKEN for noninteractive installation'; return 2
        fi
    fi
    [ -n "$TOKEN" ] || { ddnsto_error 'empty token'; return 2; }
    version_num=${DDNSTO_VERSION:-4.2.3}
    case "$version_num" in ''|*[!0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._+-]*) ddnsto_error 'invalid DDNSTO_VERSION'; return 2 ;; esac
    status "[2/4] Checking DDNSTO standard $version_num ($arch)..."
    archive_name="ddnsto-standard-$version_num.tar.gz"
    ddnsto_download linux-binary/SHA256SUMS "$transaction_dir/sums" '' 1
    digest=$(ddnsto_checksum "$transaction_dir/sums" "$archive_name")
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
    : "${ZSETUP_BIN:?zsetup is required}" "${ZSETUP_SOURCE_BASES:?source group is required}"
    ddnsto_parse_args "$@"
    os=${ZSETUP_OS:-$("$ZSETUP_BIN" context get os)}
    package_manager=${ZSETUP_PACKAGE_MANAGER:-$("$ZSETUP_BIN" context get package_manager)}
    arch=${ZSETUP_ARCH:-$("$ZSETUP_BIN" context get arch)}
    case "$os:$package_manager" in
        openwrt:opkg|openwrt:apk) business_platform=openwrt ;;
        ubuntu:apt|debian:apt|centos:yum|centos:dnf|rhel:yum|rhel:dnf|linux:*) business_platform=linux ;;
        *) ddnsto_error "unsupported platform: $os/$package_manager"; return 2 ;;
    esac
    INSTALLER_REMOTE_APP=ddnsto
    if [ "$business_platform" = linux ]; then
        [ -z "${DDNSTO_BIN_PATH:-}" ] || { ddnsto_error 'DDNSTO_BIN_PATH is retired; use --installer-prefix for the protected installation root'; return 2; }
        installer_service_prepare ddnsto || return $?
        ddnsto_linux || return $?
        installer_transaction_finish
        return $?
    fi
    [ -z "${installer_prefix:-}${installer_work_dir:-}" ] && [ "${installer_scope:-system}" = system ] || { ddnsto_error 'OpenWrt storage adapter is pending; do not apply Linux layout options to native packages'; return 2; }
    installer_policy ddnsto || return $?
    work_dir=${ZSETUP_WORK_DIR:-${WORK_ROOT}/ddnsto}
    mkdir -p "$work_dir"
    chmod 0700 "$work_dir"
    transaction_dir=$(mktemp -d "$work_dir/.transaction.XXXXXX")
    install_candidate=
    backup=
    replacement_started=0
    SUDO=
    trap ddnsto_cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [ "$business_platform" = openwrt ]; then ddnsto_openwrt; else ddnsto_linux; fi
    ddnsto_cleanup
    transaction_dir=
    trap - EXIT HUP INT TERM
}
