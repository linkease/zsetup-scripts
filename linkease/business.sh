# Included at build time; only linkease-install.sh is maintained as the public entry.
linkease_error() { printf 'LinkEase: %s\n' "$*" >&2; }

linkease_usage() {
    printf '%s\n' 'Usage: linkease-install.sh [--version VERSION]' \
        'Linux: default version 1.7.5; installs LinkEase, media, HEIF converter and linkmount.' \
        'OpenWrt opkg: defaults to server VERSION; x86_64/aarch64/armv7 supported.'
    printf '%s\n' 'Linux systemd: root/sudo -H, system scope; --installer-prefix PATH and --installer-work-dir PATH precede business arguments.'
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
linkease_download() { installer_download "$@"; }

linkease_verified_download() {
    le_name=$1
    le_digest=$("$ZSETUP_BIN" metadata sha256 "$transaction_dir/sums" "$le_name") || {
        linkease_error "invalid or missing SHA256 for $le_name"; return 11;
    }
    le_file="$cache_dir/$le_name"
    le_marker="$le_file.verified"
    installer_package_immutable "$le_marker" "$le_digest" || return $?
    linkease_download "$relative_folder/$le_name" "$le_file" "$le_digest" || return $?
    le_size=$(wc -c < "$le_file" | tr -d '[:space:]')
    printf '%s:%s\n' "$le_digest" "$le_size" > "$transaction_dir/verified"
    mv -f "$transaction_dir/verified" "$le_marker"
}

# Stream only requested members to regular staging files: no archive-provided paths/links are installed.
linkease_unpack_linux() {
    mkdir -p "$transaction_dir/products/linkmount"
    for le_binary in linkease heif-converter linkease-media; do
        installer_extract_member "$transaction_dir/products/$le_binary" tar -xOzf "$cache_dir/$archive_name" "linkease-binary-$version_num/$le_binary.$binary_arch" || return $?
        [ -s "$transaction_dir/products/$le_binary" ] || { linkease_error "empty or missing $le_binary"; return 11; }
        chmod 0755 "$transaction_dir/products/$le_binary"
    done
    # Info-ZIP -Z1 is required on Linux. Read filenames with shell builtins, without awk/sed.
    installer_exec_native "$ZSETUP_BIN" capture -o "$transaction_dir/zip-members" --max-bytes 16384 --min-free-bytes "$INSTALLER_RESERVE" -- unzip -Z1 "$cache_dir/$mount_name" || {
        linkease_error 'unzip must support -Z1 member listing'; return 2;
    }
    : > "$transaction_dir/mount-files"
    le_member_count=0
    while IFS= read -r le_member || [ -n "$le_member" ]; do
        le_member_count=$((le_member_count + 1))
        [ "$le_member_count" -le "$INSTALLER_MAX_FILES" ] || return 11
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
                installer_extract_member "$le_target" unzip -p "$cache_dir/$mount_name" "$le_member" || return $?
                printf '%s\n' "$le_output" >> "$transaction_dir/mount-files"
                [ -s "$le_target" ] || { linkease_error 'empty linkmount archive file'; return 11; } ;;
        esac
    done < "$transaction_dir/zip-members"
    [ -s "$transaction_dir/products/linkmount/linkmount_bin" ] || { linkease_error 'linkmount_bin missing'; return 11; }
    chmod -R 0755 "$transaction_dir/products/linkmount"
    installer_exec_native "$ZSETUP_BIN" run -- "$transaction_dir/products/linkease" showVersion
}

linkease_register() {
    if [ "$SERVICE_HAD_UNIT" = 1 ]; then
        installer_exec_native "$ZSETUP_BIN" run -- "$INSTALLER_PREFIX/$SERVICE_OLD/bin/linkease" --serviceControl uninstall || return $?
    fi
    installer_exec_native "$ZSETUP_BIN" run -- "$SERVICE_EXEC" --serviceControl install
}

linkease_linux_metadata() {
    for le_tool in tar unzip; do
        command -v "$le_tool" >/dev/null 2>&1 || { linkease_error "$le_tool is required on Linux"; return 2; }
    done
    case "$arch" in x86_64) binary_arch=x86_64; mount_arch=amd64 ;; aarch64) binary_arch=aarch64; mount_arch=arm64 ;; armv7) binary_arch=arm; mount_arch=arm ;; esac
    version_num=${version_override:-1.7.5}
    relative_folder="LinuxStorage/$version_num"
    status "[2/4] Checking LinkEase $version_num ($arch)..."
    linkease_download "$relative_folder/SHA256SUMS" "$transaction_dir/sums" '' 1 || return $?
    archive_name="linkease-binary-$version_num.tar.gz"; mount_name="$mount_arch.zip"
    le_archive_sha=$("$ZSETUP_BIN" metadata sha256 "$transaction_dir/sums" "$archive_name") || return 11
    le_mount_sha=$("$ZSETUP_BIN" metadata sha256 "$transaction_dir/sums" "$mount_name") || return 11
}

linkease_linux() {
    linkease_linux_metadata || return $?
    installer_service_cached "$version_num" "$le_archive_sha:$le_mount_sha" || return $?
    if [ "$SERVICE_CACHED" = 0 ]; then
        status '[3/4] Downloading and verifying LinkEase and linkmount...'
        cache_dir=$transaction_dir
        linkease_download "$relative_folder/$archive_name" "$cache_dir/$archive_name" "$le_archive_sha" || return $?
        linkease_download "$relative_folder/$mount_name" "$cache_dir/$mount_name" "$le_mount_sha" || return $?
        linkease_unpack_linux || return $?
        installer_service_stage || return $?
        for le_binary in linkease heif-converter linkease-media; do installer_service_copy "$le_binary" || return $?; done
        while IFS= read -r le_output; do installer_service_copy "linkmount/$le_output" || return $?; done < "$transaction_dir/mount-files"
        installer_service_commit_version || return $?
    else
        installer_exec_native "$ZSETUP_BIN" run -- "$SERVICE_EXEC" showVersion || return $?
    fi
    status '[4/4] Installing and checking the LinkEase system service...'
    installer_service_activate || return $?
    status 'LinkEase installation completed'
}

linkease_openwrt() {
    command -v opkg >/dev/null 2>&1 || { linkease_error 'OpenWrt requires opkg'; return 2; }
    case "$arch" in x86_64|aarch64) package_arch=$arch ;; armv7) package_arch=arm ;; esac
    version_num=$version_override
    status "[2/4] Checking LinkEase OpenWrt version ($arch)..."
    if [ -z "$version_num" ]; then
        linkease_download Openwrt/VERSION "$transaction_dir/version" '' 1 || return $?
        version_num=$("$ZSETUP_BIN" metadata version "$transaction_dir/version") || return $?
    fi
    relative_folder="Openwrt/$version_num"
    linkease_download "$relative_folder/SHA256SUMS" "$transaction_dir/sums" '' 1 || return $?
    installer_package_cache "$version_num" "$arch" || return $?
    cache_dir=$PACKAGE_CACHE
    status '[3/4] Downloading and verifying LinkEase packages...'
    set -- "linkease_$package_arch.ipk" luci-app-linkease.ipk luci-i18n-linkease-zh-cn.ipk
    case "$arch" in x86_64|aarch64) set -- "$@" "linkmount_$arch.ipk" "ffmpeg-remux_$arch.ipk" ;; esac
    for le_package in "$@"; do linkease_verified_download "$le_package" || return $?; done
    status '[4/4] Installing LinkEase packages...'
    installer_package_command remove remove app-meta-linkease luci-i18n-linkease-zh-cn luci-app-linkease linkease || true
    for le_package in "$@"; do installer_package_command install install "$cache_dir/$le_package" || return $?; done
    installer_exec_native "$ZSETUP_BIN" run -- linkease showVersion || return $?
    status 'LinkEase installation completed; refresh LuCI if its menu is missing'
}

linkease_install() {
    : "${ZSETUP_BIN:?zsetup is required}" "${ZSETUP_SOURCE_BASES:?source group is required}"
    linkease_parse_args "$@" || return $?
    os=${ZSETUP_OS:-$("$ZSETUP_BIN" context get os)}
    package_manager=${ZSETUP_PACKAGE_MANAGER:-$("$ZSETUP_BIN" context get package_manager)}
    arch=${ZSETUP_ARCH:-$("$ZSETUP_BIN" context get arch)}
    case "$arch" in x86_64|aarch64|armv7) ;; *) linkease_error "unsupported architecture: $arch"; return 2 ;; esac
    case "$os:$package_manager" in
        openwrt:opkg) business_platform=openwrt ;;
        ubuntu:apt|debian:apt|centos:yum|centos:dnf|rhel:yum|rhel:dnf|linux:*) business_platform=linux ;;
        *) linkease_error "unsupported platform: $os/$package_manager"; return 2 ;;
    esac
    INSTALLER_REMOTE_APP=LinkEase
    if [ "$business_platform" = linux ]; then
        [ -z "${LINKEASE_APP_DIR:-}" ] || { linkease_error 'LINKEASE_APP_DIR is retired; use --installer-prefix for the protected installation root'; return 2; }
        ip_uid=$("$ZSETUP_BIN" storage / get effective_uid) || return 12
        if [ "$ip_uid" != 0 ]; then installer_privilege_install linkease "$@"; return $?; fi
        installer_service_prepare linkease || return $?
        linkease_linux || return $?
        installer_transaction_finish
        return $?
    fi
    installer_package_prepare linkease || return $?
    linkease_openwrt || return $?
    PACKAGE_PHASE=complete
    installer_transaction_finish
}
