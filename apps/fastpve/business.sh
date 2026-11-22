# Only the launcher belongs here; PVE menus/actions remain in FastPVE.
fastpve_install() {
    : "${ZSETUP_BIN:?zsetup is required}" "${ZSETUP_SOURCE_BASES:?source group is required}"
    fp_arch=${ZSETUP_ARCH:-$("$ZSETUP_BIN" context get arch)}
    fp_pm=${ZSETUP_PACKAGE_MANAGER:-$("$ZSETUP_BIN" context get package_manager)}
    if [ "$fp_arch" != x86_64 ] || [ "$fp_pm" != apt ]; then
        echo 'FastPVE: requires x86_64 PVE with apt' >&2; return 2
    fi
    if ! command -v pveversion >/dev/null 2>&1 || ! pveversion >/dev/null 2>&1; then
        echo 'FastPVE: a working Proxmox VE installation is required' >&2; return 2
    fi
    if [ "$(id -u)" != 0 ]; then echo 'FastPVE: run as root on the PVE host' >&2; return 2; fi
    [ "${installer_scope:-system}" != user ] || { echo 'FastPVE: user mode is unsupported' >&2; return 2; }
    INSTALLER_REMOTE_APP=fastpve
    installer_launcher_prepare fastpve system || return $?
    status '[2/4] Checking FastPVE version...'
    installer_download version.txt "$transaction_dir/version" '' 1 || return $?
    fp_version=$("$ZSETUP_BIN" metadata version "$transaction_dir/version" VERSION) || return $?
    fp_digest=$("$ZSETUP_BIN" metadata sha256 "$transaction_dir/version" FASTPVE_SHA256) || return $?
    installer_launcher_activate "$fp_version" "FastPVE-$fp_version" "$fp_digest" || return $?
    installer_transaction_finish || return $?
    status '[4/4] Starting FastPVE...'
    exec "$INSTALLER_EXECUTABLE" "$@"
}
