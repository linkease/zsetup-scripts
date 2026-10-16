# Native packages own their installed paths and services. Only their verified
# inputs, PM scratch/cache/list data and bounded receipts are managed here.
installer_package_prepare() {
    PACKAGE_APP=$1; PACKAGE_PHASE=preflight
    PACKAGE_CACHE=; INSTALLER_PACKAGE_CLEANUP=
    PACKAGE_DEST_LOCK_HELD=0
    installer_require_root || return $?
    installer_layout "$1" system || return $?
    [ "$INSTALLER_SCOPE" = system ] || return 2
    installer_policy "$1" || return $?
    # A package target cannot be relocated by changing the download directory.
    installer_storage_check / "$INSTALLER_REQUIRED_BYTES" 1 1 || {
        printf '%s\n' 'Installer: native package target / is unsuitable; moving its download cache does not relocate package-owned files. Keep the legacy entry until the system target is verified.' >&2
        return 12
    }
    installer_preflight "$1" system "$INSTALLER_REQUIRED_BYTES" 1 || return $?
    for ip_path in "$INSTALLER_PREFIX" "$INSTALLER_WORK_ROOT"; do
        [ "$("$ZSETUP_BIN" storage "$ip_path" get system_protected)" = true ] || return 12
    done
    [ ! -L "$INSTALLER_PREFIX/.managed" ] && [ ! -L "$INSTALLER_PREFIX/.package-manager" ] || return 2
    if [ -f "$INSTALLER_PREFIX/.managed" ]; then
        for ip_marker in "$INSTALLER_PREFIX/.managed" "$INSTALLER_PREFIX/.package-manager"; do
            [ "$("$ZSETUP_BIN" storage "$ip_marker" get system_protected)" = true ] || return 12
        done
        installer_file_size "$INSTALLER_PREFIX/.managed" || return 2
        [ "$INSTALLER_FILE_SIZE" -le 65 ] || return 2
        IFS= read -r ip_owner < "$INSTALLER_PREFIX/.managed" || return 2
        [ "$ip_owner" = "$PACKAGE_APP" ] || return 2
        installer_file_size "$INSTALLER_PREFIX/.package-manager" || return 2
        [ "$INSTALLER_FILE_SIZE" -le 8 ] || return 2
        IFS= read -r ip_manager < "$INSTALLER_PREFIX/.package-manager" || return 2
        [ "$ip_manager" = "$package_manager" ] || return 2
    else
        for ip_entry in "$INSTALLER_PREFIX"/* "$INSTALLER_PREFIX"/.[!.]* "$INSTALLER_PREFIX"/..?*; do
            [ ! -e "$ip_entry" ] && [ ! -L "$ip_entry" ] || return 2
        done
        umask 022
        mkdir -p "$INSTALLER_PREFIX" || return 12
        (set -C; printf '%s\n' "$PACKAGE_APP" > "$INSTALLER_PREFIX/.managed") || return 2
        (set -C; printf '%s\n' "$package_manager" > "$INSTALLER_PREFIX/.package-manager") || return 2
    fi
    [ ! -L "$INSTALLER_PREFIX/package-result" ] && [ ! -L "$INSTALLER_PREFIX/.packages" ] || return 2
    installer_transaction_begin || return $?
    INSTALLER_CLEANUP_HOOK=installer_package_cleanup
    if ! mkdir "$INSTALLER_PREFIX/.package-lock" 2>/dev/null; then
        printf 'Installer: active or interrupted destination transaction at %s/.package-lock\n' "$INSTALLER_PREFIX" >&2
        return 2
    fi
    PACKAGE_DEST_LOCK_HELD=1
    printf '%s\n' "$$" > "$INSTALLER_PREFIX/.package-lock/owner"
    mkdir -p "$transaction_dir/pm-tmp" "$transaction_dir/pm-cache" "$transaction_dir/pm-lists"
    # PMs and their maintainer scripts use disk scratch, rather than default /tmp.
    TMPDIR="$transaction_dir/pm-tmp"; export TMPDIR
    for ip_existing in "/usr/bin/$PACKAGE_APP" "/usr/sbin/$PACKAGE_APP" "/usr/local/bin/$PACKAGE_APP"; do
        [ -e "$ip_existing" ] || [ -L "$ip_existing" ] || continue
        if [ "$package_manager" = opkg ]; then
            installer_exec_native "$ZSETUP_BIN" capture -o "$transaction_dir/owner" --max-bytes 4096 --timeout 5s -- opkg search "$ip_existing" || return 2
            ip_count=0
            while IFS= read -r ip_line; do
                case "$ip_line" in "$PACKAGE_APP - "*) ip_count=$((ip_count + 1)) ;; *) return 2 ;; esac
            done < "$transaction_dir/owner"
            [ "$ip_count" = 1 ] || return 2
        else
            installer_exec_native "$ZSETUP_BIN" capture -o "$transaction_dir/owner" --max-bytes 4096 --timeout 5s -- apk info --who-owns "$ip_existing" || return 2
            IFS= read -r ip_line < "$transaction_dir/owner" || return 2
            case "$ip_line" in "$ip_existing is owned by $PACKAGE_APP-"*) ;; *) return 2 ;; esac
        fi
    done
    PACKAGE_PHASE=download
}

installer_package_cache() {
    installer_service_version "$1" || return 2
    case "$2" in x86_64|aarch64|armv7|arm|mipsel) ;; *) return 2 ;; esac
    ip_cache_root="$INSTALLER_PREFIX/.packages"
    ip_key="$package_manager-$1-$2"
    ip_previous=
    [ ! -L "$ip_cache_root/recent" ] || return 2
    if [ -f "$ip_cache_root/recent" ]; then
        installer_file_size "$ip_cache_root/recent" || return 2
        [ "$INSTALLER_FILE_SIZE" -le 128 ] || return 2
        IFS= read -r ip_previous < "$ip_cache_root/recent" || return 2
        case "$ip_previous" in ''|*[!0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._+-]*|.*) return 2 ;; esac
    fi
    PACKAGE_CACHE="$ip_cache_root/$ip_key"
    [ ! -L "$PACKAGE_CACHE" ] || return 2
    mkdir -p "$PACKAGE_CACHE" || return 12
    [ "$("$ZSETUP_BIN" storage "$PACKAGE_CACHE" get system_protected)" = true ] || return 12
    [ ! -L "$PACKAGE_CACHE/.owned" ] || return 2
    if [ -e "$PACKAGE_CACHE/.owned" ]; then
        [ "$("$ZSETUP_BIN" storage "$PACKAGE_CACHE/.owned" get system_protected)" = true ] || return 12
        installer_file_size "$PACKAGE_CACHE/.owned" || return 2
        [ "$INSTALLER_FILE_SIZE" -le 65 ] || return 2
        IFS= read -r ip_owner < "$PACKAGE_CACHE/.owned" || return 2
        [ "$ip_owner" = "$PACKAGE_APP" ] || return 2
    else
        (set -C; printf '%s\n' "$PACKAGE_APP" > "$PACKAGE_CACHE/.owned") || return 12
    fi
    # Keep the current and preceding attempt, including verified recovery inputs
    # after a partial PM failure. Never pretend this rolls back package scripts.
    for ip_old in "$ip_cache_root"/*; do
        [ -d "$ip_old" ] && [ ! -L "$ip_old" ] || continue
        [ "${ip_old##*/}" != "$ip_key" ] && [ "${ip_old##*/}" != "$ip_previous" ] || continue
        installer_file_size "$ip_old/.owned" || continue
        [ "$INSTALLER_FILE_SIZE" -le 65 ] || continue
        IFS= read -r ip_owner < "$ip_old/.owned" || continue
        [ "$ip_owner" != "$PACKAGE_APP" ] || rm -rf "$ip_old" || return 12
    done
    printf '%s\n' "$ip_key" > "$transaction_dir/recent"
    mv -f "$transaction_dir/recent" "$ip_cache_root/recent" || return 12
}

installer_package_command() {
    installer_storage_check / "$INSTALLER_RESERVE" 1 1 || return $?
    installer_storage_check "$INSTALLER_WORK_ROOT" "$INSTALLER_RESERVE" 0 1 || return $?
    PACKAGE_PHASE=$1; shift
    ip_query_output=
    if [ "$PACKAGE_PHASE" = query ]; then ip_query_output=$1; shift; fi
    case "$package_manager" in
        opkg) set -- opkg --cache "$transaction_dir/pm-cache" --tmp-dir "$transaction_dir/pm-tmp" --lists-dir "$transaction_dir/pm-lists" "$@" ;;
        apk) set -- apk --cache-dir "$transaction_dir/pm-cache" "$@" ;;
        *) return 2 ;;
    esac
    if [ -n "$ip_query_output" ]; then
        installer_exec_native "$ZSETUP_BIN" capture -o "$ip_query_output" --max-bytes 4096 --min-free-bytes "$INSTALLER_RESERVE" --timeout 5s -- "$@"
    else
        installer_exec_native "$ZSETUP_BIN" run -- "$@"
    fi
}

installer_package_immutable() {
    ip_marker=$1; ip_expected=$2
    [ ! -L "$ip_marker" ] || return 2
    if [ -f "$ip_marker" ]; then
        installer_file_size "$ip_marker" || return 2
        [ "$INSTALLER_FILE_SIZE" -le 128 ] || return 2
        IFS= read -r ip_record < "$ip_marker" || return 2
        ip_digest=${ip_record%%:*}
        case "$ip_digest" in ''|*[!0123456789abcdef]*) return 11 ;; esac
        [ "${#ip_digest}" = 64 ] && [ "$ip_digest" = "$ip_expected" ] || return 11
    fi
}

installer_package_cleanup() {
    [ "$PACKAGE_DEST_LOCK_HELD" = 1 ] || return 0
    [ -z "$INSTALLER_PACKAGE_CLEANUP" ] || "$INSTALLER_PACKAGE_CLEANUP" || return 1
    printf 'application=%s\nmanager=%s\nphase=%s\nexit=%s\npackage_rollback=not_guaranteed\n' \
        "$PACKAGE_APP" "$package_manager" "$PACKAGE_PHASE" "${INSTALLER_EXIT_CODE:-0}" > "$INSTALLER_PREFIX/.package-result.$$" || return 1
    mv -f "$INSTALLER_PREFIX/.package-result.$$" "$INSTALLER_PREFIX/package-result" || return 1
    rm -f "$INSTALLER_PREFIX/.package-lock/owner" || return 1
    rmdir "$INSTALLER_PREFIX/.package-lock" || return 1
    PACKAGE_DEST_LOCK_HELD=0
}
