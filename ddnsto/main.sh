main() {
    # Preserve the original setup_ddnsto.sh TOKEN invocation without another installer.
    if [ "${0##*/}" = setup_ddnsto.sh ]; then
        [ "$#" -ge 1 ] && [ -n "$1" ] || { ddnsto_error 'Usage: setup_ddnsto.sh TOKEN'; return 2; }
        setup_token=$1
        shift
        set -- --token "$setup_token" --verify-status "$@"
    fi
    case "${1:-}" in --help|-h) ddnsto_usage; return 0 ;; esac
    status 'DDNSTO installer'
    if [ "${ZSETUP_INSTALLER_MODE:-0}" = 1 ]; then
        status '[1/4] zsetup is ready'
        ddnsto_install "$@"
    else
        bootstrap_and_run "$@"
    fi
}
main "$@"
