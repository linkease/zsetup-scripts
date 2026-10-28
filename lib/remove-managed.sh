# Owner implementation for user-scoped binary clients. No service operations.
remove_conflict() { printf 'Managed removal conflict: %s\n' "$*" >&2; exit 11; }
remove_plain_path() {
    installer_valid_directory "$1" || exit 2
    rp_path=$1
    while [ "$rp_path" != / ]; do
        [ ! -L "$rp_path" ] || remove_conflict 'symbolic link in directory path'
        rp_path=${rp_path%/*}; [ -n "$rp_path" ] || rp_path=/
    done
}
remove_main() {
    [ "$#" = 1 ] || exit 2
    app=$1
    case "$app" in linkspace|ks-cli|kspeeder) ;; *) exit 2 ;; esac
    : "${ZSETUP_BIN:?an existing canonical zsetup is required}"
    installer_scope=user
    installer_prefix=${ZSETUP_INSTALL_PREFIX:-}
    installer_layout "$app" user || exit $?
    remove_plain_path "$INSTALLER_PREFIX"
    remove_plain_path "${INSTALLER_COMMAND%/*}"
    # A completed removal is idempotent; foreign remnants are never deleted.
    if [ ! -e "$INSTALLER_PREFIX/.managed" ] && [ ! -L "$INSTALLER_PREFIX/.managed" ]; then
        for path in "$INSTALLER_PREFIX/versions" "$INSTALLER_PREFIX/current" "$INSTALLER_PREFIX/previous" "$INSTALLER_COMMAND"; do
            { [ ! -e "$path" ] && [ ! -L "$path" ]; } || remove_conflict 'installation has no ownership marker'
        done
        return 0
    fi
    [ -f "$INSTALLER_PREFIX/.managed" ] && [ ! -L "$INSTALLER_PREFIX/.managed" ] || remove_conflict 'invalid ownership marker'
    [ "$(wc -c < "$INSTALLER_PREFIX/.managed")" -le 65 ] || remove_conflict 'oversized ownership marker'
    [ "$(cat "$INSTALLER_PREFIX/.managed")" = "$app" ] || remove_conflict 'different application owner'
    [ "$("$ZSETUP_BIN" storage "$INSTALLER_PREFIX" get private_directory)" = true ] || remove_conflict 'prefix is not private and owned'
    INSTALLER_WORK_ROOT=${ZSETUP_WORK_DIR:-$INSTALLER_PREFIX/.staging}
    remove_plain_path "$INSTALLER_WORK_ROOT"
    installer_transaction_begin || exit $?
    command -v sha256sum >/dev/null 2>&1 || { printf 'Managed removal requires sha256sum for local integrity verification.\n' >&2; exit 127; }
    [ -d "$INSTALLER_PREFIX/versions" ] && [ ! -L "$INSTALLER_PREFIX/versions" ] || remove_conflict 'invalid versions directory'
    for version_dir in "$INSTALLER_PREFIX"/versions/* "$INSTALLER_PREFIX"/versions/.[!.]* "$INSTALLER_PREFIX"/versions/..?*; do
        [ -e "$version_dir" ] || [ -L "$version_dir" ] || continue
        version=${version_dir##*/}
        case "$version" in ''|.*|*[!a-zA-Z0-9._+-]*) remove_conflict 'invalid version identifier' ;; esac
        [ -d "$version_dir" ] && [ ! -L "$version_dir" ] && [ -d "$version_dir/bin" ] && [ ! -L "$version_dir/bin" ] || remove_conflict 'invalid version directory'
        binary="$version_dir/bin/$app"; marker="$binary.verified"
        for path in "$binary" "$marker"; do
            [ -f "$path" ] && [ ! -L "$path" ] || remove_conflict 'unverified program or marker'
        done
        [ "$(wc -c < "$marker")" -le 128 ] || remove_conflict 'oversized verification marker'
        record=$(cat "$marker"); digest=${record%%:*}; size=${record#*:}
        case "$digest" in ''|*[!0-9a-f]*) remove_conflict 'invalid digest' ;; esac
        [ "${#digest}" = 64 ] || remove_conflict 'invalid digest length'
        [ "$size" = "$(wc -c < "$binary" | tr -d ' ')" ] || remove_conflict 'program size changed'
        actual=$(sha256sum "$binary"); actual=${actual%% *}
        [ "$actual" = "$digest" ] || remove_conflict 'program bytes changed'
        # Refuse unknown files, including hidden entries, before any deletion.
        for path in "$version_dir"/* "$version_dir"/.[!.]* "$version_dir"/..?*; do
            [ -e "$path" ] || [ -L "$path" ] || continue
            [ "$path" = "$version_dir/bin" ] || remove_conflict 'unknown version contents'
        done
        for path in "$version_dir/bin"/* "$version_dir/bin"/.[!.]* "$version_dir/bin"/..?*; do
            [ -e "$path" ] || [ -L "$path" ] || continue
            case "$path" in "$binary"|"$marker") ;; *) remove_conflict 'unknown program contents' ;; esac
        done
    done
    for pointer in current previous; do
        path="$INSTALLER_PREFIX/$pointer"
        [ -e "$path" ] || [ -L "$path" ] || continue
        [ -L "$path" ] || remove_conflict 'foreign version pointer'
        target=$(readlink "$path")
        case "$target" in versions/*/bin/"$app") ;; *) remove_conflict 'foreign version pointer target' ;; esac
        version=${target#versions/}; version=${version%/bin/"$app"}
        case "$version" in ''|.*|*[!a-zA-Z0-9._+-]*) remove_conflict 'invalid pointer version' ;; esac
        [ -f "$INSTALLER_PREFIX/$target.verified" ] || remove_conflict 'unverified pointer target'
    done
    if [ -e "$INSTALLER_COMMAND" ] || [ -L "$INSTALLER_COMMAND" ]; then
        [ -L "$INSTALLER_COMMAND" ] && [ "$(readlink "$INSTALLER_COMMAND")" = "$INSTALLER_PREFIX/current" ] || remove_conflict 'foreign command entry'
    fi
    # Commit is bounded local filesystem work. Defer termination until its end;
    # never leave a half-unlinked version from a normal cancellation signal.
    trap '' HUP INT TERM
    rm -f "$INSTALLER_COMMAND" "$INSTALLER_PREFIX/current" "$INSTALLER_PREFIX/previous"
    for version_dir in "$INSTALLER_PREFIX"/versions/*; do
        [ -d "$version_dir" ] || continue
        rm "$version_dir/bin/$app" "$version_dir/bin/$app.verified"
        rmdir "$version_dir/bin" "$version_dir"
    done
    rmdir "$INSTALLER_PREFIX/versions"
    rm "$INSTALLER_PREFIX/.managed"
    installer_transaction_finish
    printf 'application=%s\nremoved=true\npreserved=config,data,cache\n' "$app"
}
remove_main "$@"
