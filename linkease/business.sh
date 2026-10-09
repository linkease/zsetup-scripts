# Included at build time; only linkease-install.sh is maintained as the public entry.
linkease_error() { printf 'LinkEase: %s\n' "$*" >&2; }

linkease_usage() {
    printf '%s\n' 'Usage: linkease-install.sh [--version VERSION]' \
        'Linux: default version 1.7.5; installs LinkEase, media, HEIF converter and linkmount.' \
        'OpenWrt opkg: defaults to server VERSION; x86_64/aarch64/armv7 supported.'
}

linkease_parse_args() {
    version_override=${LINKEASE_VERSION:-}
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --version)
                [ "$#" -ge 2 ] && [ -n "$2" ] || { linkease_error '--version requires a value'; return 2; }
                version_override=$2; shift 2 ;;
            --version=*) version_override=${1#--version=}; [ -n "$version_override" ] || return 2; shift ;;
            *) linkease_error "unknown argument: $1"; return 2 ;;
        esac
    done
    case "$version_override" in '' ) ;; *[!0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._+-]*|.*|-*|+*|_*) linkease_error 'invalid version'; return 2 ;; esac
    [ "${#version_override}" -le 64 ] || return 2
}

# All transport, HTTPS/Race/fallback policy and digest verification remain in zsetup.
linkease_download() {
    le_relative=$1; le_destination=$2; le_sha=${3:-}; le_fresh=${4:-0}
    set -- "$ZSETUP_BIN" download -o "$le_destination"
    [ -z "$le_sha" ] || set -- "$@" --sha256 "$le_sha"
    [ "$le_fresh" = 0 ] || set -- "$@" --no-cache
    [ -z "${ZSETUP_CA_FILE:-}" ] || set -- "$@" --ca-file "$ZSETUP_CA_FILE"
    for le_base in $ZSETUP_SOURCE_BASES; do
        set -- "$@" "${le_base%/}/LinkEase/$le_relative"
    done
    [ -z "${ZSETUP_SOURCE_FALLBACK:-}" ] || set -- "$@" --fallback-url "${ZSETUP_SOURCE_FALLBACK%/}/LinkEase/$le_relative"
    "$@"
}

linkease_verified_download() {
    le_name=$1
    le_digest=$("$ZSETUP_BIN" metadata sha256 "$transaction_dir/sums" "$le_name") || {
        linkease_error "invalid or missing SHA256 for $le_name"; return 11;
    }
    le_file="$cache_dir/$le_name"
    le_marker="$le_file.verified"
    if [ -s "$le_file" ] && [ -f "$le_marker" ]; then
        le_size=$(wc -c < "$le_file" | tr -d '[:space:]')
        if [ "$(cat "$le_marker")" = "$le_digest:$le_size" ]; then
            status "      Using verified cached $le_name"
            return 0
        fi
    fi
    linkease_download "$relative_folder/$le_name" "$le_file" "$le_digest"
    le_size=$(wc -c < "$le_file" | tr -d '[:space:]')
    printf '%s:%s\n' "$le_digest" "$le_size" > "$transaction_dir/verified"
    mv -f "$transaction_dir/verified" "$le_marker"
}

linkease_privileged() {
    if [ -n "${SUDO:-}" ]; then "$SUDO" "$@"; else "$@"; fi
}

linkease_stop_service() {
    if command -v systemctl >/dev/null 2>&1; then
        linkease_privileged systemctl stop com.linkease.linkeasedaemon.service
    elif command -v service >/dev/null 2>&1; then
        linkease_privileged service com.linkease.linkeasedaemon.service stop
    else
        linkease_privileged "${LINKEASE_SERVICE_PATH:-/etc/init.d/com.linkease.linkeasedaemon.service}" stop
    fi
}

linkease_rollback() {
    [ "${replacement_started:-0}" = 1 ] || return 0
    status 'LinkEase: restoring the previous installation...'
    linkease_stop_service || true
    if [ -x "$app_dir/linkease" ]; then
        linkease_privileged "$app_dir/linkease" --serviceControl uninstall || true
    fi
    for le_restore in linkease heif-converter linkease-media linkmount; do
        linkease_privileged rm -rf "$app_dir/$le_restore" || return 1
        if [ -e "$backup_dir/$le_restore" ]; then
            linkease_privileged cp -Rp "$backup_dir/$le_restore" "$app_dir/$le_restore" || return 1
        fi
    done
    if [ -f "$backup_dir/linkease" ]; then
        linkease_privileged "$app_dir/linkease" --serviceControl install || return 1
        linkease_privileged "$app_dir/linkease" --serviceControl start || return 1
    fi
    replacement_started=0
}

linkease_cleanup() {
    le_recovery_failed=0
    linkease_rollback || le_recovery_failed=1
    if [ "$le_recovery_failed" = 1 ]; then
        linkease_error "rollback incomplete; recovery files retained at $backup_dir"
    elif [ -n "${backup_dir:-}" ]; then
        linkease_privileged rm -rf "$backup_dir"
    fi
    [ -z "${candidate_dir:-}" ] || linkease_privileged rm -rf "$candidate_dir"
    [ -z "${install_lock:-}" ] || linkease_privileged rmdir "$install_lock"
    [ -z "${transaction_dir:-}" ] || rm -rf "$transaction_dir"
}

# Stream only requested members to regular staging files: no archive-provided paths/links are installed.
linkease_unpack_linux() {
    mkdir -p "$transaction_dir/products/linkmount"
    for le_binary in linkease heif-converter linkease-media; do
        tar -xOzf "$cache_dir/$archive_name" "linkease-binary-$version_num/$le_binary.$binary_arch" > "$transaction_dir/products/$le_binary"
        [ -s "$transaction_dir/products/$le_binary" ] || { linkease_error "empty or missing $le_binary"; return 11; }
        chmod 0755 "$transaction_dir/products/$le_binary"
    done
    # Info-ZIP -Z1 is required on Linux. Read filenames with shell builtins, without awk/sed.
    unzip -Z1 "$cache_dir/$mount_name" > "$transaction_dir/zip-members" || {
        linkease_error 'unzip must support -Z1 member listing'; return 2;
    }
    while IFS= read -r le_member || [ -n "$le_member" ]; do
        case "$le_member" in
            ''|*[!0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._+/-]*|/*|../*|*/../*|*/..|./*|*/./*|*/.|*//* )
                linkease_error 'invalid linkmount archive member'; return 11 ;;
        esac
        case "$le_member" in
            "$mount_arch/"|"$mount_arch/bin/") continue ;;
            "$mount_arch/bin/"*) le_output=${le_member#"$mount_arch/bin/"} ;;
            *) linkease_error 'unexpected linkmount archive layout'; return 11 ;;
        esac
        case "$le_output" in
            */) mkdir -p "$transaction_dir/products/linkmount/$le_output" ;;
            *)
                le_target="$transaction_dir/products/linkmount/$le_output"
                [ ! -e "$le_target" ] || { linkease_error 'duplicate linkmount archive member'; return 11; }
                mkdir -p "$(dirname "$le_target")"
                unzip -p "$cache_dir/$mount_name" "$le_member" > "$le_target"
                [ -s "$le_target" ] || { linkease_error 'empty linkmount archive file'; return 11; } ;;
        esac
    done < "$transaction_dir/zip-members"
    [ -s "$transaction_dir/products/linkmount/linkmount_bin" ] || { linkease_error 'linkmount_bin missing'; return 11; }
    chmod -R 0755 "$transaction_dir/products/linkmount"
    "$transaction_dir/products/linkease" showVersion
}

linkease_linux() {
    for le_tool in tar unzip; do
        command -v "$le_tool" >/dev/null 2>&1 || { linkease_error "$le_tool is required on Linux"; return 2; }
    done
    case "$arch" in x86_64) binary_arch=x86_64; mount_arch=amd64 ;; aarch64) binary_arch=aarch64; mount_arch=arm64 ;; armv7) binary_arch=arm; mount_arch=arm ;; esac
    version_num=${version_override:-1.7.5}
    app_dir=${LINKEASE_APP_DIR:-/usr/sbin}
    case "$app_dir" in /*) ;; *) linkease_error 'installation directory must be absolute'; return 2 ;; esac
    [ "$app_dir" != / ] || { linkease_error 'installation directory must not be /'; return 2; }
    if [ ! -w "$app_dir" ] && [ "$(id -u)" != 0 ]; then
        command -v sudo >/dev/null 2>&1 || { linkease_error 'root or sudo is required'; return 2; }
        SUDO=sudo
    fi
    status "[2/4] Checking LinkEase $version_num ($arch)..."
    relative_folder="LinuxStorage/$version_num"
    linkease_download "$relative_folder/SHA256SUMS" "$transaction_dir/sums" '' 1
    cache_dir="$work_dir/cache/linux/$version_num/$arch"
    mkdir -p "$cache_dir"
    archive_name="linkease-binary-$version_num.tar.gz"
    mount_name="$mount_arch.zip"
    status '[3/4] Downloading and verifying LinkEase and linkmount...'
    linkease_verified_download "$archive_name"
    linkease_verified_download "$mount_name"
    linkease_unpack_linux
    status '[4/4] Installing and starting LinkEase...'
    linkease_privileged mkdir -p "$app_dir"
    # Serialize replacement in the destination, including callers using different cache directories.
    le_lock="$app_dir/.linkease-install-lock"
    linkease_privileged mkdir "$le_lock" || { linkease_error 'another install or unrecovered install lock exists'; return 2; }
    install_lock=$le_lock
    candidate_dir="$app_dir/.linkease-candidate.$$"
    backup_dir="$app_dir/.linkease-backup.$$"
    linkease_privileged mkdir "$candidate_dir" "$backup_dir"
    linkease_privileged cp -Rp "$transaction_dir/products/." "$candidate_dir/"
    for le_existing in linkease heif-converter linkease-media linkmount; do
        [ ! -L "$app_dir/$le_existing" ] || { linkease_error "refusing to replace symbolic link $le_existing"; return 2; }
        if [ -e "$app_dir/$le_existing" ]; then
            linkease_privileged cp -Rp "$app_dir/$le_existing" "$backup_dir/$le_existing"
        fi
    done
    if [ -f "$backup_dir/linkease" ]; then linkease_stop_service; fi
    replacement_started=1
    for le_install in linkease heif-converter linkease-media linkmount; do
        linkease_privileged rm -rf "$app_dir/$le_install"
        linkease_privileged mv "$candidate_dir/$le_install" "$app_dir/$le_install"
    done
    # Match the proven installer: replace the service definition as well as its files.
    linkease_privileged "$app_dir/linkease" --serviceControl uninstall || true
    if linkease_privileged "$app_dir/linkease" --serviceControl install; then :; else
        le_code=$?; linkease_error 'service installation failed'; return "$le_code"
    fi
    if linkease_privileged "$app_dir/linkease" --serviceControl start; then :; else
        le_code=$?
        le_init=${LINKEASE_SERVICE_PATH:-/etc/init.d/com.linkease.linkeasedaemon.service}
        if [ -x "$le_init" ] && linkease_privileged "$le_init" start; then :; else
            linkease_error 'service start failed'; return "$le_code"
        fi
    fi
    replacement_started=0
    status 'LinkEase installation completed'
}

linkease_openwrt() {
    command -v opkg >/dev/null 2>&1 || { linkease_error 'OpenWrt requires opkg'; return 2; }
    case "$arch" in x86_64|aarch64) package_arch=$arch ;; armv7) package_arch=arm ;; esac
    version_num=$version_override
    status "[2/4] Checking LinkEase OpenWrt version ($arch)..."
    if [ -z "$version_num" ]; then
        linkease_download Openwrt/VERSION "$transaction_dir/version" '' 1
        version_num=$("$ZSETUP_BIN" metadata version "$transaction_dir/version")
    fi
    relative_folder="Openwrt/$version_num"
    linkease_download "$relative_folder/SHA256SUMS" "$transaction_dir/sums" '' 1
    cache_dir="$work_dir/cache/openwrt/$version_num/$arch"
    mkdir -p "$cache_dir"
    status '[3/4] Downloading and verifying LinkEase packages...'
    set -- "linkease_$package_arch.ipk" luci-app-linkease.ipk luci-i18n-linkease-zh-cn.ipk
    case "$arch" in x86_64|aarch64) set -- "$@" "linkmount_$arch.ipk" "ffmpeg-remux_$arch.ipk" ;; esac
    for le_package in "$@"; do linkease_verified_download "$le_package"; done
    status '[4/4] Installing LinkEase packages...'
    opkg remove app-meta-linkease luci-i18n-linkease-zh-cn luci-app-linkease linkease || true
    for le_package in "$@"; do opkg install "$cache_dir/$le_package"; done
    linkease showVersion
    status 'LinkEase installation completed; refresh LuCI if its menu is missing'
}

linkease_install() {
    : "${ZSETUP_BIN:?zsetup is required}" "${ZSETUP_SOURCE_BASES:?source group is required}"
    linkease_parse_args "$@"
    os=${ZSETUP_OS:-$("$ZSETUP_BIN" context get os)}
    package_manager=${ZSETUP_PACKAGE_MANAGER:-$("$ZSETUP_BIN" context get package_manager)}
    arch=${ZSETUP_ARCH:-$("$ZSETUP_BIN" context get arch)}
    case "$arch" in x86_64|aarch64|armv7) ;; *) linkease_error "unsupported architecture: $arch"; return 2 ;; esac
    case "$os:$package_manager" in
        openwrt:opkg) business_platform=openwrt ;;
        ubuntu:apt|debian:apt|centos:yum|centos:dnf|rhel:yum|rhel:dnf|linux:*) business_platform=linux ;;
        *) linkease_error "unsupported platform: $os/$package_manager"; return 2 ;;
    esac
    work_dir=${ZSETUP_WORK_DIR:-$WORK_ROOT/linkease}
    mkdir -p "$work_dir"
    chmod 0700 "$work_dir"
    transaction_dir=$(mktemp -d "$work_dir/.transaction.XXXXXX")
    replacement_started=0; candidate_dir=; backup_dir=; install_lock=; SUDO=
    trap linkease_cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [ "$business_platform" = openwrt ]; then linkease_openwrt; else linkease_linux; fi
    linkease_cleanup
    transaction_dir=; candidate_dir=; backup_dir=; install_lock=
    trap - EXIT HUP INT TERM
}
