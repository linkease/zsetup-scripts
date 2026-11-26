# Reviewed product sizes for the systemd service transaction.
# Keep product selection in a subshell: service policy must not change the
# process-mode selector's state. Historical explicit versions use old ceilings.
ddnsto_linux_storage_policy() {
    dl_sizes=$(ddnsto_process_product_metadata "${LINUX_VARIANT:-standard}" &&
        printf '%s %s\n' "$PROCESS_DOWNLOAD_BYTES" "$PROCESS_EXPANDED_BYTES") || return 11
    set -- $dl_sizes
    [ "$#" = 2 ] || return 11
    INSTALLER_MAX_DOWNLOAD=$1
    INSTALLER_RESERVE=8388608
    if [ "${LINUX_VARIANT:-standard}" = zig ]; then
        INSTALLER_RESERVE=1048576
        set -- "$1" "$1"
    fi
    # Block rounding and 256 KiB for wrapper/config/receipts. Count extraction
    # and candidate separately; old committed binaries are retained, not copied.
    INSTALLER_MAX_EXPANDED=$(( (($2 + 4095) / 4096) * 4096 + 262144 ))
    INSTALLER_MAX_FILES=16
    installer_space_budget "$INSTALLER_MAX_DOWNLOAD" "$INSTALLER_MAX_EXPANDED" "$INSTALLER_MAX_EXPANDED" 0
    [ "${LINUX_VARIANT:-standard}" != zig ] || INSTALLER_REQUIRED_BYTES=$((INSTALLER_REQUIRED_BYTES - 8388608 + INSTALLER_RESERVE))
}
