main() {
    if [ "${1:-}" = --help ]; then kspeeder_binary_help ks-cli; return 0; fi
    status 'ks-cli binary installer'
    if [ "${ZSETUP_INSTALLER_MODE:-0}" = 1 ]; then
        installer_dispatch ks-cli "$@"
    else
        bootstrap_and_run "$@"
    fi
}

main "$@"
