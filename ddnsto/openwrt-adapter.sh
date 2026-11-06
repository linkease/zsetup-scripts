# OpenWrt owns its package files and procd service, not a Linux systemd unit.
ddnsto_openwrt_paths() {
    binary=${DDNSTO_OPENWRT_BIN_PATH:-/usr/sbin/ddnstod}
    config=${DDNSTO_CONFIG_PATH:-/etc/config/ddnsto}
    service_path=${DDNSTO_SERVICE_PATH:-/etc/init.d/ddnsto}
}

ddnsto_openwrt_protected() {
    for ow_target in "$binary" "$config" "$service_path"; do
        ddnsto_ow_safe_path "$ow_target" || return 2
        ddnsto_bootstrap_safe_ancestors "${ow_target%/*}" || return 12
        [ -f "$ow_target" ] && [ "$(stat -c %u "$ow_target")" = "$(id -u)" ] || return 2
        ow_mode=$(stat -c %a "$ow_target") || return 12
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
        [ "$(stat -c %u "$config")" = "$(id -u)" ] || return 2
        ow_mode=$(stat -c %a "$config") || return 12
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
