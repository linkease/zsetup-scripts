# JSON remains authoritative. Regenerate derived YAML before coordinator starts,
# including rollback restarts, while the existing service lease is held.
ddnsto_service_before_start() (
    [ -L "$INSTALLER_PREFIX/current" ] || return 0
    current=$(readlink "$INSTALLER_PREFIX/current") || return 2
    case "$current" in versions/*) ;; *) return 2 ;; esac
    installer_service_version "${current#versions/}" || return 2
    executable="$INSTALLER_PREFIX/$current/bin/ddnsto"
    wrapper="${executable%/*}/.service-run"
    [ -f "$wrapper" ] && [ ! -L "$wrapper" ] || return 2
    wrapper_size=$(wc -c < "$wrapper") || return 2
    [ "$wrapper_size" -le 4096 ] || return 2
    state=${SERVICE_CONFIG%/*}
    runtime="$state/.ddnsto-zig.yaml"
    expected=$(ddnsto_zig_service_wrapper "$executable" "$runtime") || return 2
    # Only the exact generated wrapper opts in, never caller environment flags.
    [ "$(cat "$wrapper")" = "$expected" ] || return 0
    for protected in "$state" "$SERVICE_CONFIG" "$wrapper" "$runtime"; do
        [ ! -L "$protected" ] || return 12
        [ "$("$ZSETUP_BIN" storage "$protected" get system_protected)" = true ] || return 12
    done
    [ ! -e "$runtime" ] || [ -f "$runtime" ] || return 12
    umask 077
    candidate=$(mktemp "$state/.zig-config.XXXXXX") || return 12
    trap 'rm -f "$candidate"' EXIT
    if ! ddnsto_zig_config_render "$SERVICE_CONFIG" "$state" > "$candidate"; then
        printf '%s\n' 'DDNSTO: Zig service configuration is invalid; service was not started.' >&2
        return 2
    fi
    # Native capture commits atomically, preserving old output on failure.
    installer_exec_native "$ZSETUP_BIN" capture -o "$runtime" --max-bytes 32768 \
        --min-free-bytes "$INSTALLER_RESERVE" -- cat "$candidate" || return $?
    chmod 0600 "$runtime" || return 12
)
