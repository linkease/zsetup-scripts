# installer_dispatch parses shared options before this business preflight.
ddnsto_entry_install() {
    case "${1:-}" in --help|-h) ddnsto_usage; return 0 ;; esac
    ddnsto_parse_args "$@" || return $?
    if [ "${ZSETUP_INSTALLER_MODE:-0}" = 1 ] && [ "$PLAN_ONLY" = 0 ]; then
        os=${ZSETUP_OS:-$("$ZSETUP_BIN" context get os)}
        package_manager=${ZSETUP_PACKAGE_MANAGER:-$("$ZSETUP_BIN" context get package_manager)}
        ddnsto_detect_platform || return $?
    else
        ddnsto_local_platform || return $?
    fi
    ddnsto_validate_platform_options || return $?
    if [ "$ACTION" = ensure ] && [ "$PLAN_ONLY" = 0 ]; then
        if [ "$detected_platform" = synology ] && [ "$(id -u)" != 0 ]; then
            # Recommendation entry is already a verified private file. DSM
            # administrators authorize the same file; never download it again.
            [ -f "$0" ] && command -v sudo >/dev/null 2>&1 || {
                ddnsto_flow_error E_PRIVILEGE '群晖自动安装需要管理员权限及本地脚本文件' '请 sudo -i 后重新执行控制台命令'; return 2;
            }
            printf '%s\n' 'DDNSTO：需要 DSM 管理员权限，请按提示输入当前用户的密码。' >&2
            sudo -v || {
                ddnsto_flow_error E_PRIVILEGE '未取得 DSM 管理员授权，尚未修改套件' '请在交互式 SSH 终端输入当前管理员密码，或 sudo -i 后重试'; return 2;
            }
            sudo -n -- sh "$0" "$@"
            return $?
        fi
        ddnsto_ensure_entry "$@"
        return $?
    fi
    if [ "$REQUESTED_METHOD" = docker ]; then
        if [ "$PLAN_ONLY" = 1 ]; then ddnsto_docker_plan
        elif [ "$ACTION" = status ]; then ddnsto_docker_lifecycle
        else ddnsto_docker_locked; fi
        return $?
    fi
    if [ "$PLAN_ONLY" = 1 ]; then ddnsto_plan; return $?; fi
    if [ "$detected_platform" = synology ]; then
        ddnsto_synology_entry
        return $?
    fi
    case "$detected_platform" in linux|openwrt) ;; *) ddnsto_error 'native installation unavailable for this device'; return 2 ;; esac
    case "$ACTION" in
        status|start|stop|restart|repair|configure|uninstall)
            if [ "$detected_platform" = openwrt ]; then
                if [ "$ACTION" = status ]; then ddnsto_openwrt_local
                else ddnsto_machine_locked ddnsto_openwrt_local; fi
                return $?
            fi
            ddnsto_managed_native || return $?
            ddnsto_managed_action
            return $? ;;
    esac
    # Preserve shared directory choices when bootstrap dispatches a second time.
    ZSETUP_INSTALL_SCOPE=${installer_scope:-system}
    ZSETUP_INSTALL_PREFIX=${installer_prefix:-}
    [ -z "${installer_work_dir:-}" ] || ZSETUP_WORK_DIR=$installer_work_dir
    export ZSETUP_INSTALL_SCOPE ZSETUP_INSTALL_PREFIX
    [ -z "${ZSETUP_WORK_DIR:-}" ] || export ZSETUP_WORK_DIR
    if [ "${ZSETUP_INSTALLER_MODE:-0}" = 1 ]; then
        ddnsto_install "$@"
    else
        bootstrap_and_run "$@"
    fi
}

main() {
    case "${1:-}" in --help|-h) ddnsto_usage; return 0 ;; esac
    if [ "${0##*/}" = setup_ddnsto.sh ]; then
        [ "$#" -ge 1 ] && [ -n "$1" ] || { ddnsto_error 'Usage: setup_ddnsto.sh TOKEN'; return 2; }
        setup_token=$1; shift
        set -- --token "$setup_token" "$@"
    fi
    installer_dispatch ddnsto-entry "$@"
}
main "$@"
