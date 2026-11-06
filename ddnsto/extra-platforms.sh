# Non-service adapters still use the published native downloader. They never
# enter the Linux system-service installer on a NAS or a Docker-selected path.
ddnsto_synology_entry() (
    if [ "${PLAN_ONLY:-0}" = 1 ]; then ddnsto_synology_download "$@"; exit $?; fi
    if [ "${ZSETUP_INSTALLER_MODE:-0}" != 1 ]; then
        ddnsto_bootstrap_zsetup || exit $?
        ZSETUP_BIN=$ACTIVE_ZSETUP
    fi
    ZSETUP_SOURCE_BASES=${ZSETUP_SOURCE_BASES:-$DIRECT_PRIMARY_BASES}
    ZSETUP_SOURCE_FALLBACK=${ZSETUP_SOURCE_FALLBACK-$DIRECT_FALLBACK_BASE}
    ddnsto_download() (
        relative=$1; output=$2; digest=$3
        set -- "$ZSETUP_BIN" download -o "$output" --sha256 "$digest" \
            --max-bytes 33554432 --min-free-bytes 8388608
        [ -z "${ZSETUP_CA_FILE:-}" ] || set -- "$@" --ca-file "$ZSETUP_CA_FILE"
        for base in $ZSETUP_SOURCE_BASES; do set -- "$@" "${base%/}/ddnsto/$relative"; done
        [ -z "$ZSETUP_SOURCE_FALLBACK" ] || set -- "$@" --fallback-url "${ZSETUP_SOURCE_FALLBACK%/}/ddnsto/$relative"
        # The private download owner joins its child before caller cleanup.
        native_child=
        trap '[ -z "$native_child" ] || { kill -TERM "$native_child" 2>/dev/null || true; wait "$native_child" 2>/dev/null || true; }' EXIT
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM
        "$@" &
        native_child=$!
        result=0; wait "$native_child" || result=$?
        native_child=
        exit "$result"
    )
    ddnsto_synology_download "$@"
)

ddnsto_docker_locked() (
    ddnsto_machine_locked ddnsto_docker_lifecycle
)

ddnsto_machine_locked() (
    [ "$(id -u)" = 0 ] || { printf '%s\n' 'DDNSTO: changes require an explicit root shell' >&2; exit 2; }
    # The same root-owned lease is used by native package/service adapters.
    ddnsto_bootstrap_safe_ancestors /etc || exit 12
    for directory in /etc/zsetup /etc/zsetup/install-locks; do
        [ -e "$directory" ] || mkdir -m 755 "$directory" || exit 12
        ddnsto_bootstrap_safe_ancestors "$directory" || exit 12
    done
    docker_lock=/etc/zsetup/install-locks/ddnsto
    mkdir -m 700 "$docker_lock" 2>/dev/null || { printf '%s\n' 'DDNSTO: another installation or recovery lease exists' >&2; exit 16; }
    trap 'result=$?; trap - EXIT HUP INT TERM; rmdir "$docker_lock" || result=16; exit "$result"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    ( "$@" )
)
