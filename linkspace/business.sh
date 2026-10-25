# Linkspace product binaries are published by apptunnel, never bundled here.
linkspace_install() {
    : "${ZSETUP_BIN:?zsetup is required}" "${ZSETUP_SOURCE_BASES:?source group is required}"
    [ "$(uname -s)" = Linux ] || return 2
    case "${ZSETUP_ARCH:-$("$ZSETUP_BIN" context get arch)}" in
        x86_64|amd64) ls_arch=amd64; ls_key=AMD64 ;;
        aarch64|arm64) ls_arch=arm64; ls_key=ARM64 ;;
        armv7|armv7l) ls_arch=armv7; ls_key=ARMV7 ;;
        *) echo 'Linkspace: unsupported architecture' >&2; return 2 ;;
    esac
    [ "${installer_scope:-user}" = user ] || { echo 'Linkspace: use user scope' >&2; return 2; }
    INSTALLER_REMOTE_APP=linkspace
    INSTALLER_VERIFY_CACHE=1
    installer_launcher_prepare linkspace user || return $?
    status '[2/4] Checking Linkspace version...'
    installer_download version.txt "$transaction_dir/version" '' 1 || return $?
    ls_version=$("$ZSETUP_BIN" metadata version "$transaction_dir/version" VERSION) || return $?
    ls_sha=$("$ZSETUP_BIN" metadata sha256 "$transaction_dir/version" "LINKSPACE_${ls_key}_SHA256") || return $?
    INSTALLER_EXPECTED_SIZE=$("$ZSETUP_BIN" metadata version "$transaction_dir/version" "LINKSPACE_${ls_key}_SIZE") || return $?
    case "$INSTALLER_EXPECTED_SIZE" in ''|0|0*|*[!0-9]*) return 11 ;; esac
    [ "${#INSTALLER_EXPECTED_SIZE}" -le 8 ] && [ "$INSTALLER_EXPECTED_SIZE" -le "$INSTALLER_MAX_DOWNLOAD" ] || return 11
    installer_launcher_activate "$ls_version" "$ls_version/linkspace-linux-$ls_arch" "$ls_sha" || return $?
    installer_transaction_finish || return $?
    status '[4/4] Starting Linkspace...'
    exec "$INSTALLER_EXECUTABLE" "$@"
}
