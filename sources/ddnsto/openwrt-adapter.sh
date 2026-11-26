# OpenWrt owns its package files and procd service, not a Linux systemd unit.
# Native packages expand directly into their package-owned destinations. They
# do not create the extra expanded service candidate used by the Linux binary
# transaction. Keep the existing 32 MiB download / 64 MiB expansion ceilings,
# allow one extra compressed copy for package-manager scratch/cache, and retain
# the common 10% margin + 8 MiB reserve (148.8 MiB total, rather than 184 MiB).
# These are conservative bounds, not claims about an individual package size.
ddnsto_openwrt_package_policy() {
    [ "$1" = ddnsto ] || return 2
    INSTALLER_DOWNLOAD_BYTES=0; INSTALLER_EXPANDED_BYTES=0; INSTALLER_FILE_COUNT=0
    INSTALLER_RESERVE=8388608
    INSTALLER_MAX_DOWNLOAD=33554432; INSTALLER_MAX_EXPANDED=67108864; INSTALLER_MAX_FILES=16
    installer_space_budget "$INSTALLER_MAX_DOWNLOAD" "$INSTALLER_MAX_EXPANDED" "$INSTALLER_MAX_DOWNLOAD" 0
}

# Only curated storage facts reach the human result; do not capture arbitrary
# child stdout/stderr (package hooks may print credentials). Shared helpers and
# other applications keep their original policy and diagnostics.
ddnsto_openwrt_storage_error() {
    ow_storage_code=E_STORAGE
    case "$*" in
        'insufficient space at '*)
            ow_storage_code=E_SPACE
            ow_storage_reason="路径 $is_path 可用空间不足：需要 $is_needed 字节，可用 $is_available 字节" ;;
        'memory filesystem at '*) ow_storage_reason="路径 $is_path 位于内存文件系统，不能作为持久安装目录" ;;
        'cannot establish persistent backing at '*) ow_storage_reason="无法确认路径 $is_path 的持久存储类型" ;;
        'read-only or unknown mount at '*) ow_storage_reason="路径 $is_path 只读或无法确认挂载读写状态" ;;
        'execution is unavailable at '*) ow_storage_reason="路径 $is_path 不允许执行程序或无法确认执行权限" ;;
        'write permission is required at '*) ow_storage_reason="路径 $is_path 不可写或无法确认写权限" ;;
        'no free inodes at '*) ow_storage_reason="路径 $is_path 的可用 inode 为 0，无法确认是否还能创建文件" ;;
        'inode availability is unknown at '*) return 0 ;;
        *) ow_storage_reason='无法完成安装目录存储检查（路径、权限或 zsetup 存储探测异常）' ;;
    esac
    if command -v ddnsto_flow_error >/dev/null 2>&1; then
        ddnsto_flow_error "$ow_storage_code" "$ow_storage_reason" '请保留诊断记录，检查对应存储及权限；不要删除 DDNSTO 配置或放宽目录权限' || :
    else
        printf 'DDNSTO [%s]：%s\n' "$ow_storage_code" "$ow_storage_reason" >&2
    fi
}

ddnsto_openwrt_prepare() {
    # The process is already committed to the OpenWrt adapter. Replace only its
    # policy/error callbacks; the common package transaction remains unchanged.
    installer_policy() { ddnsto_openwrt_package_policy "$@"; }
    installer_storage_error() { ddnsto_openwrt_storage_error "$@"; }
    ow_storage_reason=
    if command -v ddnsto_flow_note >/dev/null 2>&1; then ddnsto_flow_note checking; fi
    ow_prepare_rc=0
    installer_package_prepare ddnsto || ow_prepare_rc=$?
    if [ "$ow_prepare_rc" != 0 ]; then
        if [ "$ow_prepare_rc" = 12 ] && [ -z "$ow_storage_reason" ]; then
            ddnsto_openwrt_storage_error 'package preparation failed'
        fi
        return "$ow_prepare_rc"
    fi
    if command -v ddnsto_flow_note >/dev/null 2>&1; then ddnsto_flow_note installing; fi
}

ddnsto_openwrt_paths() {
    binary=${DDNSTO_OPENWRT_BIN_PATH:-/usr/sbin/ddnstod}
    config=${DDNSTO_CONFIG_PATH:-/etc/config/ddnsto}
    service_path=${DDNSTO_SERVICE_PATH:-/etc/init.d/ddnsto}
}

ddnsto_openwrt_protected() {
    for ow_target in "$binary" "$config" "$service_path"; do
        ddnsto_ow_safe_path "$ow_target" || return 2
        ddnsto_bootstrap_safe_ancestors "${ow_target%/*}" || return 12
        [ -f "$ow_target" ] && [ "$(ddnsto_stat -c %u "$ow_target")" = "$(id -u)" ] || return 2
        ow_mode=$(ddnsto_stat -c %a "$ow_target") || return 12
        [ "$((0$ow_mode & 0022))" = 0 ] || return 12
        ddnsto_ow_owned "$ow_target" || return 2
    done
    ow_bytes=$(wc -c < "$config") || return 12
    [ "$ow_bytes" -le 16384 ] || return 11
}

ddnsto_openwrt_preflight() {
    ddnsto_openwrt_paths
    DDNSTO_OW_RETAINED=0
    if [ "${ACTION:-install}" = update ]; then
        ddnsto_openwrt_protected || return 2
        if command -v ddnsto_ensure_ow_locked >/dev/null 2>&1; then
            ddnsto_ensure_ow_locked || return $?
        fi
        return 0
    fi
    ow_packages=$(ddnsto_ow_packages) || return 2
    if ddnsto_ow_has_package ddnsto; then
        ddnsto_error 'DDNSTO package already registered; use update or configure'; return 2
    fi
    if [ -e "$config" ] || [ -L "$config" ]; then
        ddnsto_openwrt_retained_state_valid && [ -z "$TOKEN" ] || {
            ddnsto_error 'existing OpenWrt configuration: use update or configure; automatic rebinding refused'; return 2;
        }
        [ ! -e "$binary" ] && [ ! -L "$binary" ] && [ ! -e "$service_path" ] && [ ! -L "$service_path" ] || return 2
        ddnsto_bootstrap_safe_ancestors "${config%/*}" || return 12
        [ "$(ddnsto_stat -c %u "$config")" = "$(id -u)" ] || return 2
        ow_mode=$(ddnsto_stat -c %a "$config") || return 12
        [ "$((0$ow_mode & 0022))" = 0 ] || return 12
        DDNSTO_OW_RETAINED=1
    fi
}

# Called under the same machine lease as package installation. No downloads or
# zsetup are needed to operate an already installed OpenWrt package.
ddnsto_openwrt_local() {
    ddnsto_openwrt_paths
    case "$ACTION" in status|start|stop|restart|repair|configure|uninstall) ;; *) return 2 ;; esac
    ddnsto_openwrt_protected || { ddnsto_error 'complete protected package-owned OpenWrt installation required'; return 2; }
    if [ "$ACTION" = status ]; then
        ow_status=0
        "$service_path" status >/dev/null 2>&1 || ow_status=$?
        case "$ow_status" in 0) ow_state=running ;; 1|3) ow_state=stopped ;; *) return 13 ;; esac
        printf 'local_service=%s cloud_status=unverified\n' "$ow_state"
        return 0
    fi
    if [ "$ACTION" = configure ] && [ -z "$TOKEN" ]; then
        TOKEN=$(ddnsto_prompt_token) || return $?
    fi
    ddnsto_openwrt_lifecycle
}

# All artifacts have already passed the shared bounded downloader. Preserve
# UCI bytes before package hooks, including disabled state and identity fields.
ddnsto_openwrt_apply() {
    ddnsto_openwrt_paths
    if [ -e "$config" ] || [ -L "$config" ]; then
        [ "${ACTION:-install}" = update ] || [ "${DDNSTO_OW_RETAINED:-0}" = 1 ] || {
            ddnsto_error 'existing OpenWrt configuration: use update or configure; automatic rebinding refused'; return 2;
        }
        if [ "${DDNSTO_OW_RETAINED:-0}" = 1 ]; then
            ddnsto_openwrt_retained_state_valid || return 2
        else ddnsto_openwrt_protected || return 2; fi
        ddnsto_openwrt_with_retained_config ddnsto_openwrt_apply_packages || return $?
        ddnsto_openwrt_resume_config || return $?
        if [ "${DDNSTO_OW_RETAINED:-0}" = 1 ]; then
            ddnsto_openwrt_retained_state_valid || return 2
            rm -f "${config%/*}/.uninstalled-openwrt-v1" || return 12
        fi
    else
        [ "${ACTION:-install}" = install ] || { ddnsto_error 'update requires existing configuration'; return 2; }
        # Missing files must not authorize replacing a registered foreign or
        # damaged installation. Recovery must be inspected explicitly.
        ow_packages=$(ddnsto_ow_packages) || return 2
        if ddnsto_ow_has_package ddnsto; then return 2; fi
        ddnsto_openwrt_apply_packages || return $?
        if [ -n "$TOKEN" ]; then
            ( ACTION=configure; ddnsto_openwrt_local ) || return $?
        fi
    fi
    if [ "${VERIFY_STATUS:-0}" = 1 ]; then
        ddnsto_ow_wait_service running || return 13
        "$binary" -w >/dev/null 2>&1 || return 13
    fi
    printf 'operation=%s config=retained cloud_status=unverified\n' "$ACTION"
}
