main() {
    if [ "${1:-}" = --help ]; then kspeeder_binary_help kspeeder; return 0; fi
    status 'KSpeeder binary installer'
    if [ "${ZSETUP_INSTALLER_MODE:-0}" = 1 ]; then
        installer_dispatch kspeeder "$@"
    else
        bootstrap_and_run "$@"
    fi
}

main "$@"
