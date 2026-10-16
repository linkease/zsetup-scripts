main() {
    status 'FastPVE installer'
    if [ "${ZSETUP_INSTALLER_MODE:-0}" = 1 ]; then
        status '[1/4] zsetup is ready'
        installer_dispatch fastpve "$@"
    else
        bootstrap_and_run "$@"
    fi
}

main "$@"
