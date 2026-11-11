# Controlled ASUS lifecycle. Source after asus-storage.sh; caller owns the
# transaction lock and verified payload. Never execute the native plugin scripts.
# Software-center execution trust is inherited: writable firmware dispatchers
# can still execute arbitrary code. These bridges do not secure the whole router.
# All publication uses a same-filesystem source with the EXACT leaf basename,
# and destination '.' in a pinned physical directory. No mv -T requirement.
# Never execute original root scripts, even during recovery.

_ddnsto_asus_plugin_files() {
    printf '%s\n' bin/ddnsto scripts/ddnsto_config.sh scripts/ddnsto_status.sh \
        scripts/uninstall_ddnsto.sh init.d/S70ddnsto.sh webs/Module_ddnsto.asp res/icon-ddnsto.png
}

_ddnsto_asus_metadata_keys() {
    printf '%s\n' ddnsto_token ddnsto_enable ddnsto_version ddnsto_client_version \
        softcenter_module_ddnsto_version softcenter_module_ddnsto_install \
        softcenter_module_ddnsto_name softcenter_module_ddnsto_title \
        softcenter_module_ddnsto_description
}

# Called in a subshell. Each operation stays relative to the pinned physical
# directory; a changed ancestor either fails validation or cannot redirect it.
_ddnsto_asus_plugin_cd() {
    case "$1" in bin|scripts|init.d|webs|res) ;; *) return 1 ;; esac
    cd -P /jffs || return 1
    [ ! -L .koolshare ] && cd -P .koolshare || return 1
    [ "$(pwd -P)" = /jffs/.koolshare ] || return 1
    [ ! -L "$1" ] && cd -P "$1" || return 1
    [ "$(pwd -P)" = "/jffs/.koolshare/$1" ]
}

# Destination is always the pinned cwd, never a separately resolved leaf path.
# mv appends the source basename once; rename replaces a leaf symlink instead
# of traversing it. Verify firmware semantics in private state before stop.
_ddnsto_asus_publish() { mv -f "$1" .; }

_ddnsto_asus_probe_mv() (
    probe="$ASUS_ATTEMPT/mv-probe"
    mkdir "$probe" "$probe/source" "$probe/dest" "$probe/outside" || return 1
    printf probe > "$probe/source/leaf"
    ln -s "$probe/outside" "$probe/dest/leaf" || return 1
    cd -P "$probe/dest" || return 1
    _ddnsto_asus_publish "$probe/source/leaf" || return 1
    [ ! -L leaf ] && [ -f leaf ] && [ "$(cat leaf)" = probe ] || return 1
    [ ! -e "$probe/outside/leaf" ] || return 1
    mkdir "$probe/dest/directory" || return 1
    printf probe > "$probe/source/directory"
    if _ddnsto_asus_publish "$probe/source/directory" 2>/dev/null; then return 1; fi
    [ ! -e "$probe/dest/directory/directory" ]
)

ddnsto_asus_backup_plugin() (
    umask 077
    ddnsto_asus_private_dir "$ASUS_ATTEMPT" || return 1
    mkdir "$ASUS_ATTEMPT/backup" "$ASUS_ATTEMPT/changed" || return 1
    mkdir "$ASUS_ATTEMPT/backup/files" "$ASUS_ATTEMPT/backup/config" || return 1
    _ddnsto_asus_probe_mv || return 1
    for key in $(_ddnsto_asus_metadata_keys); do
        ddnsto_asus_get "$key" > "$ASUS_ATTEMPT/backup/config/$key" || return 1
    done
    for entry in $(_ddnsto_asus_plugin_files); do
        (
            _ddnsto_asus_plugin_cd "${entry%/*}" || exit 1
            leaf=${entry##*/}
            if [ -e "$leaf" ] || [ -L "$leaf" ]; then
                [ -L "$leaf" ] || [ -f "$leaf" ] || exit 1
                cp -pP "$leaf" "$ASUS_ATTEMPT/backup/files/$leaf" || exit 1
                [ -L "$ASUS_ATTEMPT/backup/files/$leaf" ] ||
                    ddnsto_asus_safe_file "$ASUS_ATTEMPT/backup/files/$leaf" || exit 1
            fi
        ) || return 1
    done
    if [ -L "$ASUS_STATE/current" ]; then
        previous=$(readlink -f "$ASUS_STATE/current") || return 1
        case "$previous" in "$ASUS_STATE"/*/runtime) ;; *) return 1 ;; esac
        ddnsto_asus_safe_file "$previous/ddnsto" &&
            ddnsto_asus_safe_file "$previous/service.sh" || return 1
        cp -pP "$ASUS_STATE/current" "$ASUS_ATTEMPT/backup/current" || return 1
    elif [ -e "$ASUS_STATE/current" ]; then return 1
    fi
    # Rollback may run ONLY reviewed bytes. Native originals remain complete in
    # backup even when they cannot be trusted to execute. Fail before stop if an
    # enabled legacy binary cannot be matched to this reviewed package.
    if [ ! -L "$ASUS_ATTEMPT/backup/current" ] &&
        [ "$(cat "$ASUS_ATTEMPT/backup/config/ddnsto_enable")" = 1 ]; then
        old="$ASUS_ATTEMPT/backup/files/ddnsto"
        ddnsto_asus_safe_file "$old" && cmp -s "$old" "$ASUS_ATTEMPT/payload/ddnsto" || {
            printf '%s\n' 'ASUS: enabled native binary is not reviewed recovery material' >&2
            return 1
        }
    fi
    # Prepare recovery before the first stop, including failures before install.
    _ddnsto_asus_prepare_runtime || return 1
    : > "$ASUS_ATTEMPT/backup/complete"
)

_ddnsto_asus_runtime() {
    cat <<'ASUS_RUNTIME'
#!/bin/sh
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
unset ENV BASH_ENV CDPATH
umask 077
service_binary=/jffs/.ddnsto-installer/current/ddnsto

asus_service_get() { /usr/bin/dbus get "$1"; }

# pidof is only an enumerator. Root ownership, executable and process birth
# time are checked independently, immediately before each signal/probe.
asus_service_identity() (
    case "$1" in ''|*[!0-9]*|0|1) exit 1 ;; esac
    target=$(readlink "/proc/$1/exe") || exit 1
    case "$target" in
        /.koolshare/bin/ddnsto|/jffs/.koolshare/bin/ddnsto)
            [ "${2:-}" = legacy ] || exit 1 ;;
        *) wanted=$(readlink -f "$service_binary") || exit 1
            [ "$target" = "$wanted" ] || exit 1 ;;
    esac
    role=$(awk '
        $1=="Uid:" {u++; if (NF!=5 || $2!=0 || $3!=0 || $4!=0 || $5!=0) bad=1}
        $1=="PPid:" {p++; parent=$2}
        END {if (u!=1 || p!=1 || bad || parent !~ /^[0-9]+$/) exit 1; print parent}
    ' "/proc/$1/status") || exit 1
    birth=$(sed 's/^.*) //' "/proc/$1/stat" | awk 'NF>=20 && $20 ~ /^[0-9]+$/ {print $20}')
    [ -n "$birth" ] || exit 1
    printf '%s:%s:%s\n' "$target" "$role" "$birth"
)

asus_service_main() {
    main=
    for pid in $(pidof ddnsto 2>/dev/null); do
        ident=$(asus_service_identity "$pid") || return 1
        case "$ident" in *:1:*)
            [ -z "$main" ] || return 1
            main=$pid; main_identity=$ident ;;
        esac
    done
    [ -n "$main" ]
}

asus_service_running() {
    asus_service_main || return 1
    stable_pid=$main stable_identity=$main_identity
    for probe in 2 3; do
        sleep 1
        asus_service_main || return 1
        [ "$main" = "$stable_pid" ] && [ "$main_identity" = "$stable_identity" ] || return 1
    done
}

asus_service_stop() {
    # Include the legacy executable only for installer migration, never for UI.
    mains= children=
    for pid in $(pidof ddnsto 2>/dev/null); do
        ident=$(asus_service_identity "$pid" "${1:-}") || continue
        case "$ident" in *:1:*) mains="$mains $pid" ;; *) children="$children $pid" ;; esac
    done
    # Stop the supervisor first so it cannot respawn the WebDAV child. Recheck
    # identity at signal time (children may have become reparented meanwhile).
    for pid in $mains $children; do
        ident=$(asus_service_identity "$pid" "${1:-}") || continue
        [ "$(asus_service_identity "$pid" "${1:-}")" = "$ident" ] || return 1
        kill -TERM "$pid" 2>/dev/null || {
            [ "$(asus_service_identity "$pid" "${1:-}")" != "$ident" ] || return 1
        }
    done
    for probe in 1 2 3 4 5; do
        remaining=0
        # Unknown or inaccessible ddnsto PIDs are never signalled, but prevent
        # replacement/startup. Otherwise migration could launch duplicates.
        for pid in $(pidof ddnsto 2>/dev/null); do remaining=1; done
        [ "$remaining" = 0 ] && return 0
        sleep 1
    done
    # No broad killall or forced kill. A resistant process blocks replacement.
    return 1
}

asus_service_start() {
    [ "$(asus_service_get ddnsto_enable)" = 1 ] || return 0
    asus_service_main && return 0
    [ -z "$(pidof ddnsto 2>/dev/null)" ] || return 1
    token=$(asus_service_get ddnsto_token) || return 1
    case "$token" in ''|*[!a-zA-Z0-9_-]*) return 1 ;; esac
    enabled=$(asus_service_get ddnsto_feat_enabled) || return 1
    user=$(asus_service_get ddnsto_feat_username) || return 1
    pass=$(asus_service_get ddnsto_feat_password) || return 1
    port=$(asus_service_get ddnsto_feat_port) || return 1
    disk=$(asus_service_get ddnsto_feat_disk_path_selected) || return 1
    set -- -u "$token" -d
    if [ "$enabled" = 1 ] && [ -n "$user" ] && [ -n "$pass" ] && [ -n "$port" ]; then
        case "$port" in *[!0-9]*|'') return 1 ;; esac
        [ "${#port}" -le 5 ] && [ "$port" -gt 0 ] && [ "$port" -le 65535 ] || return 1
        set -- "$@" -n "$user" -k "$pass" -p "$port" -s "${disk:-/}"
    fi
    "$service_binary" "$@" >/dev/null 2>&1
}

asus_service_json() {
    # Escape every control byte representable in shell strings, without eval.
    LC_ALL=C awk 'BEGIN {printf "\""; for(i=1;i<32;i++) ctrl[sprintf("%c",i)]=i}
        {if(NR>1) printf "\\n"; for(i=1;i<=length($0);i++) {
            c=substr($0,i,1)
            if(c=="\\" || c=="\"") printf "\\%s",c
            else if(c in ctrl) printf "\\u%04x",ctrl[c]
            else printf "%s",c
        }} END {printf "\""}'
}

asus_service_response() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#1}" -le 16 ] || return 1
    curl --noproxy '*' --connect-timeout 2 --max-time 5 -fsS \
        -H 'Content-Type: application/json' --data-binary "$2" \
        "http://127.0.0.1:3030/_resp/$1" >/dev/null
}

asus_service_router_id() (
    # config.go prints "%s %s\n", VERSION, RouterId for -w and exits before
    # connecting. identity/routerid.go derives ASUS IDs as 12 lowercase hex
    # digits. Never run the writable software-center binary or vendor scripts.
    query=/jffs/.ddnsto-installer/router-query.lock
    mkdir -m 700 "$query" 2>/dev/null || exit 1
    child=
    cleanup_query() {
        if [ -n "$child" ]; then
            kill -KILL "$child" 2>/dev/null || :
            wait "$child" 2>/dev/null || :
        fi
        rm -f "$query/output"
        rmdir "$query" 2>/dev/null || :
    }
    trap cleanup_query 0
    trap 'exit 1' 1 2 3 15
    # -f is in 512-byte or 1024-byte units across supported shells. Either
    # cap is <=1 KiB. Reject >128 bytes as well; no output reaches shell eval.
    (ulimit -c 0 && ulimit -f 1 && exec "$service_binary" -w) > "$query/output" 2>/dev/null &
    child=$!
    for probe in 1 2 3; do
        sleep 1
        kill -0 "$child" 2>/dev/null || break
    done
    # This PID is our directly spawned query, never a daemon discovered by name.
    if kill -0 "$child" 2>/dev/null; then exit 1; fi
    wait "$child" 2>/dev/null; result=$?
    child=
    [ "$result" = 0 ] || exit 1
    [ "$(wc -c < "$query/output")" -le 128 ] || exit 1
    LC_ALL=C awk '
        NR==1 && NF==2 && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+$/ &&
            length($2)==12 && $2 ~ /^[0-9a-f]+$/ { id=$2; valid=1 }
        END { if(NR!=1 || !valid) exit 1; print id }
    ' "$query/output"
)

asus_service_plugin_cd() {
    case "$1" in bin|scripts|init.d|webs|res) ;; *) return 1 ;; esac
    cd -P /jffs || return 1
    [ ! -L .koolshare ] && cd -P .koolshare || return 1
    [ "$(pwd -P)" = /jffs/.koolshare ] || return 1
    [ ! -L "$1" ] && cd -P "$1" || return 1
    [ "$(pwd -P)" = "/jffs/.koolshare/$1" ]
}

asus_service_owned_leaf() {
    case "$1" in Module_ddnsto.asp|icon-ddnsto.png)
        [ ! -L "./$1" ] && [ -f "./$1" ] &&
            cmp -s "./$1" "/jffs/.ddnsto-installer/current/$1" ;;
        *) [ -L "./$1" ] &&
            [ "$(readlink "./$1")" = "/jffs/.ddnsto-installer/current/$1" ] ;;
    esac
}

asus_service_uninstall() {
    # Explicit software-center uninstall only. Keep protected runtime and all
    # original backups; never call a vendor hook or enumerate wildcard paths.
    owned='bin/ddnsto scripts/ddnsto_config.sh scripts/ddnsto_status.sh scripts/uninstall_ddnsto.sh init.d/S70ddnsto.sh webs/Module_ddnsto.asp res/icon-ddnsto.png'
    for entry in $owned; do
        (asus_service_plugin_cd "${entry%/*}" &&
            asus_service_owned_leaf "${entry##*/}") || {
            printf '%s\n' 'ASUS: uninstall refused: plugin file ownership changed' >&2
            return 1
        }
    done
    asus_service_stop || return 1
    for entry in $owned; do
        (
            asus_service_plugin_cd "${entry%/*}" || exit 1
            leaf=${entry##*/}
            asus_service_owned_leaf "$leaf" || exit 1
            rm -f "./$leaf"
        ) || return 1
    done
    for key in ddnsto_token ddnsto_enable ddnsto_version ddnsto_client_version \
        ddnsto_feat_enabled ddnsto_feat_username ddnsto_feat_password \
        ddnsto_feat_port ddnsto_feat_disk_path_selected \
        softcenter_module_ddnsto_version softcenter_module_ddnsto_install \
        softcenter_module_ddnsto_name softcenter_module_ddnsto_title \
        softcenter_module_ddnsto_description; do
        /usr/bin/dbus remove "$key" || return 1
    done
}

asus_service_status() {
    request=$1
    case "$request" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#request}" -le 16 ] || return 1
    state=0 feat=0 pidtext=
    if asus_service_main; then
        state=1; pidtext=$main
        for pid in $(pidof ddnsto 2>/dev/null); do
            ident=$(asus_service_identity "$pid") || continue
            case "$ident" in *:"$main":*) feat=1 ;; esac
        done
    fi
    version=$(asus_service_get ddnsto_version | asus_service_json) || return 1
    username=$(asus_service_get ddnsto_feat_username | asus_service_json) || return 1
    port=$(asus_service_get ddnsto_feat_port | asus_service_json) || return 1
    router_id=$(asus_service_router_id) || router_id=
    asus_service_response "$request" "{\"version\":$version,\"status\":$state,\"router_id\":\"$router_id\",\"pid\":\"$pidtext\",\"feat\":{\"status\":\"$feat\",\"username\":$username,\"port\":$port,\"disk_path\":\"/webdav/\"}}"
}

# UI/autostart shares the installer lock. The trusted installer already owns
# it and uses explicit internal operations; status is read-only.
case "${1:-}" in
    start|stop|config|uninstall)
        mkdir -m 700 /jffs/.ddnsto-installer/install.lock 2>/dev/null || exit 16
        trap 'rmdir /jffs/.ddnsto-installer/install.lock 2>/dev/null || :' 0
        trap 'exit 1' 1 2 3 15 ;;
esac
case "${1:-}" in
    library) ;; # private installer/test source use; performs no action
    start|installer-start) asus_service_start ;;
    stop) asus_service_stop ;;
    migrate-stop) asus_service_stop legacy ;;
    running) asus_service_running ;;
    status) asus_service_status "${2:-}" ;;
    uninstall) asus_service_uninstall ;;
    config)
        case "${2:-}" in ''|*[!0-9]*) exit 2 ;; esac
        [ "${#2}" -le 16 ] || exit 2
        result=0
        asus_service_stop && asus_service_start || result=1
        asus_service_response "$2" "$2" || exit 1
        exit "$result" ;;
    *) exit 2 ;;
esac
ASUS_RUNTIME
}

_ddnsto_asus_prepare_runtime() (
    umask 077
    mkdir "$ASUS_ATTEMPT/runtime" || return 1
    ddnsto_asus_safe_file "$ASUS_ATTEMPT/payload/ddnsto" || return 1
    cp "$ASUS_ATTEMPT/payload/ddnsto" "$ASUS_ATTEMPT/runtime/ddnsto" || return 1
    chmod 700 "$ASUS_ATTEMPT/runtime/ddnsto" || return 1
    _ddnsto_asus_runtime > "$ASUS_ATTEMPT/runtime/service.sh" || return 1
    chmod 700 "$ASUS_ATTEMPT/runtime/service.sh" || return 1
    pins=$(ddnsto_asus_package "$ASUS_CHANNEL") || return 1
    printf '%s\n' "$pins" > "$ASUS_ATTEMPT/runtime/source-pin" || return 1
    digest=$(ddnsto_asus_hash "$ASUS_ATTEMPT/runtime/ddnsto") || return 1
    printf '%s\n' "$digest" > "$ASUS_ATTEMPT/runtime/binary.sha256" || return 1
)

# Read-only fast path, called after main's storage preflight and snapshot.
# No execution or sourcing of an installed hook; no new files or directories.
ddnsto_asus_reusable() (
    [ "$(ddnsto_asus_get ddnsto_version)" = 4.2.8 ] || return 1
    [ -L "$ASUS_STATE/current" ] || return 1
    runtime=$(readlink -f "$ASUS_STATE/current") || return 1
    case "$runtime" in "$ASUS_STATE"/*/runtime) ;; *) return 1 ;; esac
    for name in ddnsto service.sh source-pin binary.sha256 \
        ddnsto_config.sh ddnsto_status.sh uninstall_ddnsto.sh S70ddnsto.sh \
        Module_ddnsto.asp icon-ddnsto.png; do
        ddnsto_asus_safe_file "$runtime/$name" || return 1
    done
    [ -x "$runtime/ddnsto" ] || return 1
    pins=$(ddnsto_asus_package "$ASUS_CHANNEL") || return 1
    printf '%s\n' "$pins" | cmp -s "$runtime/source-pin" - || return 1
    digest=$(ddnsto_asus_hash "$runtime/ddnsto") || return 1
    printf '%s\n' "$digest" | cmp -s "$runtime/binary.sha256" - || return 1
    _ddnsto_asus_runtime | cmp -s "$runtime/service.sh" - || return 1
    for kind in config status uninstall init; do
        case "$kind" in config) leaf=ddnsto_config.sh ;; status) leaf=ddnsto_status.sh ;;
            uninstall) leaf=uninstall_ddnsto.sh ;; init) leaf=S70ddnsto.sh ;; esac
        _ddnsto_asus_bridge "$kind" | cmp -s "$runtime/$leaf" - || return 1
    done
    for entry in $(_ddnsto_asus_plugin_files); do
        (
            _ddnsto_asus_plugin_cd "${entry%/*}" || exit 1
            leaf=${entry##*/}
            case "$leaf" in Module_ddnsto.asp|icon-ddnsto.png)
                [ ! -L "$leaf" ] && [ -f "$leaf" ] && cmp -s "$leaf" "$runtime/$leaf" ;;
                *) [ -L "$leaf" ] && [ "$(readlink "$leaf")" = "$ASUS_STATE/current/$leaf" ] ;;
            esac
        ) || return 1
    done
)

_ddnsto_asus_bridge() {
    printf '%s\n' '#!/bin/sh' 'PATH=/usr/sbin:/usr/bin:/sbin:/bin' 'export PATH' \
        'unset ENV BASH_ENV CDPATH'
    case "$1" in
        config) printf '%s\n' 'case "${1:-}" in start|stop) action=$1; shift ;; *) action=config ;; esac' \
            'exec /bin/sh /jffs/.ddnsto-installer/current/service.sh "$action" "$@"' ;;
        status) printf '%s\n' 'exec /bin/sh /jffs/.ddnsto-installer/current/service.sh status "$@"' ;;
        uninstall) printf '%s\n' 'exec /bin/sh /jffs/.ddnsto-installer/current/service.sh uninstall' ;;
        init) printf '%s\n' 'case "${1:-start}" in start|stop) ;; *) exit 2 ;; esac' \
            'exec /bin/sh /jffs/.ddnsto-installer/current/service.sh "${1:-start}"' ;;
    esac
}

ddnsto_asus_install_plugin() (
    umask 077
    [ -f "$ASUS_ATTEMPT/backup/complete" ] || return 1
    ddnsto_asus_safe_file "$ASUS_ATTEMPT/runtime/ddnsto" &&
        ddnsto_asus_safe_file "$ASUS_ATTEMPT/runtime/service.sh" || return 1
    for name in Module_ddnsto.asp icon-ddnsto.png; do
        ddnsto_asus_safe_file "$ASUS_ATTEMPT/payload/$name" || return 1
        cp "$ASUS_ATTEMPT/payload/$name" "$ASUS_ATTEMPT/runtime/$name" || return 1
        chmod 644 "$ASUS_ATTEMPT/runtime/$name" || return 1
    done
    _ddnsto_asus_bridge config > "$ASUS_ATTEMPT/runtime/ddnsto_config.sh" || return 1
    _ddnsto_asus_bridge status > "$ASUS_ATTEMPT/runtime/ddnsto_status.sh" || return 1
    _ddnsto_asus_bridge init > "$ASUS_ATTEMPT/runtime/S70ddnsto.sh" || return 1
    _ddnsto_asus_bridge uninstall > "$ASUS_ATTEMPT/runtime/uninstall_ddnsto.sh" || return 1
    chmod 755 "$ASUS_ATTEMPT/runtime/ddnsto_config.sh" \
        "$ASUS_ATTEMPT/runtime/ddnsto_status.sh" "$ASUS_ATTEMPT/runtime/S70ddnsto.sh" \
        "$ASUS_ATTEMPT/runtime/uninstall_ddnsto.sh" || return 1
    mkdir "$ASUS_ATTEMPT/publish" || return 1
    ln -s "$ASUS_ATTEMPT/runtime" "$ASUS_ATTEMPT/publish/current" || return 1
    : > "$ASUS_ATTEMPT/changed/current"
    (cd -P "$ASUS_STATE" && _ddnsto_asus_publish "$ASUS_ATTEMPT/publish/current") || return 1
    for entry in $(_ddnsto_asus_plugin_files); do
        (
            _ddnsto_asus_plugin_cd "${entry%/*}" || exit 1
            leaf=${entry##*/}
            # Static UI files must remain readable by the firmware HTTP user.
            # Copy them to the anchored destination; protected runtime stays 0700.
            case "$leaf" in Module_ddnsto.asp|icon-ddnsto.png)
                cp "$ASUS_ATTEMPT/runtime/$leaf" "$ASUS_ATTEMPT/publish/$leaf" || exit 1
                chmod 644 "$ASUS_ATTEMPT/publish/$leaf" || exit 1 ;;
                *) ln -s "$ASUS_STATE/current/$leaf" "$ASUS_ATTEMPT/publish/$leaf" || exit 1 ;;
            esac
            : > "$ASUS_ATTEMPT/changed/$leaf"
            _ddnsto_asus_publish "$ASUS_ATTEMPT/publish/$leaf"
        ) || return 1
    done
    for key in ddnsto_version ddnsto_client_version softcenter_module_ddnsto_version \
        softcenter_module_ddnsto_install softcenter_module_ddnsto_name \
        softcenter_module_ddnsto_title softcenter_module_ddnsto_description; do
        case "$key" in
            *_version) value=4.2.8 ;; *_install) value=1 ;;
            *_name) value=ddnsto ;; *_title) value=DDNSTO ;;
            *_description) value='DDNSTO remote access' ;;
        esac
        : > "$ASUS_ATTEMPT/changed/$key"
        ddnsto_asus_set "$key" "$value" || return 1
    done
)

# Always emit a fresh protected runner, including before initial installation.
_ddnsto_asus_service_call() (
    umask 077
    ddnsto_asus_private_dir "$ASUS_ATTEMPT" || return 1
    runner=$(ddnsto_asus_mktemp "$ASUS_ATTEMPT") || return 1
    _ddnsto_asus_runtime > "$runner/service.sh" || return 1
    /bin/sh "$runner/service.sh" "$1"
)
ddnsto_asus_stop() { _ddnsto_asus_service_call migrate-stop; }
ddnsto_asus_start() { _ddnsto_asus_service_call installer-start; }
ddnsto_asus_running() { _ddnsto_asus_service_call running; }

ddnsto_asus_restore_plugin() (
    umask 077
    [ -f "$ASUS_ATTEMPT/backup/complete" ] || return 1
    ddnsto_asus_stop || return 1
    restore=$(ddnsto_asus_mktemp "$ASUS_ATTEMPT") || return 1
    for entry in $(_ddnsto_asus_plugin_files); do
        (
            leaf=${entry##*/}
            [ -f "$ASUS_ATTEMPT/changed/$leaf" ] || exit 0
            _ddnsto_asus_plugin_cd "${entry%/*}" || exit 1
            saved="$ASUS_ATTEMPT/backup/files/$leaf"
            if [ -e "$saved" ] || [ -L "$saved" ]; then
                cp -pP "$saved" "$restore/$leaf" || exit 1
                _ddnsto_asus_publish "$restore/$leaf" || exit 1
            else
                rm -f "./$leaf" || exit 1
            fi
        ) || return 1
    done
    recovery_conflict=0
    for key in $(_ddnsto_asus_metadata_keys); do
        [ -f "$ASUS_ATTEMPT/changed/$key" ] || continue
        case "$key" in ddnsto_token|ddnsto_enable)
            # Main journals the intended literal value BEFORE setting dbus.
            # Never overwrite account edits made outside our transaction.
            expected=$(cat "$ASUS_ATTEMPT/changed/$key") || return 1
            live=$(ddnsto_asus_get "$key") || return 1
            if [ "$live" != "$expected" ]; then
                recovery_conflict=1
                continue
            fi ;;
        esac
        value=$(cat "$ASUS_ATTEMPT/backup/config/$key") || return 1
        ddnsto_asus_set "$key" "$value" || return 1
    done
    if [ -f "$ASUS_ATTEMPT/changed/current" ]; then
        if [ -L "$ASUS_ATTEMPT/backup/current" ]; then
            cp -pP "$ASUS_ATTEMPT/backup/current" "$restore/current" || return 1
            (cd -P "$ASUS_STATE" && _ddnsto_asus_publish "$restore/current") || return 1
        elif [ "$(cat "$ASUS_ATTEMPT/backup/config/ddnsto_enable")" != 1 ]; then
            rm -f "$ASUS_STATE/current" || return 1
        fi
        # For native rollback the reviewed runtime remains available, while
        # original plugin files are restored byte-for-byte (never executed).
    fi
    if [ "$recovery_conflict" = 1 ]; then
        printf '%s\n' 'ASUS: recovery refused: concurrent account/enable change; external values preserved' >&2
        return 1
    fi
    if [ "$(cat "$ASUS_ATTEMPT/backup/config/ddnsto_enable")" = 1 ]; then
        if [ ! -L "$ASUS_STATE/current" ]; then
            ln -s "$ASUS_ATTEMPT/runtime" "$restore/current" || return 1
            (cd -P "$ASUS_STATE" && _ddnsto_asus_publish "$restore/current") || return 1
        fi
        ddnsto_asus_start && ddnsto_asus_running || return 1
    fi
)
