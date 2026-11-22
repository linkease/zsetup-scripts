# Shared product policy. Download, bounded capture, storage and process ownership
# remain in canonical zsetup and the shared installer helpers.
kspeeder_product_verify() {
    installer_exec_native "$ZSETUP_BIN" capture -o "$transaction_dir/product-version" \
        --max-bytes 1024 --timeout 10s -- "$1" version || return $?
    kp_reported=; kp_build=
    IFS=' ' read -r kp_reported kp_build < "$transaction_dir/product-version" || return 11
    [ "$kp_reported" = "$2" ] || {
        printf 'KSpeeder product: expected version %s, executable reported %s\n' "$2" "$kp_reported" >&2
        return 11
    }
}

kspeeder_product_checksum() {
    kp_checksum_file=$1
    kp_checksum_name=$2
    kp_checksum_count=0
    kp_sha=
    while IFS=' ' read -r kp_digest kp_name kp_extra; do
        kp_name=${kp_name#\*}
        [ "$kp_name" = "$kp_checksum_name" ] || continue
        kp_checksum_count=$((kp_checksum_count + 1))
        [ -z "${kp_extra:-}" ] || return 11
        case "$kp_digest" in *[!0123456789abcdef]*|'') return 11 ;; esac
        [ "${#kp_digest}" = 64 ] || return 11
        kp_sha=$kp_digest
    done < "$kp_checksum_file"
    [ "$kp_checksum_count" = 1 ] && [ -n "$kp_sha" ] || return 11
}

kspeeder_product_release() {
    kp_release_file=$1
    kp_version=; kp_release=
    kp_version_count=0; kp_release_count=0
    while IFS='=' read -r kp_key kp_value kp_extra; do
        [ -z "${kp_extra:-}" ] || return 11
        case "$kp_key" in
            VERSION) kp_version_count=$((kp_version_count + 1)); kp_version=$kp_value ;;
            RELEASE) kp_release_count=$((kp_release_count + 1)); kp_release=$kp_value ;;
            *) return 11 ;;
        esac
    done < "$kp_release_file"
    [ "$kp_version_count" = 1 ] && [ "$kp_release_count" = 1 ] || return 11
    kp_major=${kp_version%%.*}; kp_rest=${kp_version#*.}
    [ "$kp_rest" != "$kp_version" ] || return 11
    kp_minor=${kp_rest%%.*}; kp_patch=${kp_rest#*.}
    [ "$kp_patch" != "$kp_rest" ] || return 11
    [ -n "$kp_major" ] && [ -n "$kp_minor" ] && [ -n "$kp_patch" ] || return 11
    case "$kp_major:$kp_minor:$kp_patch" in *[!0-9:]*) return 11 ;; esac
    [ "${#kp_release}" = 64 ] || return 11
    case "$kp_release" in *[!0123456789abcdef]*|'') return 11 ;; esac
}

kspeeder_binary_install() {
    kp_app=$1; shift
    [ "$#" = 0 ] || {
        printf '%s: this entry installs a binary only; invoke the installed command separately.\n' "$kp_app" >&2
        return 2
    }
    : "${ZSETUP_BIN:?zsetup is required}"
    kp_kernel=$(uname -s)
    case "${ZSETUP_OS:-$("$ZSETUP_BIN" context get os)}" in
        linux|ubuntu|debian|centos|rhel)
            [ "$kp_kernel" = Linux ] || return 2
            kp_os=linux ;;
        darwin|macos)
            [ "$kp_kernel" = Darwin ] || return 2
            kp_os=mac ;;
        *) echo 'KSpeeder products: this entry supports ordinary Linux and macOS; OpenWrt uses its package workflow.' >&2; return 2 ;;
    esac
    case "${ZSETUP_ARCH:-$("$ZSETUP_BIN" context get arch)}" in
        x86_64) kp_arch=amd64 ;;
        aarch64) kp_arch=arm64 ;;
        armv7) kp_arch=arm ;;
        *) echo 'KSpeeder products: unsupported architecture' >&2; return 2 ;;
    esac
    [ "$kp_os" != mac ] || [ "$kp_arch" != arm ] || {
        echo 'KSpeeder products: macOS supports x86_64 and arm64 only' >&2
        return 2
    }
    [ "${installer_scope:-user}" = user ] || {
        echo 'KSpeeder products: use user scope; system service installation is a separate workflow.' >&2
        return 2
    }
    # Product bytes are mirrored as one versioned release below
    # /binary/kspeeder. Explicit overrides retain the old flat layout for
    # controlled tests or emergency source selection.
    if [ "${KSPEEDER_PRODUCT_BASES+x}" = x ]; then
        ZSETUP_SOURCE_BASES=$KSPEEDER_PRODUCT_BASES
        ZSETUP_SOURCE_FALLBACK=${KSPEEDER_PRODUCT_FALLBACK:-}
        kp_product_root=${KSPEEDER_PRODUCT_ROOT:-bin}
        kp_versioned=${KSPEEDER_PRODUCT_VERSIONED:-0}
    else
        ZSETUP_SOURCE_BASES='https://dl.istoreos.com/binary https://fw.d4ctech.com/binary https://fw20.koolcenter.com/binary'
        ZSETUP_SOURCE_FALLBACK='https://fw.koolcenter.com/binary'
        kp_product_root=kspeeder
        kp_versioned=1
    fi
    case "$kp_product_root" in ''|/*|*..*|*\\*|*' '*) echo 'KSpeeder products: unsafe product source path' >&2; return 2 ;; esac
    case "$kp_versioned" in 0|1) ;; *) echo 'KSpeeder products: invalid product layout' >&2; return 2 ;; esac
    INSTALLER_REMOTE_APP=$kp_product_root
    INSTALLER_VERIFY_CACHE=1
    installer_launcher_prepare "$kp_app" user || return $?
    case "$kp_app" in
        ks-cli)
            kp_metadata=ks-cli-version.txt
            kp_filename="ks-cli-$kp_os-$kp_arch" ;;
        kspeeder)
            kp_metadata=version.txt
            if [ "$kp_os" = mac ]; then kp_filename="iStoreEnhance-mac.$kp_arch"
            else kp_filename="iStoreEnhance-linux.$kp_arch"; fi ;;
        *) return 2 ;;
    esac
    status "[2/4] Checking $kp_app release metadata..."
    if [ "$kp_versioned" = 1 ]; then
        installer_download release.txt "$transaction_dir/release" '' 1 || return $?
        kspeeder_product_release "$transaction_dir/release" || return $?
        INSTALLER_REMOTE_APP=$kp_product_root/releases/$kp_release
        installer_download SHA256SUMS "$transaction_dir/product-SHA256SUMS" '' 1 || return $?
        kspeeder_product_checksum "$transaction_dir/product-SHA256SUMS" "$kp_filename" || return $?
    else
        installer_download "$kp_metadata" "$transaction_dir/version" '' 1 || return $?
        kp_version=$("$ZSETUP_BIN" metadata version "$transaction_dir/version" VERSION) || return $?
        kp_sha=$("$ZSETUP_BIN" metadata sha256 "$transaction_dir/version" "SHA256_${kp_os}_$kp_arch") || return $?
    fi
    installer_launcher_activate "$kp_version" "$kp_filename" "$kp_sha" kspeeder_product_verify || return $?
    installer_transaction_finish || return $?
    status "[4/4] Installed $kp_app $kp_version"
    printf 'application=%s\nversion=%s\ncommand=%s\nprefix=%s\n' \
        "$kp_app" "$kp_version" "$INSTALLER_COMMAND" "$INSTALLER_PREFIX"
    status 'No service was registered or started. Invoke the installed command explicitly.'
}

kspeeder_binary_help() {
    printf '%s\n' "Usage: $1-install.sh [--installer-prefix ABSOLUTE_DIRECTORY] [--installer-work-dir ABSOLUTE_DIRECTORY]" \
        'Installs and verifies the Linux/macOS binary in user scope; does not run business commands or install a service.' \
        'Default command: $HOME/.local/bin/APP; default prefix: $HOME/.local/lib/linkease/APP.'
}
