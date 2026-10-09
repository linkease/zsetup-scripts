main() {
    status 'FastPVE installer'
    if [ "${ZSETUP_INSTALLER_MODE:-0}" = 1 ]; then
        status '[1/4] zsetup is ready'
        fastpve_install "$@"
    else
        bootstrap_and_run "$@"
    fi
}

main "$@"
