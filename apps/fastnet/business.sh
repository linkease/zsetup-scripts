fastnet_install() {
    : "${ZSETUP_BIN:?zsetup is required}" "${ZSETUP_SOURCE_BASES:?source group is required}"
    case "${ZSETUP_ARCH:-$(uname -m)}" in
        x86_64|amd64) arch_suffix=amd64; sha_key=FASTNET_AMD64_SHA256 ;;
        aarch64|arm64) arch_suffix=arm64; sha_key=FASTNET_ARM64_SHA256 ;;
        armv7l|armv7) arch_suffix=armv7; sha_key=FASTNET_ARMV7_SHA256 ;;
        *) echo 'FastNet: unsupported architecture' >&2; return 2 ;;
    esac
    INSTALLER_REMOTE_APP=fastnet
    installer_launcher_prepare fastnet user || return $?
    status '[2/4] Checking FastNet version...'
    installer_download version.txt "$transaction_dir/version" '' 1 || return $?
    version=$("$ZSETUP_BIN" metadata version "$transaction_dir/version" VERSION) || return $?
    expected_sha=$("$ZSETUP_BIN" metadata sha256 "$transaction_dir/version" "$sha_key") || return $?
    installer_launcher_activate "$version" "FastNet-$version.$arch_suffix" "$expected_sha" || return $?
    installer_transaction_finish || return $?
    status '[4/4] Starting FastNet...'
    exec "$INSTALLER_EXECUTABLE" "$@"
}
