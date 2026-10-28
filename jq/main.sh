main() {
    case "${1:-}" in
        --plan) jq_install "$@" ;;
        --help) printf '%s\n' 'jq-install.sh [--plan|--remove] [--installer-prefix ABSOLUTE_DIRECTORY]' 'Installs only a pinned, verified jq; preserves the system executable.' ;;
        *)
            if [ "${ZSETUP_INSTALLER_MODE:-0}" != 1 ] && [ -z "${ZSETUP_BIN:-}" ]; then
                bootstrap_zsetup || return $?
                ZSETUP_BIN=$ACTIVE_ZSETUP
            fi
            jq_install "$@" ;;
    esac
}
main "$@"
