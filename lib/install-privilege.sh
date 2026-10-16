# Only the optional sudo bootstrap uses OS copy/hash tools. Ordinary root
# installs and all business downloads/hashes continue to use canonical zsetup.
# The root coordinator owns its monitor and installer; EOF requests cancellation
# and it joins the installer (including rollback) before releasing bootstrap files.
installer_privilege_root_code() {
    cat <<'ZSETUP_ROOT_COORDINATOR'
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin; export PATH
umask 077
exec 5>&1
exec 1>&2
root_directory=; root_child=; root_monitor=; root_ready=0; root_cancel=0; root_spawning=0
root_signal() { root_cancel=$1; trap '' HUP INT TERM; [ "$root_spawning" = 1 ] || exit "$root_cancel"; }
root_finish() {
    root_result=$1
    trap - EXIT
    trap '' HUP INT TERM
    if [ -n "$root_child" ]; then kill -TERM "$root_child" 2>/dev/null || true; wait "$root_child" 2>/dev/null || true; root_child=; fi
    if [ -n "$root_monitor" ]; then kill -TERM "$root_monitor" 2>/dev/null || true; wait "$root_monitor" 2>/dev/null || true; root_monitor=; fi
    if [ -n "$root_directory" ]; then
        case "$root_directory" in /tmp/zsetup-privileged.*) rm -rf "$root_directory" || root_result=12 ;; *) root_result=12 ;; esac
    fi
    [ "$root_ready" = 1 ] || printf E >&5
    printf '%03d\n' "$root_result" >&5 || true
    exec 5>&-
    exit "$root_result"
}
trap 'root_finish $?' EXIT
trap 'root_signal 129' HUP
trap 'root_signal 130' INT
trap 'root_signal 143' TERM
[ "$(id -u)" = 0 ] && [ "$1" = "${SUDO_UID:-0}" ] || exit 2
root_caller=$1; root_native=$2; root_native_sha=$3; root_program=$4; root_program_sha=$5
root_ca=$6; root_ca_sha=$7; root_prepared=$8; root_os=$9
shift 9
root_pm=$1; root_arch=$2; root_bases=$3; root_fallback=$4; root_prefix=$5; root_version=$6
shift 6
root_directory=$(mktemp -d /tmp/zsetup-privileged.XXXXXX) || exit 12
root_parent=$$
IFS= read -r root_stat < "/proc/$root_parent/stat" || exit 12
set -f; set -- "$@" # do not expand proc text as filenames in the monitor
# Save business argv before inspecting /proc positional fields in a function.
root_cookie() { IFS= read -r rc_line < "/proc/$root_parent/stat" || return 1; set -- $rc_line; [ "$#" -ge 22 ] || return 1; shift 21; printf '%s\n' "$1"; }
root_birth=$(root_cookie) || exit 12
exec 6<&0
root_spawning=1
(
    trap 'exit 0' HUP INT TERM
    while IFS= read -r root_control; do
        [ "$root_control" = G ] && (set -C; : > "$root_directory/go") || break
    done
    # The root PID is held until normal monitor join. The birth guard also
    # avoids signalling an unrelated process after an exceptional root SIGKILL.
    if [ "$(root_cookie 2>/dev/null || true)" = "$root_birth" ]; then kill -TERM "$root_parent" 2>/dev/null || true; fi
) <&6 6<&- 5>&- &
root_monitor=$!
exec 6<&-
root_spawning=0
[ "$root_cancel" = 0 ] || exit "$root_cancel"
root_run() {
    root_spawning=1
    "$@" </dev/null 5>&- &
    root_child=$!
    root_spawning=0
    [ "$root_cancel" = 0 ] || exit "$root_cancel"
    root_status=0
    wait "$root_child" || root_status=$?
    root_child=
    return "$root_status"
}
root_copy_verified() {
    rcv_source=$1; rcv_target=$2; rcv_sha=$3; rcv_blocks=$4
    case "$rcv_sha" in ''|*[!0123456789abcdef]*) return 11 ;; esac
    [ "${#rcv_sha}" = 64 ] || return 11
    # Nonblocking open and a hard count also bound FIFO/device/race inputs.
    root_run dd "if=$rcv_source" "of=$rcv_target" bs=32768 "count=$rcv_blocks" iflag=nonblock 2>/dev/null || return 12
    if command -v sha256sum >/dev/null 2>&1; then
        root_run /bin/sh -c 'exec sha256sum "$1" > "$2"' hash "$rcv_target" "$root_directory/hash" || return 12
        IFS= read -r rcv_actual < "$root_directory/hash" || return 12
        rcv_actual=${rcv_actual%% *}
    elif command -v openssl >/dev/null 2>&1; then
        root_run /bin/sh -c 'exec openssl dgst -sha256 "$1" > "$2"' hash "$rcv_target" "$root_directory/hash" || return 12
        IFS= read -r rcv_actual < "$root_directory/hash" || return 12
        rcv_actual=${rcv_actual##*= }
    else printf '%s\n' 'Privilege bootstrap needs sha256sum or openssl; use the explicit root installer when unavailable.' >&2; return 2; fi
    [ "$rcv_actual" = "$rcv_sha" ] || return 11
}
root_copy_verified "$root_native" "$root_directory/zsetup" "$root_native_sha" 2049 || exit $?
root_copy_verified "$root_program" "$root_directory/install.sh" "$root_program_sha" 33 || exit $?
chmod 0755 "$root_directory/zsetup"
if [ -n "$root_ca" ]; then root_copy_verified "$root_ca" "$root_directory/ca.pem" "$root_ca_sha" 33 || exit $?; root_ca="$root_directory/ca.pem"; fi
printf R >&5
root_ready=1
while [ ! -f "$root_directory/go" ]; do sleep .05; done
# User data is argv/environment data. Neither a configuration expression nor
# the original user-writable installer/native is executed with root privileges.
root_run env -i PATH="$PATH" HOME=/root SUDO_UID="$root_caller" \
    ZSETUP_BIN="$root_directory/zsetup" ZSETUP_INSTALLER_MODE=1 \
    ZSETUP_OS="$root_os" ZSETUP_PACKAGE_MANAGER="$root_pm" ZSETUP_ARCH="$root_arch" \
    ZSETUP_SOURCE_BASES="$root_bases" ZSETUP_SOURCE_FALLBACK="$root_fallback" ZSETUP_CA_FILE="$root_ca" \
    ZSETUP_PRIVILEGED_STAGE="$root_prepared" DDNSTO_VERSION="$root_version" \
    /bin/sh "$root_directory/install.sh" --installer-prefix "$root_prefix" -- "$@" || exit $?
exit 0
ZSETUP_ROOT_COORDINATOR
}

installer_privilege_hash() {
    if command -v sha256sum >/dev/null 2>&1; then
        ip_hash=$(sha256sum "$1") || return 12
        INSTALLER_HASH=${ip_hash%% *}
    elif command -v openssl >/dev/null 2>&1; then
        ip_hash=$(openssl dgst -sha256 "$1") || return 12
        INSTALLER_HASH=${ip_hash##*= }
    else
        printf '%s\n' 'Automatic privilege bootstrap needs sha256sum or openssl; run the installer explicitly as root instead.' >&2
        return 2
    fi
}

# The ordinary-user coordinator owns preparation and its sudo transport. Root
# owns privileged children; closing control requests root cancellation/join.
installer_privilege_read() {
    ip_read_count=$1
    installer_exec_native "$ZSETUP_BIN" capture -o "$transaction_dir/bridge-read" --max-bytes "$ip_read_count" --timeout 60s -- \
        dd "if=$transaction_dir/status" bs=1 "count=$ip_read_count" iflag=fullblock || return $?
    installer_file_size "$transaction_dir/bridge-read" || return 12
    [ "$INSTALLER_FILE_SIZE" = "$ip_read_count" ] || return 12
}

installer_privilege_result() {
    installer_privilege_read 4 || return $?
    ip_transport_only=0
    case "$(cat "$transaction_dir/bridge-read")" in
        T*)
            # A sudo transport exit after ready without a root result is a
            # protocol failure, but it must still be reaped before cleanup.
            ip_transport_code=$(cat "$transaction_dir/bridge-read")
            ip_transport_code=${ip_transport_code#T}
            installer_privilege_read 1 || return $?
            printf '%s\n' "$ip_transport_code" > "$transaction_dir/bridge-read"
            ip_transport_only=1
            ;;
    esac
    IFS= read -r ip_result < "$transaction_dir/bridge-read" || return 12
    case "$ip_result" in [012][0123456789][0123456789]) ;; *) return 12 ;; esac
    # decimal conversion without shell-dependent octal interpretation
    ip_h=${ip_result%??}; ip_t=${ip_result#?}; ip_t=${ip_t%?}; ip_o=${ip_result#??}
    INSTALLER_ROOT_RESULT=$((ip_h * 100 + ip_t * 10 + ip_o))
    [ "$INSTALLER_ROOT_RESULT" -le 255 ] || return 12
    INSTALLER_ROOT_ACK=1
    [ "$ip_transport_only" = 0 ] || return 12
}

installer_privilege_transport() {
    # A distinct ordinary-user owner reaps sudo even when its command policy
    # refuses startup before the root protocol exists. Caught signals interrupt
    # wait; repeat wait until the owned child actually exits.
    ip_transport_signal=0
    trap 'ip_transport_signal=1' HUP INT TERM
    exec 6<&0
    /usr/bin/sudo -n "$@" <&6 6<&- &
    ip_transport_pid=$!
    exec 6<&-
    while :; do
        ip_transport_exit=0
        wait "$ip_transport_pid" || ip_transport_exit=$?
        if [ "$ip_transport_signal" = 1 ]; then ip_transport_signal=0; continue; fi
        break
    done
    printf 'T%03d\n' "$ip_transport_exit" || true
    return "$ip_transport_exit"
}

installer_privilege_cleanup() {
    if [ "${INSTALLER_BRIDGE_OPEN:-0}" = 1 ]; then
        exec 3>&-
        # EOF is the only request across UIDs. Never kill the root coordinator
        # before its rollback/native operations have joined.
        if [ "$INSTALLER_ROOT_ACK" = 0 ]; then installer_privilege_result || return 1; fi
        ip_sudo_status=0
        wait "$INSTALLER_SUDO_PID" || ip_sudo_status=$?
        INSTALLER_SUDO_PID=
        exec 4>&-
        INSTALLER_BRIDGE_OPEN=0
        [ "$ip_sudo_status" = "$INSTALLER_ROOT_RESULT" ] || return 1
    fi
}

installer_privilege_install() {
    ip_app=$1; shift
    [ -x /usr/bin/sudo ] && /usr/bin/sudo -n true || {
        printf '%s\n' 'Installer: system service needs sudo credentials. Run sudo -v in a terminal and retry, or invoke the installer explicitly as root. No password prompt was started.' >&2
        return 2
    }
    installer_layout "$ip_app" system || return $?
    [ "$INSTALLER_SCOPE" = system ] || return 2
    installer_policy "$ip_app" || return $?
    installer_space_budget "$INSTALLER_MAX_DOWNLOAD" "$INSTALLER_MAX_EXPANDED" "$INSTALLER_MAX_EXPANDED" "$INSTALLER_MAX_DOWNLOAD" || return $?
    installer_storage_select "$INSTALLER_PREFIX" "$INSTALLER_REQUIRED_BYTES" 1 0 || return $?
    INSTALLER_PREFIX=$INSTALLER_STORAGE_PATH
    [ "$("$ZSETUP_BIN" storage "$INSTALLER_PREFIX" get system_protected)" = true ] || return 12
    INSTALLER_WORK_ROOT=${installer_work_dir:-${ZSETUP_WORK_DIR:-$HOME/.local/state/linkease/$ip_app/.staging}}
    installer_valid_directory "$INSTALLER_WORK_ROOT" || return $?
    installer_storage_select "$INSTALLER_WORK_ROOT" "$INSTALLER_REQUIRED_BYTES" 1 1 || return $?
    INSTALLER_WORK_ROOT=$INSTALLER_STORAGE_PATH
    printf 'Prepare as uid=%s: prefix=%s staging=%s; privileged commit uses protected prefix/.staging\n' "$ip_uid" "$INSTALLER_PREFIX" "$INSTALLER_WORK_ROOT" >&2
    installer_transaction_begin || return $?
    # Shared metadata/version selection, no extracted business program executes
    # under the ordinary account during preparation.
    SERVICE_APP=$ip_app
    "${ip_app}_linux_metadata" || return $?
    case "$ip_app" in
        ddnsto)
            installer_service_cached "$version_num" "$digest" || return $?
            [ "$SERVICE_CACHED" = 1 ] || installer_download "linux-binary/$archive_name" "$transaction_dir/$archive_name" "$digest" || return $?
            set -- --token "$TOKEN"
            ;;
        linkease)
            installer_service_cached "$version_num" "$le_archive_sha:$le_mount_sha" || return $?
            if [ "$SERVICE_CACHED" = 0 ]; then
                installer_download "$relative_folder/$archive_name" "$transaction_dir/$archive_name" "$le_archive_sha" || return $?
                installer_download "$relative_folder/$mount_name" "$transaction_dir/$mount_name" "$le_mount_sha" || return $?
            fi
            set -- --version "$version_num"
            ;;
        *) return 2 ;;
    esac
    installer_privileged_program > "$transaction_dir/root-program" || return 12
    installer_privilege_hash "$ZSETUP_BIN" || return $?
    ip_native_sha=$INSTALLER_HASH
    installer_privilege_hash "$transaction_dir/root-program" || return $?
    ip_program_sha=$INSTALLER_HASH
    ip_ca_sha=
    if [ -n "${ZSETUP_CA_FILE:-}" ]; then installer_privilege_hash "$ZSETUP_CA_FILE" || return $?; ip_ca_sha=$INSTALLER_HASH; fi
    mkfifo "$transaction_dir/control" "$transaction_dir/status" || return 12
    exec 3<> "$transaction_dir/control"
    exec 4<> "$transaction_dir/status"
    INSTALLER_BRIDGE_OPEN=1; INSTALLER_ROOT_ACK=0; INSTALLER_SUDO_PID=
    INSTALLER_CLEANUP_HOOK=installer_privilege_cleanup
    INSTALLER_SPAWNING=1
    (
    # Close permanently in this subshell. Redirecting a shell function's FD3
    # alone saves a hidden restoration descriptor and keeps the control writer
    # alive, preventing root from observing cancellation EOF.
    exec 3>&- 4>&-
    installer_privilege_transport /bin/sh -eu -c "$(installer_privilege_root_code)" zsetup-root \
        "$ip_uid" "$ZSETUP_BIN" "$ip_native_sha" "$transaction_dir/root-program" "$ip_program_sha" \
        "${ZSETUP_CA_FILE:-}" "$ip_ca_sha" "$transaction_dir" "$os" "$package_manager" "$arch" \
        "$ZSETUP_SOURCE_BASES" "${ZSETUP_SOURCE_FALLBACK:-}" "$INSTALLER_PREFIX" "${DDNSTO_VERSION:-}" "$@" \
    ) < "$transaction_dir/control" > "$transaction_dir/status" &
    INSTALLER_SUDO_PID=$!
    INSTALLER_SPAWNING=0
    [ "$INSTALLER_SIGNAL" = 0 ] || exit "$INSTALLER_SIGNAL"
    installer_privilege_read 1 || return $?
    ip_ready=$(cat "$transaction_dir/bridge-read")
    case "$ip_ready" in
        R) printf 'G\n' >&3 ;;
        E) installer_privilege_result || return $?; return "$INSTALLER_ROOT_RESULT" ;;
        T) installer_privilege_result || return $?; return 2 ;;
        *) return 12 ;;
    esac
    installer_privilege_result || return $?
    ip_return=$INSTALLER_ROOT_RESULT
    installer_transaction_finish || return $?
    return "$ip_return"
}
