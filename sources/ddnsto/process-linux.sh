# Plain Linux fallback: no supervisor, privilege escalation or persistence promise.
ddnsto_process_needed() {
    [ ! -d /run/systemd/system ] || ! command -v systemctl >/dev/null 2>&1
}

ddnsto_process_paths() {
    PROCESS_PREFIX=${HOME:-}/.local/share/ddnsto
    case "${HOME:-}" in /*) ;; *) return 12 ;; esac
    case "$HOME" in *'
'*|*"$(printf '\r')"*) return 12 ;; esac
    process_home=$(CDPATH= cd -P -- "$HOME" && pwd -P) || return 12
    [ "$process_home" != / ] || return 12
    PROCESS_PREFIX=$process_home/.local/share/ddnsto
}

ddnsto_process_error() {
    ddnsto_flow_error "$1" "$2" "请检查 $PROCESS_PREFIX；启动输出在 startup.log，不会接管其他进程" || :
}

ddnsto_process_private() {
    [ -d "$1" ] && [ ! -L "$1" ] &&
        [ "$("$ZSETUP_BIN" storage "$1" get private_directory)" = true ]
}

ddnsto_process_storage() {
    # Check the nearest existing parent before creating ~/.local/share; never
    # follow a writable/foreign/symlink parent or chmod an existing directory.
    process_parent=${PROCESS_PREFIX%/*}
    process_existing=$process_parent
    while [ ! -e "$process_existing" ] && [ ! -L "$process_existing" ]; do
        process_existing=${process_existing%/*}
        [ -n "$process_existing" ] || process_existing=/
    done
    ddnsto_bootstrap_safe_ancestors "$process_existing" || return 12
    (umask 077; mkdir -p "$process_parent") || return 12
    ddnsto_bootstrap_safe_ancestors "$process_parent" || return 12
    [ ! -L "$PROCESS_PREFIX" ] || return 12
    if [ ! -e "$PROCESS_PREFIX" ]; then (umask 077; mkdir "$PROCESS_PREFIX") || return 12; fi
    ddnsto_process_private "$PROCESS_PREFIX" || return 12
    [ "$("$ZSETUP_BIN" storage "$PROCESS_PREFIX" get read_only)" = false ] || return 12
    [ "$("$ZSETUP_BIN" storage "$PROCESS_PREFIX" get noexec)" = false ] || return 12
    # tmpfs/overlay are allowed: files may disappear on reboot/recreation.
    for process_file in receipt config.yaml ddnsto pid startup.log .ddnsto_boot.cfg; do
        [ ! -L "$PROCESS_PREFIX/$process_file" ] || return 12
        [ ! -e "$PROCESS_PREFIX/$process_file" ] || [ -f "$PROCESS_PREFIX/$process_file" ] || return 12
    done
    for process_dir in tmp logs .staging; do
        [ ! -e "$PROCESS_PREFIX/$process_dir" ] && [ ! -L "$PROCESS_PREFIX/$process_dir" ] ||
            ddnsto_process_private "$PROCESS_PREFIX/$process_dir" || return 12
    done
}

ddnsto_process_read() {
    PROCESS_OLD_VERSION=; PROCESS_OLD_ENV=production; PROCESS_OLD_DIGEST=
    if [ ! -f "$PROCESS_PREFIX/receipt" ]; then
        [ ! -e "$PROCESS_PREFIX/config.yaml" ] && [ ! -e "$PROCESS_PREFIX/ddnsto" ] &&
            [ ! -e "$PROCESS_PREFIX/pid" ] || return 2
        return 0
    fi
    installer_file_size "$PROCESS_PREFIX/receipt" || return 2
    [ "$INSTALLER_FILE_SIZE" -le 1024 ] || return 2
    { IFS= read -r process_owner; IFS= read -r PROCESS_OLD_VERSION
      IFS= read -r PROCESS_OLD_DIGEST; IFS= read -r process_arch
      IFS= read -r PROCESS_OLD_ENV; } < "$PROCESS_PREFIX/receipt" || return 2
    [ "$process_owner" = ddnsto-process-v1 ] && [ "$process_arch" = "$arch" ] || return 2
    ddnsto_version_parts "$PROCESS_OLD_VERSION" >/dev/null || return 2
    case "$PROCESS_OLD_ENV" in production|test) ;; *) return 2 ;; esac
    [ -x "$PROCESS_PREFIX/ddnsto" ] || return 2
    installer_file_size "$PROCESS_PREFIX/config.yaml" || return 2
    [ "$INSTALLER_FILE_SIZE" -le 32768 ] || return 2
    IFS= read -r process_token_line < "$PROCESS_PREFIX/config.yaml" || return 2
}

# PID + kernel start ticks + exact executable: never signal a recycled PID.
ddnsto_process_ticks() (
    IFS= read -r process_stat < "/proc/$1/stat" || exit 1
    process_stat=${process_stat##*) }
    set -f; set -- $process_stat
    [ "$#" -ge 20 ] && [ "$1" != Z ] || exit 1
    shift 19; printf '%s\n' "$1"
)

ddnsto_process_running() {
    [ -f "$PROCESS_PREFIX/pid" ] && [ ! -L "$PROCESS_PREFIX/pid" ] || return 1
    IFS=' ' read -r process_pid process_birth < "$PROCESS_PREFIX/pid" || return 1
    case "$process_pid:$process_birth" in *[!0-9:]*|:*|*:) return 1 ;; esac
    [ "$process_pid" -gt 1 ] || return 1
    [ "$(readlink "/proc/$process_pid/exe" 2>/dev/null)" = "$PROCESS_PREFIX/ddnsto" ] || return 1
    [ "$(ddnsto_process_ticks "$process_pid" 2>/dev/null)" = "$process_birth" ]
}

ddnsto_process_stop() {
    ddnsto_process_running || return 0
    kill -TERM "$process_pid" || return 13
    process_wait=0
    while ddnsto_process_running; do
        process_wait=$((process_wait + 1)); [ "$process_wait" -lt 50 ] || return 13
        sleep .1
    done
}

ddnsto_process_start() {
    if ! ddnsto_process_running; then
        process_assignment=$(ddnsto_business_assignment "$BUSINESS_ENV") || return 2
        (
            trap '' HUP
            TMPDIR=$PROCESS_PREFIX/tmp
            DDNSTO_TEST_SERVER_ASSIGNMENT_JSON=$process_assignment
            export TMPDIR DDNSTO_TEST_SERVER_ASSIGNMENT_JSON
            # Detach from terminal/process-group cleanup when the base system
            # provides setsid; minimal systems still inherit ignored SIGHUP.
            if command -v setsid >/dev/null 2>&1; then
                exec setsid "$PROCESS_PREFIX/ddnsto" --config "$PROCESS_PREFIX/config.yaml"
            fi
            exec "$PROCESS_PREFIX/ddnsto" --config "$PROCESS_PREFIX/config.yaml"
        ) </dev/null > "$PROCESS_PREFIX/startup.log" 2>&1 &
        process_pid=$!
        process_birth=$(ddnsto_process_ticks "$process_pid") || return 13
        printf '%s %s\n' "$process_pid" "$process_birth" > "$PROCESS_PREFIX/pid"
        process_wait=0
        until ddnsto_process_running; do
            kill -0 "$process_pid" 2>/dev/null || return 13
            process_wait=$((process_wait + 1)); [ "$process_wait" -lt 30 ] || return 13
            sleep .1
        done
    fi
    process_wait=0
    while [ "$process_wait" -lt 3 ]; do
        sleep 1
        ddnsto_process_running || return 13
        process_wait=$((process_wait + 1))
    done
}

ddnsto_process_entry() (
    ddnsto_process_paths || { ddnsto_process_error E_HOME '用户主目录不存在或无效，无法安装后台进程'; exit 12; }
    case "$arch" in x86_64|aarch64) ;; *) ddnsto_process_error E_ARCH "Linux 二进制尚不支持架构 $arch"; exit 2 ;; esac
    [ -z "${installer_prefix:-}${installer_work_dir:-}" ] || {
        ddnsto_process_error E_OPTIONS '后台进程模式使用 ~/.local/share/ddnsto，不支持自定义安装路径'; exit 2;
    }
    case "$ACTION" in ensure|install|update|status|start|stop|restart|repair) ;;
        *) ddnsto_process_error E_ACTION '后台进程模式不支持此动作'; exit 2 ;; esac
    case "${TOKEN:-}" in *[!a-zA-Z0-9_-]*) ddnsto_process_error E_TOKEN 'Token 格式不正确'; exit 2 ;; esac
    case "$ACTION" in ensure|install) [ -n "${TOKEN:-}" ] || { ddnsto_process_error E_TOKEN '缺少账号 Token'; exit 2; } ;; esac
    ddnsto_process_storage || { ddnsto_process_error E_STORAGE '进程目录不安全、只读或不可执行'; exit 12; }
    umask 077
    INSTALLER_WORK_ROOT=$PROCESS_PREFIX/.staging
    installer_transaction_begin || { ddnsto_process_error E_LOCK '安装锁或工作目录不可用，请检查是否仍有安装进行中'; exit 12; }
    ddnsto_process_read || { ddnsto_process_error E_OWNERSHIP '现有安装记录或配置不属于此进程安装器，未覆盖'; exit 2; }
    if [ -n "$PROCESS_OLD_VERSION" ]; then
        [ -z "${TOKEN:-}" ] || [ "$process_token_line" = "userToken: '$TOKEN'" ] || {
            ddnsto_process_error E_ACCOUNT '已安装账号与提供的 Token 不一致，未换绑'; exit 2;
        }
        ddnsto_business_match "$PROCESS_OLD_ENV" || exit 2
        if [ "$BUSINESS_ENV" != "$PROCESS_OLD_ENV" ]; then
            case "$ACTION" in ensure|install|update) ;;
                *) ddnsto_process_error E_ENV_SWITCH '切换环境请使用安装或更新动作及 --switch-environment'; exit 2 ;;
            esac
        fi
    fi
    if [ "$ACTION" = status ]; then
        if ddnsto_process_running; then printf 'local_service=running cloud_status=unverified mode=process\n'
        else printf 'local_service=stopped cloud_status=unverified mode=process\n'; fi
        exit 0
    fi
    if [ "$ACTION" = ensure ] || [ "$ACTION" = install ] || [ "$ACTION" = update ]; then
        ddnsto_process_install || exit $?
    else
        [ -n "$PROCESS_OLD_VERSION" ] || { ddnsto_process_error E_NOT_INSTALLED '尚未安装后台进程'; exit 2; }
    fi
    case "$ACTION" in stop|restart)
        ddnsto_process_stop || { ddnsto_process_error E_STOP '进程未能停止，请检查进程状态'; exit 13; } ;;
    esac
    [ "$ACTION" != stop ] || exit 0
    ddnsto_flow_note installed
    ddnsto_flow_note starting
    ddnsto_process_start || { ddnsto_process_error E_START '客户端未能稳定启动，请检查 startup.log 中的运行错误'; exit 13; }
    PROCESS_CHANGED=0
    installer_transaction_finish || exit $?
    ddnsto_flow_note started
    [ -z "${DDNSTO_FLOW_DIR:-}" ] || printf '%s\n' '后台进程模式：文件位于 ~/.local/share/ddnsto；不提供开机自启或崩溃重启，系统重启或容器重建后请重新运行安装命令。' > "$DDNSTO_FLOW_DIR/notice"
    printf 'DDNSTO：后台进程已启动；目录 %s；不保证重启后恢复。\n' "$PROCESS_PREFIX"
)
