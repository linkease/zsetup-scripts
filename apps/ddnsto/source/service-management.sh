# Local-only management. Never bootstrap or read client credentials.
ddnsto_service_state() {
    if [ "$manager" = systemd ]; then
        service_state=$(ddnsto_privileged systemctl show --property=ActiveState --value "$linux_service_name") || return $?
        case "$service_state" in
            active) service_state=running ;;
            inactive) service_state=stopped ;;
            failed|activating|deactivating|reloading) ;;
            *) ddnsto_error 'unknown service state'; return 2 ;;
        esac
    else
        state_rc=0
        ddnsto_service_command status >/dev/null 2>&1 || state_rc=$?
        case "$state_rc" in
            0) service_state=running ;;
            1|3) service_state=stopped ;;
            *) ddnsto_error 'could not query service state'; return "$state_rc" ;;
        esac
    fi
}

ddnsto_service_assert_owned() (
    # A matching name/LoadState is not ownership. Reuse the lifecycle contracts
    # before EVERY write (including enable/disable), under the shared lock.
    case "$manager" in
        systemd)
            for owned_path in "$bin_path" "$linux_config_file" "$config_dir/.installer-linux-v1" "$config_dir/.uninstalled-linux-v1"; do
                ddnsto_linux_lifecycle_safe_path "$owned_path" || return 2
            done
            ddnsto_privileged test -f "$bin_path" && ddnsto_privileged test -f "$linux_config_file" || return 2
            ddnsto_linux_state_valid "$config_dir/.installer-linux-v1" || {
                ddnsto_error 'managed Linux marker required for service changes; legacy status remains available'; return 2;
            }
            ddnsto_privileged test ! -e "$config_dir/.uninstalled-linux-v1" || return 2
            ddnsto_linux_unit_exists && ddnsto_linux_unit_owned || {
                ddnsto_error 'systemd service ownership not verified; refusing service operation'; return 2;
            } ;;
        openwrt)
            case "${package_manager:-}" in opkg|apk) ;; *) ddnsto_error 'package manager required for service ownership'; return 2 ;; esac
            for owned_path in "$binary" "$config" "$service_path"; do
                ddnsto_ow_safe_path "$owned_path" && [ -f "$owned_path" ] && ddnsto_ow_owned "$owned_path" || {
                    ddnsto_error 'OpenWrt package ownership not verified; refusing service operation'; return 2;
                }
            done
            [ -x "$binary" ] && [ -x "$service_path" ] || return 2
            ow_packages=$(ddnsto_ow_packages) && ddnsto_ow_has_package ddnsto || {
                ddnsto_error 'installed ddnsto package metadata unavailable'; return 2;
            } ;;
        *) ddnsto_error 'OpenRC write actions require verifiable ownership and are not supported'; return 2 ;;
    esac
)

ddnsto_service_command() {
    if [ "$1" != status ]; then ddnsto_service_assert_owned || return 2; fi
    case "$manager:$1" in
        systemd:*) ddnsto_privileged systemctl "$1" "$linux_service_name" ;;
        openrc:enable) ddnsto_privileged rc-update add "$linux_service_name" default ;;
        openrc:disable) ddnsto_privileged rc-update del "$linux_service_name" default ;;
        openrc:*) ddnsto_privileged rc-service "$linux_service_name" "$1" ;;
        openwrt:*) ddnsto_privileged "$service_path" "$1" ;;
    esac
}

ddnsto_manage_service() {
    ddnsto_local_platform || exit $?
    [ "$REQUESTED_METHOD" != docker ] || { ddnsto_error 'Docker management is not available'; exit 2; }
    case "$detected_platform" in linux|openwrt) ;; *) ddnsto_error 'native service management is unavailable for this device'; exit 2 ;; esac
    if [ "$ACTION" = status ]; then
        ddnsto_manage_service_locked
    else
        ddnsto_with_operation_lock ddnsto_manage_service_locked
    fi
}

ddnsto_manage_service_locked() (
    case "$detected_platform" in
        linux)
            ddnsto_linux_preflight management || exit $?
            binary=${DDNSTO_BIN_PATH:-/usr/local/bin/ddnsto}
            config_dir=${DDNSTO_LINUX_CONFIG_DIR:-/etc/ddnsto}
            config=$config_dir/ddnsto-config.json
            if [ "$ACTION" = status ] && ddnsto_linux_state_valid "$config_dir/.uninstalled-linux-v1" &&
               ! ddnsto_privileged test -e "$binary" && ! ddnsto_privileged test -L "$binary"; then
                printf '%s\n' 'local_service=not-installed config=retained cloud_status=unverified'
                exit 0
            fi ;;
        openwrt)
            SUDO=
            [ "$(id -u)" = 0 ] || { ddnsto_error 'OpenWrt management requires root'; exit 2; }
            binary=${DDNSTO_OPENWRT_BIN_PATH:-/usr/sbin/ddnstod}
            config=${DDNSTO_CONFIG_PATH:-/etc/config/ddnsto}
            config_dir=${config%/*} ;;
        *) ddnsto_error 'native service management is unavailable for this device'; exit 2 ;;
    esac
    for file in "$binary" "$config"; do
        ddnsto_privileged test -f "$file" && ddnsto_privileged test ! -L "$file" || { ddnsto_error 'complete native installation required; no service changes made'; exit 2; }
    done
    ddnsto_privileged test ! -L "$config_dir" || { ddnsto_error 'configuration directory must not be a symlink'; exit 2; }
    if [ "$detected_platform" = linux ]; then
        manager=$linux_service_manager
        if [ "$manager" = systemd ]; then
            bin_path=$binary
            linux_config_file=$config
            unit_path=$(ddnsto_linux_unit_path) || exit 2
            load_state=$(ddnsto_privileged systemctl show --property=LoadState --value "$linux_service_name") || exit $?
            [ "$load_state" = loaded ] || { ddnsto_error 'installed service unit is unavailable'; exit 2; }
        else
            [ "$ACTION" = status ] || { ddnsto_error 'OpenRC write actions require verifiable ownership and are not supported'; exit 2; }
            ddnsto_privileged rc-service --exists "$linux_service_name" || exit $?
        fi
    else
        manager=openwrt
        service_path=${DDNSTO_SERVICE_PATH:-/etc/init.d/ddnsto}
        [ -f "$service_path" ] && [ -x "$service_path" ] && [ ! -L "$service_path" ] || exit 2
    fi
    if [ "$ACTION" != status ]; then
        # stop disables boot startup as well as stopping the supervised process.
        # No config rewrite, service re-registration or implicit install occurs.
        if [ "$ACTION" = stop ]; then
            ddnsto_service_command disable || exit $?
            ddnsto_service_command stop || exit $?
            expected=stopped
        else
            ddnsto_service_command enable || exit $?
            if [ "$ACTION" = restart ]; then ddnsto_service_command stop || exit $?; fi
            ddnsto_service_command start || exit $?
            expected=running
        fi
        attempt=0
        while :; do
            ddnsto_service_state || exit $?
            [ "$service_state" != "$expected" ] || break
            attempt=$((attempt + 1))
            [ "$attempt" -lt 10 ] || { ddnsto_error 'service did not reach requested state'; exit 13; }
            sleep 1
        done
    else
        ddnsto_service_state || exit $?
    fi
    printf 'local_service=%s cloud_status=unverified\n' "$service_state"
)
