# DDNSTO actions use the shared protected service coordinator, never flat paths.
ddnsto_managed_native() {
    # Offline operations must use the same reviewed bytes as installation.
    # This reads compiled-in pins only: no bootstrap, download or cache writes.
    bootstrap_arch || return 2
    fetch_bootstrap_metadata https '' '' || return 2
    if [ -n "${ZSETUP_BIN:-}" ]; then
        if is_expected_zsetup "$ZSETUP_BIN"; then return 0; fi
    elif find_existing_zsetup; then
        ZSETUP_BIN=$ACTIVE_ZSETUP
        return 0
    fi
    ddnsto_error 'offline management requires the verified pinned zsetup in the installer cache, PATH or ZSETUP_BIN; restore it using the installer before retrying'
    return 2
}

ddnsto_privilege_args() {
    case "${ACTION:-install}" in ensure|install|update) ;; *) return 2 ;; esac
    DDNSTO_ROOT_ACTION=${ACTION:-install}
    DDNSTO_ROOT_TOKEN=$TOKEN
    [ "$DDNSTO_ROOT_ACTION" != update ] || [ -z "$TOKEN" ]
}

# Update only the verified managed ExecStart/condition, preserving unit options
# and every configuration byte. No product -u invocation during an update.
ddnsto_managed_rewrite_unit() {
    [ "$SERVICE_HAD_UNIT" = 1 ] || { ddnsto_error 'update requires an owned service'; return 2; }
    installer_service_quote_unit
}

# Only the reviewed 4.2.8 client defines this local health protocol. Historical
# explicit version overrides retain the upstream systemd health checks.
ddnsto_service_health() {
    if [ "${DDNSTO_ENSURE_ACTIVE:-0}" = 1 ]; then
        ddnsto_ensure_linux_running || return 13
    fi
    [ "${version_num:-}" = 4.2.8 ] || return 0
    managed_health_attempt=0
    while [ "$managed_health_attempt" -lt 5 ]; do
        if ddnsto_managed_health_probe; then return 0; fi
        managed_health_attempt=$((managed_health_attempt + 1))
        sleep 1
    done
    ddnsto_error 'local client health failed; rolling back (cloud status unverified)'
    return 13
}

ddnsto_managed_health_probe() (
    managed_info=${SERVICE_CONFIG%/*}/.ddnsto_http_addr.json
    [ -f "$managed_info" ] && [ ! -L "$managed_info" ] || exit 13
    [ "$("$ZSETUP_BIN" storage "$managed_info" get system_protected)" = true ] || exit 13
    installer_file_size "$managed_info" || exit 13
    [ "$INSTALLER_FILE_SIZE" -le 1024 ] || exit 13
    info=$(cat "$managed_info") || exit 13
    case "$info" in '{"addr":"127.0.0.1:'*'","pid":'*',"startedAt":"'*'"}') ;; *) exit 13 ;; esac
    port=${info#*127.0.0.1:}; port=${port%%\"*}
    pid=${info#*\"pid\":}; pid=${pid%%,*}
    case "$port:$pid" in *[!0-9:]*|:*|*:) exit 13 ;; esac
    [ "${#port}" -le 5 ] && [ "$port" -gt 0 ] && [ "$port" -le 65535 ] || exit 13
    [ "${#pid}" -le 10 ] && [ "$pid" -gt 0 ] || exit 13
    [ "$(readlink "/proc/$pid/exe")" = "$SERVICE_EXEC" ] || exit 13
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy
    no_proxy='*'; NO_PROXY='*'; export no_proxy NO_PROXY
    if command -v curl >/dev/null 2>&1; then
        set -- curl -q --noproxy '*' -fsS --connect-timeout 1 --max-time 2 "http://127.0.0.1:$port/healthz"
    elif command -v wget >/dev/null 2>&1; then
        WGETRC=/dev/null; export WGETRC
        set -- wget -q -T 2 -O - "http://127.0.0.1:$port/healthz"
    else exit 13; fi
    installer_exec_native "$ZSETUP_BIN" capture -o "$transaction_dir/client-health" --max-bytes 16 --timeout 3s -- "$@" >/dev/null 2>&1 || exit 13
    [ "$(cat "$transaction_dir/client-health")" = ok ] || exit 13
)

# Read-only ownership proof; no mkdir, lock, package query or configuration read.
# The service adapter rechecks under its destination lock before any mutation.
ddnsto_managed_owned() {
    installer_layout ddnsto system || return $?
    [ "$INSTALLER_SCOPE" = system ] || return 2
    SERVICE_APP=ddnsto
    SERVICE_NAME=com.linkease.ddnstoshell.service
    SERVICE_UNIT=/etc/systemd/system/$SERVICE_NAME
    SERVICE_BACKEND=systemd
    SERVICE_CONFIG=/etc/ddnsto/ddnsto-config.json
    for managed_path in "$INSTALLER_PREFIX" "$INSTALLER_PREFIX/.managed" "$SERVICE_UNIT"; do
        [ "$("$ZSETUP_BIN" storage "$managed_path" get system_protected)" = true ] || return 12
    done
    [ -f "$INSTALLER_PREFIX/.managed" ] && [ ! -L "$INSTALLER_PREFIX/.managed" ] || {
        ddnsto_error 'managed installation required; legacy migration is not automatic'; return 2;
    }
    installer_file_size "$INSTALLER_PREFIX/.managed" || return 2
    [ "$INSTALLER_FILE_SIZE" = 7 ] || return 2
    IFS= read -r managed_owner < "$INSTALLER_PREFIX/.managed" || return 2
    [ "$managed_owner" = ddnsto ] || return 2
    if [ "${1:-}" = locked ]; then
        [ "${SERVICE_DEST_LOCK_HELD:-0}" = 1 ] || return 2
        ddnsto_managed_lock_owner "$INSTALLER_PREFIX/.service-lock" || return 2
    else
        [ ! -e "$INSTALLER_PREFIX/.service-lock" ] && [ ! -L "$INSTALLER_PREFIX/.service-lock" ] || {
            ddnsto_error 'active or interrupted service transaction requires recovery'; return 2;
        }
    fi
    installer_service_read_current || return $?
    [ -n "$SERVICE_OLD" ] || return 2
    [ "$SERVICE_HAD_UNIT" = 1 ] || [ "${ACTION:-}" = repair ] || return 2
    ddnsto_managed_receipt "$SERVICE_OLD" || return $?
    SERVICE_EXEC="$INSTALLER_PREFIX/$SERVICE_OLD/bin/ddnsto"
    version_num=${SERVICE_OLD#versions/}
}

# Called by the shared service coordinator for install/update as well as local
# writes. Same non-stealable machine lease as native packages and Docker.
ddnsto_service_lock() {
    DDNSTO_GLOBAL_HELD=0; DDNSTO_UNINSTALL_BACKUP=; DDNSTO_UNINSTALL_MOVED=0
    INSTALLER_CLEANUP_HOOK=ddnsto_managed_cleanup
    DDNSTO_GLOBAL_LOCK=/etc/zsetup/install-locks/ddnsto
    [ "$("$ZSETUP_BIN" storage "$DDNSTO_GLOBAL_LOCK" get system_protected)" = true ] || return 12
    umask 022
    mkdir -p /etc/zsetup/install-locks || return 12
    [ "$("$ZSETUP_BIN" storage /etc/zsetup/install-locks get system_protected)" = true ] || return 12
    umask 077
    mkdir "$DDNSTO_GLOBAL_LOCK" 2>/dev/null || {
        ddnsto_error 'active or interrupted machine-wide DDNSTO transaction requires recovery'; return 2;
    }
    DDNSTO_GLOBAL_HELD=1
    printf '%s\n' "$$" > "$DDNSTO_GLOBAL_LOCK/owner" || return 12
    # Recheck method conflict under the same lock used by Docker writers.
    [ ! -e /etc/ddnsto-docker ] && [ ! -L /etc/ddnsto-docker ] || {
        ddnsto_error 'Docker state conflicts with native installation'; return 2;
    }
    # Install/update already performed a preliminary read. Authenticate an
    # existing installation again under the global lease, before snapshots.
    if [ -n "${SERVICE_OLD:-}" ]; then
        ddnsto_managed_owned || return $?
        ddnsto_managed_effective || {
            ddnsto_error 'effective systemd service is not exclusively owned'; return 2;
        }
    fi
    if command -v ddnsto_ensure_linux_locked >/dev/null 2>&1; then
        ddnsto_ensure_linux_locked || return $?
    fi
}

ddnsto_managed_lock_owner() {
    [ -d "$1" ] && [ ! -L "$1" ] || return 2
    [ "$("$ZSETUP_BIN" storage "$1/owner" get system_protected)" = true ] || return 12
    installer_file_size "$1/owner" || return 2
    [ "$INSTALLER_FILE_SIZE" -le 16 ] || return 2
    [ "$(cat "$1/owner")" = "$$" ]
}

# Receipt trust is the same protected-file trust as install-service cached
# versions, with a closed inventory for DDNSTO's single binary and wrapper.
ddnsto_managed_receipt() (
    case "$1" in versions/*) ;; *) exit 2 ;; esac
    v=${1#versions/}; installer_service_version "$v" || exit 2
    dir="$INSTALLER_PREFIX/$1"
    for f in "$dir" "$dir/bin" "$dir/.files" "$dir/.arch" "$dir/.artifact-sha256" "$dir/bin/ddnsto" "$dir/bin/.service-run"; do
        [ "$("$ZSETUP_BIN" storage "$f" get system_protected)" = true ] || exit 12
        [ ! -L "$f" ] || exit 2
    done
    [ -d "$dir" ] && [ -d "$dir/bin" ] || exit 2
    for f in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        case "${f##*/}" in bin|.files|.arch|.artifact-sha256) ;; *) exit 2 ;; esac
    done
    for f in "$dir/bin"/* "$dir/bin"/.[!.]* "$dir/bin"/..?*; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        case "${f##*/}" in ddnsto|.service-run) ;; *) exit 2 ;; esac
    done
    for f in .files .arch .artifact-sha256; do
        installer_file_size "$dir/$f" || exit 2
        [ "$INSTALLER_FILE_SIZE" -le 160 ] || exit 2
    done
    [ "$(cat "$dir/.files")" = "$(printf '.service-run\nddnsto')" ] || exit 2
    case "$(cat "$dir/.arch")" in x86_64|aarch64|armv7) ;; *) exit 2 ;; esac
    sha=$(cat "$dir/.artifact-sha256")
    [ "${#sha}" = 64 ] || exit 2
    case "$sha" in *[!a-f0-9]*) exit 2 ;; esac
    for f in ddnsto .service-run; do
        installer_file_size "$dir/bin/$f" || exit 2
        [ "$INSTALLER_FILE_SIZE" -gt 0 ] && [ "$INSTALLER_FILE_SIZE" -le 67108864 ] && [ -x "$dir/bin/$f" ] || exit 2
    done
    installer_file_size "$dir/bin/.service-run" || exit 2
    [ "$INSTALLER_FILE_SIZE" -le 4096 ] || exit 2
    installer_service_replace "$dir/bin/ddnsto" "'" "'\\''"
    [ "$(cat "$dir/bin/.service-run")" = "$(printf '#!/bin/sh\nexec '\''%s'\'' run\n' "$service_replaced")" ] || exit 2
)

ddnsto_managed_property() {
    installer_exec_native "$ZSETUP_BIN" run -- systemctl show "--property=$1" --value "$SERVICE_NAME"
}

# Prove loaded state as well as the file: matching one ExecStart line alone
# cannot authorize hooks, drop-ins, a stale loaded unit, or a foreign fragment.
ddnsto_managed_effective() {
    managed_fragment=$(ddnsto_managed_property FragmentPath) || return 2
    managed_load=$(ddnsto_managed_property LoadState) || return 2
    managed_reload=$(ddnsto_managed_property NeedDaemonReload) || return 2
    [ "$managed_reload" = no ] || return 2
    for managed_property in DropInPaths ExecCondition ExecStartPre ExecStartPost ExecStop ExecStopPost ExecReload RootDirectory RootImage Environment User Group WorkingDirectory BindPaths BindReadOnlyPaths; do
        managed_value=$(ddnsto_managed_property "$managed_property") || return 2
        [ -z "$managed_value" ] || return 2
    done
    managed_env=$(ddnsto_managed_property EnvironmentFiles) || return 2
    if [ -n "$managed_env" ]; then
        managed_optional=/etc/sysconfig/com.linkease.ddnstoshell
        [ "$managed_env" = "$managed_optional (ignore_errors=yes)" ] || return 2
        [ "$("$ZSETUP_BIN" storage "$managed_optional" get system_protected)" = true ] || return 12
        [ ! -e "$managed_optional" ] && [ ! -L "$managed_optional" ] || return 2
    fi
    managed_exec=$(ddnsto_managed_property ExecStart) || return 2
    if [ "$SERVICE_HAD_UNIT" = 0 ]; then
        [ "$ACTION" = repair ] && [ "$managed_load" = not-found ] && [ -z "$managed_fragment" ] && [ -z "$managed_exec" ] || return 2
        [ ! -e "$SERVICE_UNIT" ] && [ ! -L "$SERVICE_UNIT" ] || return 2
    else
        [ "$managed_load" = loaded ] && [ "$managed_fragment" = "$SERVICE_UNIT" ] || return 2
        case "$managed_exec" in
            "{ path=/bin/sh ; argv[]=/bin/sh ${SERVICE_EXEC%/*}/.service-run ; ignore_errors=no ; "*' }') ;;
            *) return 2 ;;
        esac
        [ -z "${managed_exec#*\}}" ] || return 2
    fi
    managed_state=$(ddnsto_managed_property ActiveState) || return 2
    case "$managed_state" in active) [ "$SERVICE_HAD_UNIT" = 1 ] || return 2 ;; inactive|failed) ;; *) return 2 ;; esac
    managed_enabled=$(ddnsto_managed_property UnitFileState) || return 2
    case "$managed_enabled" in enabled|disabled) ;; '') [ "$SERVICE_HAD_UNIT" = 0 ] || return 2 ;; *) return 2 ;; esac
}

ddnsto_managed_cleanup() {
    # A failed stop is not permission to rewrite a running service's files.
    if [ "$SERVICE_CHANGED" = 1 ]; then
        installer_service_manager stop || return 1
        managed_stopped=$(ddnsto_managed_property ActiveState) || return 1
        case "$managed_stopped" in inactive|failed) ;; *) return 1 ;; esac
    fi
    if [ "${DDNSTO_UNINSTALL_MOVED:-0}" = 1 ]; then
        for managed_entry in versions current previous .managed; do
            if [ -e "$DDNSTO_UNINSTALL_BACKUP/$managed_entry" ] || [ -L "$DDNSTO_UNINSTALL_BACKUP/$managed_entry" ]; then
                [ ! -e "$INSTALLER_PREFIX/$managed_entry" ] && [ ! -L "$INSTALLER_PREFIX/$managed_entry" ] || return 1
                mv "$DDNSTO_UNINSTALL_BACKUP/$managed_entry" "$INSTALLER_PREFIX/$managed_entry" || return 1
            fi
        done
        DDNSTO_UNINSTALL_MOVED=0
    fi
    installer_service_cleanup || return 1
    if [ "${DDNSTO_GLOBAL_HELD:-0}" = 1 ]; then
        ddnsto_managed_lock_owner "$DDNSTO_GLOBAL_LOCK" || return 1
        rm -f "$DDNSTO_GLOBAL_LOCK/owner" || return 1
        rmdir "$DDNSTO_GLOBAL_LOCK" || return 1
        DDNSTO_GLOBAL_HELD=0
    fi
}

ddnsto_managed_uninstall_inventory() {
    for managed_entry in "$INSTALLER_PREFIX"/* "$INSTALLER_PREFIX"/.[!.]* "$INSTALLER_PREFIX"/..?*; do
        [ -e "$managed_entry" ] || [ -L "$managed_entry" ] || continue
        case "${managed_entry##*/}" in versions|current|previous|.managed|.staging|.service-lock) ;; *) return 2 ;; esac
    done
    [ -d "$INSTALLER_PREFIX/versions" ] && [ ! -L "$INSTALLER_PREFIX/versions" ] || return 2
    for managed_entry in "$INSTALLER_PREFIX/versions"/* "$INSTALLER_PREFIX/versions"/.[!.]* "$INSTALLER_PREFIX/versions"/..?*; do
        [ -e "$managed_entry" ] || [ -L "$managed_entry" ] || continue
        ddnsto_managed_receipt "versions/${managed_entry##*/}" || return 2
    done
    if [ -e "$INSTALLER_PREFIX/previous" ] || [ -L "$INSTALLER_PREFIX/previous" ]; then
        [ -L "$INSTALLER_PREFIX/previous" ] || return 2
        ddnsto_managed_receipt "$(readlink "$INSTALLER_PREFIX/previous")" || return 2
    fi
}

ddnsto_managed_write() (
    # This subshell owns traps and flags. Caller/environment flags never grant
    # permission to bypass another coordinator's locks.
    SERVICE_CHANGED=0; SERVICE_NEW_VERSION=0; SERVICE_CANDIDATE=; SERVICE_GOOD=0
    SERVICE_DEST_LOCK_HELD=0; SERVICE_CONFIG_TOUCHED=0; SERVICE_HAD_CONFIG=0
    SERVICE_WAS_ACTIVE=0; SERVICE_WAS_ENABLED=0; DDNSTO_GLOBAL_HELD=0
    INSTALLER_CLEANUP_HOOK=
    [ "$("$ZSETUP_BIN" storage / get effective_uid)" = 0 ] || {
        ddnsto_error 'local writes require a root shell: run sudo -i, then rerun the installer in that shell'; exit 2;
    }
    ddnsto_managed_owned || exit $?
    INSTALLER_WORK_ROOT="$INSTALLER_PREFIX/.staging"
    INSTALLER_RESERVE=8388608
    [ "$("$ZSETUP_BIN" storage "$INSTALLER_WORK_ROOT" get system_protected)" = true ] || exit 12
    installer_transaction_begin || exit $?
    INSTALLER_CLEANUP_HOOK=ddnsto_managed_cleanup
    ddnsto_service_lock || exit $?
    mkdir "$INSTALLER_PREFIX/.service-lock" 2>/dev/null || exit 2
    SERVICE_DEST_LOCK_HELD=1
    printf '%s\n' "$$" > "$INSTALLER_PREFIX/.service-lock/owner" || exit 12
    ddnsto_managed_owned locked || exit $?
    ddnsto_managed_effective || { ddnsto_error 'effective systemd service is not exclusively owned'; exit 2; }
    [ "$managed_state" != active ] || SERVICE_WAS_ACTIVE=1
    [ "$managed_enabled" != enabled ] || SERVICE_WAS_ENABLED=1
    [ "$SERVICE_HAD_UNIT" != 1 ] || cp -p "$SERVICE_UNIT" "$transaction_dir/old-unit" || exit 12
    [ "$("$ZSETUP_BIN" storage "$SERVICE_CONFIG" get system_protected)" = true ] || exit 12
    installer_file_size "$SERVICE_CONFIG" || exit 2
    [ "$INSTALLER_FILE_SIZE" -le 16384 ] || exit 11
    cp -p "$SERVICE_CONFIG" "$transaction_dir/old-config" || exit 12
    SERVICE_HAD_CONFIG=1
    if [ "$ACTION" = configure ]; then
        [ -n "${TOKEN:-}" ] && command -v jq >/dev/null 2>&1 || { ddnsto_error 'configure requires a nonempty Token and jq'; exit 2; }
        installer_exec_native "$ZSETUP_BIN" capture -o "$transaction_dir/new-config" --max-bytes 16384 --min-free-bytes "$INSTALLER_RESERVE" -- jq -e -s --arg token "$TOKEN" 'if length == 1 and (.[0] | type == "object" and (.token | type == "string")) then .[0] | .token = $token else error("unsupported configuration") end' "$SERVICE_CONFIG" >/dev/null 2>&1 || { ddnsto_error 'configuration must contain one JSON object with a token string'; exit 2; }
        chmod 0600 "$transaction_dir/new-config" || exit 12
    fi
    if [ "$ACTION" = uninstall ]; then
        ddnsto_managed_uninstall_inventory || { ddnsto_error 'unknown uninstall inventory; no changes made'; exit 2; }
        DDNSTO_UNINSTALL_BACKUP=$(mktemp -d "$INSTALLER_PREFIX/.uninstalled.XXXXXX") || exit 12
        cp -p "$transaction_dir/old-unit" "$DDNSTO_UNINSTALL_BACKUP/unit" || exit 12
        cp -p "$transaction_dir/old-config" "$DDNSTO_UNINSTALL_BACKUP/config" || exit 12
        printf 'active=%s\nenabled=%s\n' "$SERVICE_WAS_ACTIVE" "$SERVICE_WAS_ENABLED" > "$DDNSTO_UNINSTALL_BACKUP/state" || exit 12
    fi
    ddnsto_managed_effective || exit 2
    SERVICE_CHANGED=1
    # All actions may cause the client to persist config while stopping. Restore
    # its original bytes on failure, even when this operation is not configure.
    SERVICE_CONFIG_TOUCHED=1
    if [ "$SERVICE_HAD_UNIT" = 1 ] && [ "$ACTION" != start ]; then
        installer_service_manager stop || exit $?
        managed_stopped=$(ddnsto_managed_property ActiveState) || exit 2
        case "$managed_stopped" in inactive|failed) ;; *) exit 13 ;; esac
    fi
    case "$ACTION" in
        stop) installer_service_manager disable || exit $? ;;
        uninstall)
            installer_service_manager disable || exit $?
            rm -f "$SERVICE_UNIT" || exit 12
            installer_service_manager reload || exit $?
            [ "$(ddnsto_managed_property LoadState)" = not-found ] || exit 13
            [ -z "$(ddnsto_managed_property FragmentPath)" ] || exit 13
            DDNSTO_UNINSTALL_MOVED=1
            for managed_entry in versions current previous .managed; do
                [ -e "$INSTALLER_PREFIX/$managed_entry" ] || [ -L "$INSTALLER_PREFIX/$managed_entry" ] || continue
                mv "$INSTALLER_PREFIX/$managed_entry" "$DDNSTO_UNINSTALL_BACKUP/$managed_entry" || exit 12
            done
            cp -p "$transaction_dir/old-config" "$SERVICE_CONFIG" || exit 12
            ;;
        *)
            if [ "$ACTION" = configure ]; then
                installer_exec_native "$ZSETUP_BIN" capture -o "$SERVICE_CONFIG" --max-bytes 16384 --min-free-bytes "$INSTALLER_RESERVE" -- cat "$transaction_dir/new-config" || exit $?
                chmod 0600 "$SERVICE_CONFIG" || exit 12
            fi
            if [ "$SERVICE_HAD_UNIT" = 0 ]; then
                installer_service_escape_exec "${SERVICE_EXEC%/*}/.service-run"
                printf '[Unit]\nDescription=DdnstoShell Service\nAfter=network.target\n[Service]\nType=simple\nExecStart=/bin/sh "%s"\nRestart=always\nRestartSec=5\nLimitNOFILE=1048576\n[Install]\nWantedBy=multi-user.target\n' "$service_escaped" > "$transaction_dir/new-unit" || exit 12
                installer_exec_native "$ZSETUP_BIN" capture -o "$SERVICE_UNIT" --max-bytes 16384 --min-free-bytes "$INSTALLER_RESERVE" -- cat "$transaction_dir/new-unit" || exit $?
                chmod 0644 "$SERVICE_UNIT" || exit 12
                installer_service_manager reload || exit $?
            fi
            installer_service_manager enable || exit $?
            installer_service_manager start || exit $?
            installer_service_manager is-active || exit $?
            ddnsto_service_health || exit $?
            ;;
    esac
    SERVICE_CHANGED=0; SERVICE_GOOD=1; DDNSTO_UNINSTALL_MOVED=0
    installer_transaction_finish || exit $?
    printf 'operation=%s cloud_status=unverified\n' "$ACTION"
    [ "$ACTION" != uninstall ] || printf 'config=retained backup=%s user_aliases=retained\n' "$DDNSTO_UNINSTALL_BACKUP"
)

ddnsto_managed_action() {
    [ "$detected_platform" = linux ] || { ddnsto_error 'protected OpenWrt local lifecycle is not yet ported'; return 2; }
    case "$ACTION" in
        status) ;;
        start|stop|restart|repair|configure|uninstall) ddnsto_managed_write; return $? ;;
        *) return 2 ;;
    esac
    installer_layout ddnsto system || return $?
    [ "$INSTALLER_SCOPE" = system ] || return 2
    if [ ! -e "$INSTALLER_PREFIX" ] && [ ! -L "$INSTALLER_PREFIX" ]; then
        printf '%s\n' 'local_service=not-installed cloud_status=unverified'
        return 0
    fi
    ddnsto_managed_owned || return $?
    ddnsto_managed_effective || return $?
    case "$managed_state" in active) managed_state=running ;; inactive) managed_state=stopped ;; failed|activating|deactivating|reloading) ;; *) return 2 ;; esac
    printf 'local_service=%s cloud_status=unverified\n' "$managed_state"
}
