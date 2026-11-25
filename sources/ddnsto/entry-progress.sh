# Human-facing stages. Never print arguments (which may contain the Token).
DDNSTO_HUMAN_OUTPUT=1
export DDNSTO_HUMAN_OUTPUT

zsetup_bootstrap_progress() {
    case "$1" in
        source) printf 'DDNSTO：正在连接下载源 %s…\n' "${2#*://}" >&2 ;;
        retry) printf '%s\n' 'DDNSTO：此下载源未成功，正在尝试下一种下载方式或镜像…' >&2 ;;
        cached) printf '%s\n' 'DDNSTO：使用已有安装工具，无需重复下载。' >&2 ;;
        download) printf '%s\n' 'DDNSTO：正在下载并校验安装工具…' >&2 ;;
    esac
}

ddnsto_entry_wait() (
    ddnsto_stage=$1
    shift
    printf 'DDNSTO：%s…\n' "$ddnsto_stage" >&2
    ddnsto_interval=${DDNSTO_PROGRESS_INTERVAL:-8}
    case "$ddnsto_interval" in ''|*[!0-9]*|0) ddnsto_interval=8 ;; esac
    (
        ddnsto_sleep=
        trap '[ -z "$ddnsto_sleep" ] || kill "$ddnsto_sleep" 2>/dev/null || :; exit 0' HUP INT TERM
        while :; do
            sleep "$ddnsto_interval" & ddnsto_sleep=$!
            wait "$ddnsto_sleep" || exit 0
            ddnsto_sleep=
            printf 'DDNSTO：%s，仍在处理，请稍候…\n' "$ddnsto_stage" >&2
        done
    ) &
    ddnsto_ticker=$!
    trap 'kill "$ddnsto_ticker" 2>/dev/null || :; wait "$ddnsto_ticker" 2>/dev/null || :' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    # Execute in a separate subshell so bootstrap traps and exec cannot replace
    # the ticker cleanup handler. Preserve the original command's exit code.
    set +e
    ( set -e; "$@" )
    ddnsto_rc=$?
    if [ "$ddnsto_rc" != 0 ]; then
        printf 'DDNSTO：阶段“%s”失败（退出码 %s）；下一步：根据上方错误检查网络或诊断记录后重试。\n' "$ddnsto_stage" "$ddnsto_rc" >&2
    fi
    exit "$ddnsto_rc"
)
