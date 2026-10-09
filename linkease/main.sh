main() {
    case "${1:-}" in --help|-h) linkease_usage; return 0 ;; esac
    status 'LinkEase installer'
    if [ "${ZSETUP_INSTALLER_MODE:-0}" = 1 ]; then
        status '[1/4] zsetup is ready'
        linkease_install "$@"
    else
        bootstrap_and_run "$@"
    fi
}
main "$@"
