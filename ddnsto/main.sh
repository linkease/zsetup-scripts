ddnsto_dispatch_local_action() {
    ddnsto_validate_action_options || return $?
    case "$ACTION" in
        status|start|stop|restart) ddnsto_manage_service ;;
        repair|configure|uninstall)
            ddnsto_local_platform || return $?
            [ "$REQUESTED_METHOD" != docker ] || { ddnsto_error 'Docker lifecycle unavailable'; return 2; }
            case "$detected_platform" in
                linux) ddnsto_with_operation_lock ddnsto_linux_lifecycle ;;
                openwrt)
                    SUDO=
                    [ "$(id -u)" = 0 ] || { ddnsto_error 'OpenWrt lifecycle requires root'; return 2; }
                    business_platform=openwrt
                    binary=${DDNSTO_OPENWRT_BIN_PATH:-/usr/sbin/ddnstod}
                    config=${DDNSTO_CONFIG_PATH:-/etc/config/ddnsto}
                    service_path=${DDNSTO_SERVICE_PATH:-/etc/init.d/ddnsto}
                    if [ "$ACTION" = configure ] && [ -z "$TOKEN" ]; then
                        [ -t 0 ] || { ddnsto_error 'configure needs --token or --token-file without an interactive terminal'; return 2; }
                        TOKEN=$(ddnsto_prompt_token) || { ddnsto_error 'could not read token'; return 2; }
                        [ -n "$TOKEN" ] || { ddnsto_error 'empty token'; return 2; }
                    fi
                    ddnsto_with_operation_lock ddnsto_openwrt_lifecycle ;;
                *) ddnsto_error 'this platform lifecycle is not available'; return 2 ;;
            esac ;;
        *) return 2 ;;
    esac
}

main() {
    # Preserve the original setup_ddnsto.sh TOKEN invocation without another installer.
    if [ "${0##*/}" = setup_ddnsto.sh ]; then
        [ "$#" -ge 1 ] && [ -n "$1" ] || { ddnsto_error 'Usage: setup_ddnsto.sh TOKEN'; return 2; }
        setup_token=$1
        shift
        set -- --token "$setup_token" --verify-status "$@"
    fi
    case "${1:-}" in --help|-h) ddnsto_usage; return 0 ;; esac
    ddnsto_parse_args "$@" || return $?
    if [ "$PLAN_ONLY" = 0 ] && [ "${ZSETUP_INSTALLER_MODE:-0}" != 1 ] &&
       { [ "$ACTION" = install ] || [ "$ACTION" = update ] || [ "$ACTION" = download ]; }; then
        ddnsto_local_platform || return $?
        ddnsto_validate_platform_options || return $?
        ddnsto_offer_install_method || return $?
    fi
    if [ "$REQUESTED_METHOD" = docker ]; then
        ddnsto_local_platform || return $?
        [ -z "$OUTPUT_DIR" ] || { ddnsto_error 'output-dir is not a Docker option'; return 2; }
        if [ "$PLAN_ONLY" = 1 ]; then ddnsto_docker_plan
        elif [ "$ACTION" = status ]; then ddnsto_docker_lifecycle
        else ddnsto_with_operation_lock ddnsto_docker_lifecycle; fi
        return $?
    fi
    if [ "$PLAN_ONLY" = 1 ]; then ddnsto_plan; return $?; fi
    case "$ACTION" in
        repair|configure|uninstall|status|start|stop|restart) ddnsto_dispatch_local_action; return $? ;;
    esac
    if [ "${ZSETUP_INSTALLER_MODE:-0}" != 1 ]; then
        # Exiting an existing installation must also work offline, without
        # bootstrapping zsetup or creating cache files. Revalidate after context.
        ddnsto_local_platform || return $?
        if [ "$REQUESTED_METHOD" = docker ]; then
            ddnsto_error 'Docker installer is not available; native installation was not attempted'
            return 2
        fi
        case "$detected_platform" in
            linux|openwrt)
                business_platform=$detected_platform
                ddnsto_existing_policy || return $?
                [ "$INSTALL_SKIPPED" = 0 ] || return 0
                case "$ACTION" in install|update) ;; *) ddnsto_dispatch_local_action; return $? ;; esac
                # Carry an interactive choice across the installer's reparse.
                if [ "$ACTION" = update ]; then set -- "$@" --action update; fi ;;
        esac
    fi
    status 'DDNSTO installer'
    if [ "${ZSETUP_INSTALLER_MODE:-0}" = 1 ]; then
        status '[1/4] zsetup is ready'
        ddnsto_install "$@"
    else
        bootstrap_and_run "$@"
    fi
}
main "$@"
