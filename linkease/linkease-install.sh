#!/bin/sh
set -eu

WORK_ROOT=${ZSETUP_ROOT:-/tmp/zsetup}
DEFAULT_PRIMARY_BASES="https://dl.istoreos.com/binary https://fw.d4ctech.com/binary https://fw20.koolcenter.com/binary"
DEFAULT_FALLBACK_BASE="https://fw.koolcenter.com/binary"
if [ -n "${ZSETUP_BOOTSTRAP_BASES:-}" ]; then
    BOOTSTRAP_BASES=$ZSETUP_BOOTSTRAP_BASES
    DIRECT_PRIMARY_BASES=$ZSETUP_BOOTSTRAP_BASES
    DIRECT_FALLBACK_BASE=
else
    BOOTSTRAP_BASES="$DEFAULT_PRIMARY_BASES $DEFAULT_FALLBACK_BASE"
    DIRECT_PRIMARY_BASES=$DEFAULT_PRIMARY_BASES
    DIRECT_FALLBACK_BASE=$DEFAULT_FALLBACK_BASE
fi
INSECURE_CONFIRMED=0

status() {
    printf '%s\n' "$*" >&2
}

bootstrap_mips_byte_order() {
    command -v od >/dev/null 2>&1 || return 1
    set -- $(od -An -tu1 -N6 /bin/sh 2>/dev/null)
    [ "$#" -eq 6 ] && [ "$1" = 127 ] && [ "$2" = 69 ] && [ "$3" = 76 ] && [ "$4" = 70 ] && [ "$6" = 1 ]
}

bootstrap_arch() {
    case "$(uname -m 2>/dev/null || true)" in
        x86_64|amd64) ZSETUP_ARCH=x86_64 ;;
        aarch64|arm64) ZSETUP_ARCH=aarch64 ;;
        armv7l|armv7) ZSETUP_ARCH=armv7 ;;
        mipsel|mipsle) ZSETUP_ARCH=mipsel ;;
        mips)
            # uname alone does not identify byte order. ELF EI_DATA=1 is little endian.
            bootstrap_mips_byte_order || { echo "zsetup: MIPS byte order is unsupported or unknown" >&2; return 2; }
            ZSETUP_ARCH=mipsel ;;
        *) echo "zsetup: unsupported architecture" >&2; return 2 ;;
    esac
    ZSETUP_ARTIFACT="zsetup-linux-$ZSETUP_ARCH"
}

bootstrap_url() {
    scheme=$1
    base=$2
    path=$3
    authority_path=${base#*://}
    printf '%s://%s/%s\n' "$scheme" "${authority_path%/}" "$path"
}

bootstrap_fetch_from_base() {
    scheme=$1
    base=$2
    remote_path=$3
    destination=$4
    found=0
    url=$(bootstrap_url "$scheme" "$base" "$remote_path")
    if command -v curl >/dev/null 2>&1; then
        found=1
        rm -f "$destination" 2>/dev/null || true
        if curl -fsSL --connect-timeout 10 --max-time 30 -o "$destination" "$url"; then
            return 0
        fi
    fi
    if command -v wget >/dev/null 2>&1; then
        found=1
        rm -f "$destination" 2>/dev/null || true
        if wget -q -T 10 -O "$destination" "$url"; then
            return 0
        fi
    fi
    [ "$found" -eq 1 ] || echo "zsetup: curl or wget is required for first bootstrap" >&2
    return 1
}

bootstrap_fetch() {
    scheme=$1
    remote_path=$2
    destination=$3
    for base in $BOOTSTRAP_BASES; do
        if bootstrap_fetch_from_base "$scheme" "$base" "$remote_path" "$destination"; then
            return 0
        fi
    done
    return 1
}

confirm_insecure_http() {
    [ "$INSECURE_CONFIRMED" -eq 0 ] || return 0
    echo "zsetup: all HTTPS bootstrap sources failed." >&2
    echo "WARNING: HTTP can be intercepted; both zsetup and checksum metadata may be replaced." >&2
    printf 'Continue with insecure HTTP bootstrap? [y/N] ' >&2
    confirm_file=${ZSETUP_CONFIRM_FILE:-/dev/tty}
    answer=
    if ! IFS= read -r answer < "$confirm_file"; then
        echo >&2
        echo "zsetup: HTTP bootstrap refused because no interactive confirmation is available" >&2
        return 1
    fi
    case "$answer" in
        y|Y|yes|YES) INSECURE_CONFIRMED=1; echo "zsetup: user accepted insecure HTTP bootstrap" >&2 ;;
        *) echo "zsetup: insecure HTTP bootstrap declined" >&2; return 1 ;;
    esac
}

read_stable_version() {
    file=$1
    IFS= read -r RESCUE_VERSION < "$file" || return 1
    case "$RESCUE_VERSION" in
        ''|*[!0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._+-]*) return 1 ;;
    esac
    [ -n "$RESCUE_VERSION" ] && [ "${#RESCUE_VERSION}" -le 64 ] || return 1
    compatibility_version=${RESCUE_VERSION%%[-+]*}
    compatibility_major=${compatibility_version%%.*}
    compatibility_rest=${compatibility_version#*.}
    compatibility_minor=${compatibility_rest%%.*}
    compatibility_patch=${compatibility_rest#*.}
    case "$compatibility_major:$compatibility_minor:$compatibility_patch" in *[!0123456789:]*|::*|*::*) return 1 ;; esac
    if [ "$compatibility_major" -eq 0 ]; then
        [ "$compatibility_minor" -ge 2 ] || return 1
        if [ "$compatibility_minor" -eq 2 ]; then [ "$compatibility_patch" -ge 4 ] || return 1; fi
    fi
}

read_expected_sha256() {
    file=$1
    EXPECTED_SHA256=
    while IFS=' ' read -r digest name remainder; do
        name=${name#\*}
        if [ "$name" = "$ZSETUP_ARTIFACT" ] && [ -z "${remainder:-}" ]; then
            EXPECTED_SHA256=$digest
            break
        fi
    done < "$file"
    [ "${#EXPECTED_SHA256}" -eq 64 ] || return 1
    case "$EXPECTED_SHA256" in *[!0123456789abcdefABCDEF]*) return 1 ;; esac
}

have_hash_tool() {
    command -v sha256sum >/dev/null 2>&1 || command -v openssl >/dev/null 2>&1
}

hash_matches() {
    [ -f "$1" ] || return 1
    if [ -z "${EXPECTED_SHA256:-}" ]; then
        echo "zsetup: bootstrap SHA-256 verification skipped; HTTPS transport remains required" >&2
        return 0
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "$1")
        actual=${actual%% *}
    elif command -v openssl >/dev/null 2>&1; then
        actual=$(openssl dgst -sha256 "$1")
        actual=${actual##*= }
    else
        echo "zsetup: bootstrap SHA-256 tool disappeared before verification" >&2
        return 1
    fi
    [ "$actual" = "$EXPECTED_SHA256" ]
}

is_expected_zsetup() {
    [ -x "$1" ] && [ "$("$1" --version 2>/dev/null || true)" = "zsetup $RESCUE_VERSION" ]
}

find_existing_zsetup() {
    if [ -n "${ZSETUP_BIN:-}" ] && is_expected_zsetup "$ZSETUP_BIN"; then
        ACTIVE_ZSETUP=$ZSETUP_BIN
        return 0
    fi
    if is_expected_zsetup "$WORK_ROOT/rescue/$RESCUE_VERSION/zsetup"; then
        ACTIVE_ZSETUP="$WORK_ROOT/rescue/$RESCUE_VERSION/zsetup"
        return 0
    fi
    if command -v zsetup >/dev/null 2>&1; then
        system_zsetup=$(command -v zsetup)
        if is_expected_zsetup "$system_zsetup"; then
            ACTIVE_ZSETUP=$system_zsetup
            return 0
        fi
    fi
    return 1
}

fetch_bootstrap_metadata() {
    scheme=$1
    stable_file=$2
    sums_file=$3
    for base in $BOOTSTRAP_BASES; do
        bootstrap_fetch_from_base "$scheme" "$base" zsetup/stable "$stable_file" || continue
        read_stable_version "$stable_file" || continue
        EXPECTED_SHA256=
        if have_hash_tool && bootstrap_fetch_from_base "$scheme" "$base" "zsetup/$RESCUE_VERSION/SHA256SUMS" "$sums_file"; then
            read_expected_sha256 "$sums_file" || EXPECTED_SHA256=
        fi
        return 0
    done
    echo "zsetup: no source returned valid stable metadata over $scheme" >&2
    return 1
}

bootstrap_zsetup() {
    bootstrap_arch
    state_dir="$WORK_ROOT/bootstrap"
    mkdir -p "$state_dir"
    stable_file="$state_dir/.stable.$$"
    sums_file="$state_dir/.SHA256SUMS.$$"
    trap 'rm -f "$stable_file" "$sums_file" "${candidate:-}" 2>/dev/null || true' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    metadata_scheme=https
    if ! fetch_bootstrap_metadata https "$stable_file" "$sums_file"; then
        confirm_insecure_http
        metadata_scheme=http
        fetch_bootstrap_metadata http "$stable_file" "$sums_file"
    fi

    if find_existing_zsetup; then
        trap - EXIT HUP INT TERM
        rm -f "$stable_file" "$sums_file" 2>/dev/null || true
        return 0
    fi

    rescue_dir="$WORK_ROOT/rescue/$RESCUE_VERSION"
    rescue_bin="$rescue_dir/zsetup"
    candidate="$rescue_dir/.zsetup-download.$$"
    mkdir -p "$rescue_dir"
    if ! bootstrap_fetch https "zsetup/$RESCUE_VERSION/$ZSETUP_ARTIFACT" "$candidate"; then
        confirm_insecure_http
        bootstrap_fetch http "zsetup/$RESCUE_VERSION/$ZSETUP_ARTIFACT" "$candidate"
    fi
    hash_matches "$candidate" || {
        echo "zsetup: bootstrap checksum mismatch" >&2
        return 1
    }
    chmod 0755 "$candidate"
    is_expected_zsetup "$candidate" || {
        echo "zsetup: downloaded bootstrap has the wrong product or version" >&2
        return 1
    }
    mv -f "$candidate" "$rescue_bin"
    ACTIVE_ZSETUP=$rescue_bin
    trap - EXIT HUP INT TERM
    rm -f "$stable_file" "$sums_file" 2>/dev/null || true
    [ "$metadata_scheme" = https ] || echo "zsetup: insecure HTTP bootstrap completed with user consent" >&2
}


# Business logic: maintained in linkease/business.sh
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


bootstrap_and_run() {
    status "[1/4] Checking zsetup..."
    bootstrap_zsetup
    status "      zsetup $RESCUE_VERSION is ready"
    ZSETUP_BIN=$ACTIVE_ZSETUP
    ZSETUP_SOURCE_BASES=${ZSETUP_SOURCE_BASES:-$DIRECT_PRIMARY_BASES}
    ZSETUP_SOURCE_FALLBACK=${ZSETUP_SOURCE_FALLBACK-$DIRECT_FALLBACK_BASE}
    export ZSETUP_BIN ZSETUP_ARCH ZSETUP_SOURCE_BASES ZSETUP_SOURCE_FALLBACK
    linkease_install "$@"
}

main() {
    case "${1:-}" in --help|-h) linkease_usage; return 0 ;; esac
    status 'LinkEase installer'
    if [ "${ZSETUP_INSTALLER_MODE:-0}" = 1 ]; then
        status '[1/4] zsetup is ready'
        linkease_install "$@"
    else
        bootstrap_and_run "$@"
    fi
}
main "$@"
