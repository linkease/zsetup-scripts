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

kspeeder_binary_install() {
    kp_app=$1; shift
    [ "$#" = 0 ] || {
        printf '%s: this entry installs a binary only; invoke the installed command separately.\n' "$kp_app" >&2
        return 2
    }
    : "${ZSETUP_BIN:?zsetup is required}"
    [ "$(uname -s)" = Linux ] || return 2
    case "${ZSETUP_OS:-$("$ZSETUP_BIN" context get os)}" in
        linux|ubuntu|debian|centos|rhel) ;;
        *) echo 'KSpeeder products: this entry supports ordinary Linux; OpenWrt uses its package workflow.' >&2; return 2 ;;
    esac
    case "${ZSETUP_ARCH:-$("$ZSETUP_BIN" context get arch)}" in
        x86_64) kp_arch=amd64 ;;
        aarch64) kp_arch=arm64 ;;
        armv7) kp_arch=arm ;;
        *) echo 'KSpeeder products: unsupported architecture' >&2; return 2 ;;
    esac
    [ "${installer_scope:-user}" = user ] || {
        echo 'KSpeeder products: use user scope; system service installation is a separate workflow.' >&2
        return 2
    }
    # Installer sources and product sources have different owners. Product URLs
    # are the existing business release, never inferred from bootstrap mirrors.
    ZSETUP_SOURCE_BASES=${KSPEEDER_PRODUCT_BASES:-https://kspeeder.com}
    ZSETUP_SOURCE_FALLBACK=${KSPEEDER_PRODUCT_FALLBACK:-}
    INSTALLER_REMOTE_APP=bin
    INSTALLER_VERIFY_CACHE=1
    installer_launcher_prepare "$kp_app" user || return $?
    case "$kp_app" in
        ks-cli) kp_metadata=ks-cli-version.txt; kp_filename="ks-cli-linux-$kp_arch" ;;
        kspeeder) kp_metadata=version.txt; kp_filename="iStoreEnhance-linux.$kp_arch" ;;
        *) return 2 ;;
    esac
    status "[2/4] Checking $kp_app release metadata..."
    installer_download "$kp_metadata" "$transaction_dir/version" '' 1 || return $?
    kp_version=$("$ZSETUP_BIN" metadata version "$transaction_dir/version" VERSION) || return $?
    kp_sha=$("$ZSETUP_BIN" metadata sha256 "$transaction_dir/version" "SHA256_linux_$kp_arch") || return $?
    installer_launcher_activate "$kp_version" "$kp_filename" "$kp_sha" kspeeder_product_verify || return $?
    installer_transaction_finish || return $?
    status "[4/4] Installed $kp_app $kp_version"
    printf 'application=%s\nversion=%s\ncommand=%s\nprefix=%s\n' \
        "$kp_app" "$kp_version" "$INSTALLER_COMMAND" "$INSTALLER_PREFIX"
    status 'No service was registered or started. Invoke the installed command explicitly.'
}

kspeeder_binary_help() {
    printf '%s\n' "Usage: $1-install.sh [--installer-prefix ABSOLUTE_DIRECTORY] [--installer-work-dir ABSOLUTE_DIRECTORY]" \
        'Installs and verifies the binary in user scope; does not run business commands or install a service.' \
        'Default command: $HOME/.local/bin/APP; default prefix: $HOME/.local/lib/linkease/APP.'
}
