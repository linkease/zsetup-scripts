main() {
    status "FastNet installer"
    if [ "${ZSETUP_INSTALLER_MODE:-0}" = 1 ]; then
        status "[1/4] zsetup is ready"
        installer_dispatch fastnet "$@"
    else
        bootstrap_and_run "$@"
    fi
}

main "$@"
