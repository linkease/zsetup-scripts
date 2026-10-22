# Only offer Docker for a fresh generic Linux host and a verified local engine.
ddnsto_method_interactive() { [ -t 0 ]; }

ddnsto_choose_method() (
    exec 3<>/dev/tty || exit 2
    printf '%s\n' 'A local Linux amd64 Docker engine is available.' \
        '0) Native installation (default)' \
        '1) Experimental Docker: identity persistence and replacement upgrades are NOT accepted yet.' >&3
    printf 'Installation method [0]: ' >&3
    IFS= read -r method_choice <&3 || method_choice=
    case "$method_choice" in ''|0) printf native ;; 1) printf docker ;; *) exit 2 ;; esac
)

ddnsto_offer_install_method() {
    [ "$detected_platform" = linux ] || return 0
    [ "$REQUESTED_METHOD" != docker ] || return 0
    docker_state=${DDNSTO_DOCKER_STATE_DIR:-/etc/ddnsto-docker}
    if [ -e "$docker_state" ] || [ -L "$docker_state" ]; then
        ddnsto_error 'Docker state exists; use --method docker explicitly. Native/container migration is not supported.'
        return 2
    fi
    [ "$REQUESTED_METHOD" = auto ] && [ "$ACTION" = install ] || return 0
    ddnsto_method_interactive || return 0
    for native_path in "${DDNSTO_BIN_PATH:-/usr/local/bin/ddnsto}" "${DDNSTO_LINUX_CONFIG_DIR:-/etc/ddnsto}"; do
        [ ! -e "$native_path" ] && [ ! -L "$native_path" ] || return 0
    done
    (REQUESTED_METHOD=docker; ddnsto_docker_discover >/dev/null 2>&1) || return 0
    method_choice=$(ddnsto_choose_method) || { ddnsto_error 'invalid method selection'; return 2; }
    case "$method_choice" in native) ;; docker) REQUESTED_METHOD=docker ;; *) return 2 ;; esac
}
