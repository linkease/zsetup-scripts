# OpenWrt owns its package files and procd service, not a Linux systemd unit.
# Plan from reviewed, digest-bound package sizes before the common transaction.
# Include all three packages, a compressed PM scratch copy, 4 MiB for package
# database/config/metadata work, and the shared 10% + 8 MiB reserve. With proven
# tmpfs scratch, persistent storage excludes downloads; temporary storage keeps
# the full peak. Existing files/caches reduce free space; never credit deletion.
ddnsto_openwrt_budget() {
    version_num=$(ddnsto_pinned_version "$SELECTED_VERSION") || return $?
    version_folder=$SELECTED_VERSION
    [ "$pkg_ext" != apk ] || version_folder="$version_folder-apk"
    relative_folder="openwrt/$version_folder/$version_num"
    main_package="ddnsto_$package_arch.$pkg_ext"
    ui_package="luci-app-ddnsto.$pkg_ext"
    language_package="luci-i18n-ddnsto-zh-cn.$pkg_ext"
    OW_DOWNLOAD_BYTES=0; OW_EXPANDED_BYTES=0
    for ow_budget_path in "$relative_folder/$main_package" "openwrt/$ui_package" "openwrt/$language_package"; do
        ow_sizes=$(ddnsto_pinned_package_sizes "$ow_budget_path") || return 11
        set -- $ow_sizes
        [ "$#" = 2 ] || return 11
        for ow_size in "$@"; do
            case "$ow_size" in ''|0*|*[!0-9]*) return 11 ;; esac
            [ "${#ow_size}" -le 9 ] && [ "$ow_size" -le 134217728 ] || return 11
        done
        OW_DOWNLOAD_BYTES=$((OW_DOWNLOAD_BYTES + $1))
        OW_EXPANDED_BYTES=$((OW_EXPANDED_BYTES + $2))
    done
    installer_space_budget "$OW_DOWNLOAD_BYTES" "$OW_EXPANDED_BYTES" "$OW_DOWNLOAD_BYTES" 4194304 || return $?
    OW_REQUIRED_BYTES=$INSTALLER_REQUIRED_BYTES
    OW_TEMP_REQUIRED_BYTES=$OW_REQUIRED_BYTES
    if [ "${OW_TMP_MODE:-0}" = 1 ]; then
        installer_space_budget 0 "$OW_EXPANDED_BYTES" 0 4194304 || return $?
        OW_REQUIRED_BYTES=$INSTALLER_REQUIRED_BYTES
    fi
}

ddnsto_openwrt_plan() {
    OW_TMP_MODE=0
    # Custom work paths retain their established persistent-storage contract.
    # Only a proven separate memory filesystem receives the split budget.
    if [ -z "${installer_work_dir:-${ZSETUP_WORK_DIR:-}}" ] &&
        [ "$("$ZSETUP_BIN" storage /tmp get memory_backed 2>/dev/null)" = true ]; then
        OW_TMP_MODE=1
    fi
    case "$package_manager" in opkg) pkg_ext=ipk ;; apk) pkg_ext=apk ;; *) return 2 ;; esac
    case "$arch" in
        x86_64|aarch64|mipsel) package_arch=$arch ;;
        armv7|arm) package_arch=arm ;;
        *) return 2 ;;
    esac
    SELECTED_VERSION=${FORCE_VERSION:-}
    if [ -z "$SELECTED_VERSION" ]; then
        mem_mb=${DDNSTO_MEM_MB:-${ZSETUP_MEMORY_TOTAL_MB:-$("$ZSETUP_BIN" context get memory_total_mb)}}
        case "$mem_mb" in ''|*[!0-9]*) mem_mb=0 ;; esac
        if [ "$mem_mb" -gt 0 ] && [ "$mem_mb" -lt 900 ]; then SELECTED_VERSION=lite; else SELECTED_VERSION=standard; fi
    fi
    case "$SELECTED_VERSION" in lite|standard) ;; *) return 2 ;; esac
    ddnsto_openwrt_budget || return $?
    ow_available=$("$ZSETUP_BIN" storage / get available_bytes) || return 12
    case "$ow_available" in ''|*[!0-9]*)
        ddnsto_openwrt_storage_error 'available space is unknown'; return 12 ;;
    esac
    ow_tmp_available=$OW_TEMP_REQUIRED_BYTES
    if [ "$OW_TMP_MODE" = 1 ]; then
        ow_tmp_available=$("$ZSETUP_BIN" storage /tmp get available_bytes) || return 12
        case "$ow_tmp_available" in ''|*[!0-9]*) ddnsto_openwrt_storage_error 'temporary space unknown'; return 12 ;; esac
    fi
    if { [ "$ow_available" -lt "$OW_REQUIRED_BYTES" ] || [ "$ow_tmp_available" -lt "$OW_TEMP_REQUIRED_BYTES" ]; } &&
        [ -z "${FORCE_VERSION:-}" ] && [ "$SELECTED_VERSION" = standard ]; then
        ow_standard_required=$OW_REQUIRED_BYTES
        ow_standard_temp=$OW_TEMP_REQUIRED_BYTES
        SELECTED_VERSION=lite
        ddnsto_openwrt_budget || return $?
        if [ "$OW_REQUIRED_BYTES" -lt "$ow_standard_required" ] &&
            [ "$OW_TEMP_REQUIRED_BYTES" -le "$ow_standard_temp" ]; then
            printf '%s\n' 'DDNSTO：安装空间不足以使用 standard，正在检查 lite 安装包…' >&2
        else
            # The 4.2.8 exception means lite is not smaller on every architecture.
            SELECTED_VERSION=standard
            ddnsto_openwrt_budget || return $?
        fi
    fi
    if [ "$ow_available" -lt "$OW_REQUIRED_BYTES" ]; then
        is_path=/; is_needed=$OW_REQUIRED_BYTES; is_available=$ow_available
        ddnsto_openwrt_storage_error 'insufficient space at /'
        return 12
    fi
    if [ "$OW_TMP_MODE" = 1 ]; then
        if [ "$ow_tmp_available" -lt "$OW_TEMP_REQUIRED_BYTES" ]; then
            is_path=/tmp; is_needed=$OW_TEMP_REQUIRED_BYTES; is_available=$ow_tmp_available
            ddnsto_openwrt_storage_error 'insufficient space at /tmp'; return 12
        fi
        printf 'DDNSTO：临时空间预算 %s 字节，可用 %s 字节（/tmp）；下载缓存不占用闪存。\n' "$OW_TEMP_REQUIRED_BYTES" "$ow_tmp_available" >&2
    fi
    printf 'DDNSTO：选择 %s %s；安装空间预算 %s 字节，可用 %s 字节。\n' \
        "$SELECTED_VERSION" "$version_num" "$OW_REQUIRED_BYTES" "$ow_available" >&2
}

ddnsto_openwrt_package_preflight() {
    if [ "${OW_TMP_MODE:-0}" != 1 ]; then
        installer_package_persistent_preflight "$@"; return $?
    fi
    installer_storage_check "$INSTALLER_PREFIX" "$OW_REQUIRED_BYTES" 1 1 || return $?
    [ "$("$ZSETUP_BIN" storage "$INSTALLER_PREFIX" get system_protected)" = true ] || return 12
    ddnsto_bootstrap_safe_ancestors /tmp || return 12
    installer_storage_check /tmp "$OW_TEMP_REQUIRED_BYTES" 1 1 temporary || return $?
    # Fixed private root preserves verified recovery inputs across retries;
    # sticky /tmp plus root ownership prevents replacement by another user.
    INSTALLER_WORK_ROOT=/tmp/ddnsto-package-stage
    ddnsto_bootstrap_private_dir "$INSTALLER_WORK_ROOT" || return 12
    [ "$("$ZSETUP_BIN" storage "$INSTALLER_WORK_ROOT" get private_directory)" = true ] || return 12
}

ddnsto_openwrt_cache_location() {
    if [ "${OW_TMP_MODE:-0}" = 1 ]; then
        ip_cache_root="$INSTALLER_WORK_ROOT/.packages"
        [ ! -L "$ip_cache_root" ] || return 12
    else ip_cache_root="$INSTALLER_PREFIX/.packages"; fi
}

ddnsto_openwrt_cache_protected() {
    if [ "${OW_TMP_MODE:-0}" = 1 ]; then
        case "$1" in "$INSTALLER_WORK_ROOT"/.packages/*) ;; *) return 12 ;; esac
        [ ! -L "$1" ] && [ ! -L "$INSTALLER_WORK_ROOT/.packages" ] || return 12
        ddnsto_bootstrap_private_dir "$INSTALLER_WORK_ROOT" || return 12
    else [ "$("$ZSETUP_BIN" storage "$1" get system_protected)" = true ]; fi
}

ddnsto_openwrt_work_check() {
    if [ "${OW_TMP_MODE:-0}" = 1 ]; then
        installer_storage_check "$INSTALLER_WORK_ROOT" "$INSTALLER_RESERVE" 1 1 temporary
    else installer_storage_check "$INSTALLER_WORK_ROOT" "$INSTALLER_RESERVE" 0 1; fi
}

ddnsto_openwrt_package_policy() {
    [ "$1" = ddnsto ] || return 2
    INSTALLER_DOWNLOAD_BYTES=0; INSTALLER_EXPANDED_BYTES=0; INSTALLER_FILE_COUNT=0
    INSTALLER_RESERVE=8388608
    INSTALLER_MAX_DOWNLOAD=$OW_DOWNLOAD_BYTES
    INSTALLER_MAX_EXPANDED=$OW_EXPANDED_BYTES
    INSTALLER_MAX_FILES=16
    INSTALLER_REQUIRED_BYTES=$OW_REQUIRED_BYTES
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
    # policy/error and workspace callbacks; keep common locking and recovery.
    installer_policy() { ddnsto_openwrt_package_policy "$@"; }
    installer_storage_error() { ddnsto_openwrt_storage_error "$@"; }
    installer_package_preflight() { ddnsto_openwrt_package_preflight "$@"; }
    installer_package_work_check() { ddnsto_openwrt_work_check; }
    installer_package_cache_location() { ddnsto_openwrt_cache_location; }
    installer_package_cache_protected() { ddnsto_openwrt_cache_protected "$@"; }
    ow_storage_reason=
    if command -v ddnsto_flow_note >/dev/null 2>&1; then ddnsto_flow_note checking; fi
    ddnsto_openwrt_plan || return $?
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
