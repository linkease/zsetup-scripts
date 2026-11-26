# Product choice for the Linux user process adapter only. No package managers
# or systemd installs use this fallback. Mutable raw URLs remain digest/size
# pinned: a CDN update requires reviewed product metadata, never blind execution.
ddnsto_process_product_budget() {
    PROCESS_RESERVE=8388608
    [ "$PROCESS_VARIANT" != zig ] || PROCESS_RESERVE=1048576
    process_budget_sum=$((PROCESS_DOWNLOAD_BYTES + PROCESS_EXPANDED_BYTES + process_backup_bytes + 262144))
    PROCESS_REQUIRED_BYTES=$((process_budget_sum + (process_budget_sum + 9) / 10 + PROCESS_RESERVE))
}

ddnsto_process_product_plan() {
    ddnsto_process_product_metadata standard || return $?
    process_backup_bytes=0
    if [ -f "$PROCESS_PREFIX/ddnsto" ]; then
        installer_file_size "$PROCESS_PREFIX/ddnsto" || return 11
        [ "$INSTALLER_FILE_SIZE" -le 134217728 ] || return 11
        process_backup_bytes=$INSTALLER_FILE_SIZE
    fi
    ddnsto_process_product_budget
    process_available=$("$ZSETUP_BIN" storage "$PROCESS_PREFIX" get available_bytes) || return 12
    case "$process_available" in ''|*[!0-9]*)
        ddnsto_process_error E_STORAGE '无法确认客户端目录可用空间'; return 12 ;;
    esac
    if [ "${FORCE_VERSION:-}" = lite ] || [ "$process_available" -lt "$PROCESS_REQUIRED_BYTES" ]; then
        if [ "${FORCE_VERSION:-}" = standard ]; then
            ddnsto_process_error E_SPACE '空间不足以安装明确指定的 standard，不自动替换'; return 12
        fi
        if [ "${BUSINESS_ENV:-production}" != production ] || [ "${SWITCH_ENVIRONMENT:-0}" = 1 ]; then
            ddnsto_process_error E_SPACE 'standard 空间不足；Zig 尚未验证测试环境切换能力，未替换客户端'; return 12
        fi
        ddnsto_process_product_metadata zig || return $?
        if [ -n "${PROCESS_OLD_VERSION:-}" ]; then
            process_order=$(ddnsto_version_order "$PROCESS_OLD_VERSION" "$PROCESS_VERSION") || return 11
            [ "$process_order" != 1 ] || {
                ddnsto_process_error E_SPACE 'standard 空间不足，已发布 Zig 版本低于当前安装；不会自动降级'; return 12;
            }
            if [ "$process_order" = 0 ] && [ "${PROCESS_OLD_DIGEST:-}" = "$PROCESS_DIGEST" ] &&
                [ "${PROCESS_OLD_ENV:-production}" = "${BUSINESS_ENV:-production}" ]; then
                # Already-installed verified product: starting it is not a new
                # download/backup transaction, even when free space is now low.
                PROCESS_REQUIRED_BYTES=0
                printf '%s\n' 'DDNSTO：保留当前 Zig 客户端，无需重新下载。' >&2
                return 0
            fi
        fi
        ddnsto_process_product_budget
    fi
    if [ "$process_available" -lt "$PROCESS_REQUIRED_BYTES" ]; then
        ddnsto_process_error E_SPACE "客户端目录需要 $PROCESS_REQUIRED_BYTES 字节，可用 $process_available 字节"; return 12
    fi
    printf 'DDNSTO：选择 %s %s；空间预算 %s 字节，可用 %s 字节。\n' \
        "$PROCESS_VARIANT" "$PROCESS_VERSION" "$PROCESS_REQUIRED_BYTES" "$process_available" >&2
}

ddnsto_process_product_policy() {
    INSTALLER_REMOTE_APP=ddnsto
    INSTALLER_DOWNLOAD_BYTES=0; INSTALLER_EXPANDED_BYTES=0; INSTALLER_FILE_COUNT=0
    INSTALLER_RESERVE=$PROCESS_RESERVE
    INSTALLER_MAX_DOWNLOAD=$PROCESS_DOWNLOAD_BYTES
    INSTALLER_MAX_EXPANDED=$PROCESS_EXPANDED_BYTES
    INSTALLER_MAX_FILES=1
    INSTALLER_REQUIRED_BYTES=$PROCESS_REQUIRED_BYTES
}
