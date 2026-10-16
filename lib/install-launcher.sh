# Common options precede business arguments; -- ends installer parsing.
installer_dispatch() {
    il_app=$1; shift
    installer_scope=${ZSETUP_INSTALL_SCOPE:-}
    installer_prefix=${ZSETUP_INSTALL_PREFIX:-}
    installer_work_dir=
    il_seen_scope=0; il_seen_prefix=0; il_seen_work=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --installer-scope|--installer-prefix|--installer-work-dir)
                [ "$#" -ge 2 ] && [ -n "$2" ] || return 2
                case "$1" in
                    --installer-scope) [ "$il_seen_scope" = 0 ] || return 2; installer_scope=$2; il_seen_scope=1 ;;
                    --installer-prefix) [ "$il_seen_prefix" = 0 ] || return 2; installer_prefix=$2; il_seen_prefix=1 ;;
                    *) [ "$il_seen_work" = 0 ] || return 2; installer_work_dir=$2; il_seen_work=1 ;;
                esac
                shift 2 ;;
            --) shift; break ;;
            --installer-*) printf 'Unknown installer option: %s\n' "$1" >&2; return 2 ;;
            *) break ;;
        esac
    done
    "${il_app}_install" "$@"
}

installer_launcher_prepare() {
    il_application=$1
    case "$1" in fastnet) il_display=FastNet ;; fastpve) il_display=FastPVE ;; *) il_display=$1 ;; esac
    il_work_hint=${installer_work_dir:-${ZSETUP_WORK_DIR:-}}
    [ -z "$il_work_hint" ] || [ ! -L "$il_work_hint" ] || return 2
    installer_policy "$1" || return $?
    installer_preflight "$1" "$2" "$INSTALLER_REQUIRED_BYTES" 1 || return $?
    [ "$INSTALLER_SCOPE" != system ] || INSTALLER_COMMAND="$INSTALLER_PREFIX/current"
    [ ! -L "$INSTALLER_PREFIX" ] || return 2
    umask 077
    mkdir -p "$INSTALLER_PREFIX"
    [ "$("$ZSETUP_BIN" storage "$INSTALLER_PREFIX" get private_directory)" = true ] || return 12
    [ ! -L "$INSTALLER_PREFIX/.managed" ] && [ ! -L "$INSTALLER_PREFIX/versions" ] || return 2
    il_owner=
    if [ -f "$INSTALLER_PREFIX/.managed" ] && [ ! -L "$INSTALLER_PREFIX/.managed" ]; then
        installer_file_size "$INSTALLER_PREFIX/.managed" || return 2
        [ "$INSTALLER_FILE_SIZE" -le 65 ] || return 2
        IFS= read -r il_owner < "$INSTALLER_PREFIX/.managed" || return 2
        [ "$il_owner" = "$1" ] || return 2
    else
        [ ! -e "$INSTALLER_PREFIX/versions" ] && [ ! -L "$INSTALLER_PREFIX/current" ] && [ ! -e "$INSTALLER_PREFIX/current" ] || return 2
        (set -C; printf '%s\n' "$1" > "$INSTALLER_PREFIX/.managed") || return 2
    fi
    if [ "$INSTALLER_SCOPE" = user ]; then
        if [ -e "$INSTALLER_COMMAND" ] || [ -L "$INSTALLER_COMMAND" ]; then
            [ -L "$INSTALLER_COMMAND" ] && [ "$(readlink "$INSTALLER_COMMAND")" = "$INSTALLER_PREFIX/current" ] || {
                printf 'Installer: existing command belongs to another installation: %s\n' "$INSTALLER_COMMAND" >&2; return 2;
            }
        fi
    fi
    installer_transaction_begin || return $?
    INSTALLER_CLEANUP_HOOK=installer_launcher_cleanup
    il_candidate=
    il_new_version=0
    il_activated=0
    il_previous=
    mkdir -p "$INSTALLER_PREFIX/versions"
}

installer_launcher_cleanup() {
    if [ "$il_activated" = 1 ]; then
        if [ -n "$il_previous" ]; then
            ln -s "$il_previous" "$INSTALLER_PREFIX/.restore.$$" || return 1
            mv -f "$INSTALLER_PREFIX/.restore.$$" "$INSTALLER_PREFIX/current" || return 1
        else
            rm -f "$INSTALLER_PREFIX/current" || return 1
        fi
        il_activated=0
    fi
    [ -z "$il_candidate" ] || rm -f "$il_candidate" || return 1
    if [ "$il_new_version" = 1 ]; then rm -rf "$il_version_dir" || return 1; fi
    rm -f "$INSTALLER_PREFIX/.current.$$" "$INSTALLER_PREFIX/.previous.$$"
}

installer_launcher_activate() {
    il_version=$1; il_remote_name=$2; il_sha=$3
    il_version_dir="$INSTALLER_PREFIX/versions/$il_version"
    INSTALLER_EXECUTABLE="$il_version_dir/bin/$il_application"
    il_marker="$INSTALLER_EXECUTABLE.verified"
    [ ! -L "$il_version_dir" ] && [ ! -L "$il_version_dir/bin" ] || return 2
    for il_path in "$INSTALLER_EXECUTABLE" "$il_marker"; do
        [ ! -L "$il_path" ] && { [ ! -e "$il_path" ] || [ -f "$il_path" ]; } || return 2
    done
    il_cached=0
    if [ -x "$INSTALLER_EXECUTABLE" ] && [ -f "$il_marker" ]; then
        installer_file_size "$INSTALLER_EXECUTABLE" || return $?
        il_payload_size=$INSTALLER_FILE_SIZE
        [ "$il_payload_size" -le "$INSTALLER_MAX_DOWNLOAD" ] || return 11
        installer_file_size "$il_marker" || return 2
        [ "$INSTALLER_FILE_SIZE" -le 128 ] || return 2
        il_record=
        IFS= read -r il_record < "$il_marker" || il_record=
        il_old_sha=${il_record%%:*}
        case "$il_old_sha" in *[!0123456789abcdef]*|'') ;;
            *) if [ "${#il_old_sha}" = 64 ] && [ "$il_old_sha" != "$il_sha" ]; then
                printf 'Installer: installed version %s has a different digest; immutable versions cannot be replaced.\n' "$il_version" >&2
                return 11
            fi ;;
        esac
        if [ "$il_record" = "$il_sha:$il_payload_size" ]; then il_cached=1; fi
    fi
    if [ "$il_cached" = 1 ]; then
        status "[3/4] $il_display is already downloaded (verified cached version)"
        installer_exec_native "$ZSETUP_BIN" run -- "$INSTALLER_EXECUTABLE" version || return $?
    else
        status "[3/4] Downloading $il_display..."
        installer_download "$il_remote_name" "$transaction_dir/product" "$il_sha" || return $?
        chmod 0755 "$transaction_dir/product"
        installer_exec_native "$ZSETUP_BIN" run -- "$transaction_dir/product" version || return $?
        if [ ! -d "$il_version_dir" ]; then
            mkdir "$il_version_dir" || return 12
            il_new_version=1
        fi
        mkdir -p "$il_version_dir/bin"
        il_candidate="$il_version_dir/bin/.candidate.$$"
        installer_exec_native "$ZSETUP_BIN" capture -o "$il_candidate" --max-bytes "$INSTALLER_MAX_DOWNLOAD" --min-free-bytes "$INSTALLER_RESERVE" -- cat "$transaction_dir/product" || return $?
        chmod 0755 "$il_candidate"
        installer_file_size "$il_candidate" || return $?
        printf '%s:%s\n' "$il_sha" "$INSTALLER_FILE_SIZE" > "$transaction_dir/verified"
        mv -f "$il_candidate" "$INSTALLER_EXECUTABLE" || return 12
        il_candidate=
        mv -f "$transaction_dir/verified" "$il_marker" || return 12
    fi
    installer_storage_check "$INSTALLER_PREFIX" "$INSTALLER_RESERVE" 1 1 || return $?
    if [ -e "$INSTALLER_PREFIX/current" ] || [ -L "$INSTALLER_PREFIX/current" ]; then
        [ -L "$INSTALLER_PREFIX/current" ] && [ -f "$INSTALLER_PREFIX/current" ] || return 2
        il_previous=$(readlink "$INSTALLER_PREFIX/current") || return 2
        case "$il_previous" in versions/*/bin/"$il_application") ;; *) return 2 ;; esac
        il_old_version=${il_previous#versions/}; il_old_version=${il_old_version%/bin/"$il_application"}
        case "$il_old_version" in ''|*[!0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._+-]*|.*) return 2 ;; esac
    fi
    ln -s "versions/$il_version/bin/$il_application" "$INSTALLER_PREFIX/.current.$$" || return 12
    il_activated=1
    mv -f "$INSTALLER_PREFIX/.current.$$" "$INSTALLER_PREFIX/current" || return 12
    if [ "$INSTALLER_SCOPE" = user ]; then
        mkdir -p "${INSTALLER_COMMAND%/*}"
        il_candidate="${INSTALLER_COMMAND%/*}/.$il_application.$$"
        ln -s "$INSTALLER_PREFIX/current" "$il_candidate" || return 12
        mv -f "$il_candidate" "$INSTALLER_COMMAND" || return 12
        il_candidate=
    fi
    if [ -n "$il_previous" ] && [ "$il_previous" != "versions/$il_version/bin/$il_application" ]; then
        ln -s "$il_previous" "$INSTALLER_PREFIX/.previous.$$" || return 12
        mv -f "$INSTALLER_PREFIX/.previous.$$" "$INSTALLER_PREFIX/previous" || return 12
    fi
    il_keep=$(readlink "$INSTALLER_PREFIX/current")
    il_keep_old=$(readlink "$INSTALLER_PREFIX/previous" 2>/dev/null || true)
    for il_dir in "$INSTALLER_PREFIX"/versions/*; do
        [ -d "$il_dir" ] && [ ! -L "$il_dir" ] || continue
        il_target="versions/${il_dir##*/}/bin/$il_application"
        [ "$il_target" != "$il_keep" ] && [ "$il_target" != "$il_keep_old" ] || continue
        [ -f "$il_dir/bin/$il_application.verified" ] && [ ! -L "$il_dir/bin/$il_application.verified" ] || continue
        rm -rf "$il_dir" || return 12
    done
    il_activated=0
    il_new_version=0
}
