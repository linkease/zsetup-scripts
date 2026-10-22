# Included in install.sh. Do not trust older clients' service exit codes.
ddnsto_linux_preflight() {
    SUDO=
    if [ "$(id -u)" != 0 ]; then
        command -v sudo >/dev/null 2>&1 || { ddnsto_error 'Linux service installation requires root or sudo'; return 2; }
        SUDO=sudo
        sudo -v || return 2
    fi
    linux_service_name=com.linkease.ddnstoshell
    linux_config_dir=${DDNSTO_LINUX_CONFIG_DIR:-/etc/ddnsto}
    linux_config_file="$linux_config_dir/ddnsto-config.json"
    [ ! -L "$linux_config_dir" ] && [ ! -L "$linux_config_file" ] || {
        ddnsto_error 'service configuration must not be a symlink'; return 2;
    }
    if command -v systemctl >/dev/null 2>&1 && ddnsto_privileged systemctl show-environment >/dev/null 2>&1; then
        linux_service_manager=systemd
    elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1 &&
         command -v openrc-run >/dev/null 2>&1 && [ -f /run/openrc/softlevel ]; then
        linux_service_manager=openrc
    else
        ddnsto_error 'a running systemd or initialized OpenRC environment is required; no service changes made'
        return 2
    fi
    [ "${1:-}" != management ] || return 0
    command -v readlink >/dev/null 2>&1 || return 2
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || {
        ddnsto_error 'curl or wget is required for the local health check'; return 2;
    }
}

ddnsto_linux_running() {
    case "$linux_service_manager" in
        systemd) ddnsto_privileged systemctl is-active --quiet "$linux_service_name" ;;
        openrc) ddnsto_privileged rc-service "$linux_service_name" status ;;
    esac
}

ddnsto_linux_stop() {
    case "$linux_service_manager" in
        systemd) ddnsto_privileged systemctl stop "$linux_service_name" ;;
        openrc) ddnsto_privileged rc-service "$linux_service_name" stop ;;
    esac
}

ddnsto_linux_health() (
    # Read only the client's own compact addrInfo schema; reject unfamiliar data
    # rather than eval JSON or probe an unrelated service at a hard-coded port.
    info=$(ddnsto_privileged cat "$linux_config_dir/.ddnsto_http_addr.json" 2>/dev/null) || exit 1
    case "$info" in '{"addr":"127.0.0.1:'*'","pid":'*',"startedAt":"'*'"}') ;; *) exit 1 ;; esac
    port=${info#*127.0.0.1:}; port=${port%%\"*}
    pid=${info#*\"pid\":}; pid=${pid%%,*}
    case "$port:$pid" in *[!0-9:]*|:*|*:) exit 1 ;; esac
    [ "${#port}" -le 5 ] && [ "$port" -gt 0 ] && [ "$port" -le 65535 ] || exit 1
    [ "${#pid}" -le 10 ] && [ "$pid" -gt 0 ] || exit 1
    executable=$(ddnsto_privileged readlink "/proc/$pid/exe") || exit 1
    [ "$executable" = "$(readlink -f "$bin_path")" ] || exit 1
    # Never send local checks through an environment-configured proxy.
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy
    if command -v curl >/dev/null 2>&1; then
        response=$(curl --noproxy '*' -fsS --connect-timeout 1 --max-time 2 "http://127.0.0.1:$port/healthz" 2>/dev/null) || exit 1
    else
        response=$(wget -q -T 2 -O - "http://127.0.0.1:$port/healthz" 2>/dev/null) || exit 1
    fi
    [ "$response" = ok ]
)

ddnsto_linux_wait_healthy() {
    health_attempt=0
    while [ "$health_attempt" -lt 10 ]; do
        if ddnsto_linux_running >/dev/null 2>&1 && ddnsto_linux_health; then return 0; fi
        health_attempt=$((health_attempt + 1))
        sleep 1
    done
    ddnsto_error 'local service health check failed (cloud connectivity is not required)'
    return 13
}

ddnsto_linux_restore() {
    # Every step is checked explicitly: this runs from a conditional EXIT trap,
    # where POSIX shells suppress errexit inside functions.
    ddnsto_linux_stop >/dev/null 2>&1 || return 1
    if [ "$had_old" = 1 ]; then
        ddnsto_privileged cp -p "$backup/binary" "$bin_path" || return 1
    else
        ddnsto_privileged "$bin_path" uninstall || return 1
        ddnsto_privileged rm -f "$bin_path" || return 1
    fi
    if [ "$had_config" = 1 ]; then
        ddnsto_privileged cp -p "$backup/config" "$linux_config_file" || return 1
    else
        ddnsto_privileged rm -f "$linux_config_file" || return 1
    fi
    if [ "$had_old" = 1 ]; then
        # Reuse restored service config, never overwrite it with the failed
        # candidate's Token while attempting recovery.
        ddnsto_privileged "$bin_path" -daemon || return 1
        ddnsto_linux_wait_healthy || return 1
    fi
    replacement_started=0
}
