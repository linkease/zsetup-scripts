# Default workflow. Platform executors keep their own locks and rollback.
# Logs contain bounded installer events, never raw child output or credentials.
ddnsto_flow_note() {
    [ -n "${DDNSTO_FLOW_DIR:-}" ] || return 0
    case "$1" in checking|installing|installed|starting|started) ;; *) return 2 ;; esac
    printf '%s\n' "$1" > "$DDNSTO_FLOW_DIR/state"
    printf 'stage=%s\n' "$1" >> "$DDNSTO_FLOW_DIR/events.log"
}

ddnsto_flow_error() {
    if [ -n "${DDNSTO_FLOW_DIR:-}" ]; then
        printf '%s\n' "$1" "$2" "$3" > "$DDNSTO_FLOW_DIR/reason"
        printf 'error=%s\n' "$1" >> "$DDNSTO_FLOW_DIR/events.log"
    fi
    printf 'DDNSTO [%s]：%s。%s\n' "$1" "$2" "$3" >&2
    return 2
}

# Strict numeric release triples. Unknown/prerelease versions require review,
# never lexical comparison or a silent downgrade. Bound arithmetic operands.
ddnsto_version_parts() (
    case "$1" in ''|*[!0-9.]*|.*|*.|*..*) exit 2 ;; esac
    IFS=.; set -- $1
    [ "$#" = 3 ] || exit 2
    for part do
        [ "${#part}" -le 6 ] || exit 2
        case "$part" in 0|[1-9]|[1-9][0-9]*) ;; *) exit 2 ;; esac
    done
    printf '%s %s %s\n' "$1" "$2" "$3"
)

ddnsto_version_order() (
    left=$(ddnsto_version_parts "$1") || exit 2
    right=$(ddnsto_version_parts "$2") || exit 2
    set -- $left $right
    while [ "$#" -gt 3 ]; do
        [ "$1" -le "$4" ] || { printf '1\n'; exit 0; }
        [ "$1" -ge "$4" ] || { printf '%s\n' -1; exit 0; }
        shift
    done
    printf '0\n'
)

ddnsto_ensure_decision() {
    ENSURE_ACTION=install
    [ -n "$1" ] || return 0
    ensure_order=$(ddnsto_version_order "$1" "$2") || {
        ddnsto_flow_error E_VERSION '无法安全判断已安装版本，未执行覆盖' '请检查现有安装来源'; return 2;
    }
    ENSURE_ACTION=start
    [ "$ensure_order" != -1 ] || ENSURE_ACTION=update
}

ddnsto_ensure_preflight() {
    case "$detected_platform" in linux|openwrt|synology|asus) ;; *)
        ddnsto_flow_error E_PLATFORM '此设备暂不支持自动安装' '请使用该设备的手动安装教程'; return 2 ;;
    esac
    [ -n "$TOKEN" ] && [ "${#TOKEN}" -le 16384 ] || {
        ddnsto_flow_error E_TOKEN '缺少有效的账号 Token' '请登录控制台重新复制完整命令'; return 2;
    }
    [ "$REQUESTED_METHOD" != docker ] || {
        ddnsto_flow_error E_METHOD 'Docker 自动安装尚未完成验收' '请使用已验收的原生平台；不会自动切换安装方式'; return 2;
    }
    [ -z "$FORCE_VERSION" ] && [ "$VERIFY_STATUS" = 0 ] || {
        ddnsto_flow_error E_OPTIONS '默认流程不接受手选版本或云端检查选项' '请重新复制默认命令'; return 2;
    }
    [ "${DDNSTO_VERSION:-4.2.8}" = 4.2.8 ] || {
        ddnsto_flow_error E_VERSION '默认流程只使用该审核安装器固定的客户端版本' '请使用推荐版本入口'; return 2;
    }
}

ddnsto_flow_finish() {
    flow_rc=$1
    trap - EXIT
    # Once cancellation starts, repeated signals must not interrupt the join
    # or abandon the platform controller's rollback/lock cleanup.
    trap '' HUP INT TERM
    if [ -n "${flow_child:-}" ]; then
        kill -TERM "$flow_child" 2>/dev/null || true
        wait "$flow_child" 2>/dev/null || true
    fi
    flow_state=$(cat "$DDNSTO_FLOW_DIR/state")
    if [ "$flow_rc" = 0 ] && [ "$flow_state" != started ]; then flow_rc=13; fi
    if [ "$flow_rc" = 0 ]; then
        printf '%s\n' 'DDNSTO：安装成功，启动成功。' '仅验证本地运行；设备在线状态请查看客户端运行日志。'
    else
        flow_code=E_EXECUTOR
        flow_reason="平台执行失败（退出码 $flow_rc），未能确认启动成功"
        flow_next='请检查安装状态和服务日志后重试；不要删除配置或强制重装'
        if [ -f "$DDNSTO_FLOW_DIR/reason" ]; then
            { IFS= read -r flow_code; IFS= read -r flow_reason; IFS= read -r flow_next; } < "$DDNSTO_FLOW_DIR/reason"
        fi
        printf 'DDNSTO [%s]：%s\n' "$flow_code" "$flow_reason" >&2
        case "$flow_state" in installed|starting) printf '%s\n' '当前状态：安装成功，启动失败；配置保留，请检查服务日志。' >&2 ;;
            installing) printf '%s\n' '当前状态：安装未完成；恢复已由平台执行器尝试，需检查残留状态。' >&2 ;;
            *) printf '%s\n' '当前状态：未确认安装完成；未自动换绑或卸载。' >&2 ;; esac
        printf '下一步：%s\n' "$flow_next" >&2
    fi
    printf 'exit_code=%s\n' "$flow_rc" >> "$DDNSTO_FLOW_DIR/events.log"
    printf '脱敏诊断记录：%s/events.log\n' "$DDNSTO_FLOW_DIR" >&2
    exit "$flow_rc"
}

# This terminal entry exits via ddnsto_flow_finish. Keep its traps in the public
# shell, not an implicit function subshell that SIGTERM to the public PID skips.
ddnsto_ensure_entry() {
    set +x
    umask 077
    # mktemp creates the private destination, never reuse an inherited path.
    if [ "${detected_platform:-}" = asus ]; then
        ddnsto_asus_storage || { ddnsto_flow_error E_STORAGE '华硕受保护存储不可用' '请检查 /jffs 挂载，不要放宽目录权限'; exit 12; }
        DDNSTO_FLOW_DIR=$(ddnsto_asus_mktemp "$ASUS_STATE") || exit 12
    else
        DDNSTO_FLOW_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ddnsto-result.XXXXXX") || exit 12
    fi
    flow_child=
    trap 'ddnsto_flow_finish $?' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    ddnsto_flow_note checking
    printf '%s\n' 'DDNSTO：正在检查并安装，请稍候…' >&2
    ( set -e; ddnsto_ensure_preflight; ddnsto_ensure_execute "$@" ) >/dev/null 2>&1 &
    flow_child=$!
    flow_rc=0; wait "$flow_child" || flow_rc=$?
    flow_child=
    exit "$flow_rc"
}

ddnsto_ensure_execute() {
    if [ "$detected_platform" = asus ]; then ddnsto_asus_ensure; return $?; fi
    if [ "$detected_platform" = synology ]; then ddnsto_synology_ensure; return $?; fi
    ZSETUP_INSTALL_SCOPE=${installer_scope:-system}
    ZSETUP_INSTALL_PREFIX=${installer_prefix:-}
    [ -z "${installer_work_dir:-}" ] || ZSETUP_WORK_DIR=$installer_work_dir
    if [ "${ZSETUP_INSTALLER_MODE:-0}" = 1 ]; then ddnsto_install "$@"
    else bootstrap_and_run "$@"; fi
}
