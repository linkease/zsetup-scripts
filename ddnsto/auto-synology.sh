# DSM package-managed default workflow. Never install a generic Linux service.
ddnsto_synopkg() { /usr/syno/bin/synopkg "$@"; }

ddnsto_synology_storage() {
    # DSM /tmp is noexec; /var/tmp can be world-writable without sticky bit.
    # Do not change mounts or weaken the shared cache ownership rules.
    syno_storage=/var/lib/ddnsto-installer
    ddnsto_bootstrap_safe_ancestors /var/lib && ddnsto_bootstrap_private_dir "$syno_storage" || {
        ddnsto_flow_error E_STORAGE '群晖安装器缓存目录不安全或不可写' '请检查 /var/lib/ddnsto-installer 权限'; return 12;
    }
}

ddnsto_synology_preflight() {
    [ "$(id -u)" = 0 ] || { ddnsto_flow_error E_PRIVILEGE '群晖套件安装需要管理员权限' '请使用 sudo -i 后重新执行'; return 2; }
    for tool in jq readlink stat; do
        command -v "$tool" >/dev/null 2>&1 || { ddnsto_flow_error E_DEPENDENCY '缺少群晖配置或进程检查工具' '请检查 DSM 的 jq、stat、readlink'; return 2; }
    done
    [ -x /usr/syno/bin/synopkg ] || { ddnsto_flow_error E_DEPENDENCY '找不到 DSM 套件管理器' '请通过套件中心手动安装'; return 2; }
    ddnsto_synology_select || { ddnsto_flow_error E_PLATFORM '此 DSM 版本或架构尚未支持自动安装' '请使用匹配机型的手动套件'; return 2; }
    [ "$major" = 7 ] || { ddnsto_flow_error E_PLATFORM 'DSM 6 暂仅支持手动安装' '请使用套件中心手动安装'; return 2; }
    syno_pkg=/var/packages/ddnsto
    syno_config=$syno_pkg/var/ddnsto-config.json
    ddnsto_synology_storage
}

ddnsto_synology_check_paths() {
    # DSM owns target/var symlinks. Resolve and check their actual ancestors;
    # package data may be owned by the dedicated service user, never strangers.
    syno_uid=$(id -u ddnsto) || return 2
    for path in "$syno_pkg/INFO" "$syno_pkg/target/bin/ddnsto" "$syno_config"; do
        [ -f "$path" ] || return 2
        resolved=$(readlink -f "$path") || return 2
        while [ "$resolved" != / ]; do
            owner=$(stat -c %u "$resolved") || return 2
            mode=$(stat -c %a "$resolved") || return 2
            case "$owner" in 0|"$syno_uid") ;; *) return 2 ;; esac
            [ "$((0$mode & 0022))" = 0 ] || return 2
            resolved=${resolved%/*}; [ -n "$resolved" ] || resolved=/
        done
    done
}

ddnsto_synology_account() {
    ddnsto_synology_check_paths || { ddnsto_flow_error E_OWNERSHIP '群晖套件文件缺失或权限不安全' '请核对套件来源与配置权限，不要强制覆盖'; return 2; }
    # Token comes via stdin, never jq argv or diagnostic output.
    printf '%s' "$TOKEN" | jq -Rse --slurpfile config "$syno_config" '
        . as $expected | ($config | length == 1) and
        ($config[0] | type == "object" and (.token == $expected) and
        (.routeridx | type == "number" and . >= 0 and . <= 99 and floor == .))
    ' >/dev/null 2>&1 || {
        ddnsto_flow_error E_ACCOUNT '套件账号不匹配或设备编号无法安全确认' '请使用原账号检查套件设置，不会自动换绑'; return 2;
    }
}

ddnsto_synology_version() {
    syno_version=$(ddnsto_synopkg version ddnsto) || return 2
    case "$syno_version" in *-*) ;; *) return 2 ;; esac
    syno_release=${syno_version%-*}; syno_revision=${syno_version##*-}
    ddnsto_version_parts "$syno_release" >/dev/null || return 2
    case "$syno_revision" in ''|*[!0-9]*|0*) return 2 ;; esac
    [ "${#syno_revision}" -le 6 ]
}

ddnsto_synology_fetch() (
    ddnsto_synology_storage || exit $?
    WORK_ROOT="$syno_storage/native"
    ddnsto_bootstrap_zsetup || { ddnsto_flow_error E_BOOTSTRAP 'zsetup 下载或校验失败' '请检查 HTTPS 下载和缓存权限'; exit 2; }
    ddnsto_synology_select || exit 2
    "$ACTIVE_ZSETUP" download -o "$1" --sha256 "$digest" --max-bytes 33554432 --min-free-bytes 8388608 \
        "https://fw.koolcenter.com/binary/ddnsto/$relative" \
        "https://fw.d4ctech.com/binary/ddnsto/$relative" \
        --fallback-url "https://fw20.koolcenter.com/binary/ddnsto/$relative"
)

ddnsto_synology_running() {
    binary=$(readlink -f "$syno_pkg/target/bin/ddnsto") || return 13
    pid=$(cat "$syno_pkg/var/ddnsto.pid") || return 13
    case "$pid" in ''|*[!0-9]*) return 13 ;; esac
    [ "$pid" -gt 1 ] || return 13
    for probe in 1 2 3; do
        ddnsto_synopkg status ddnsto | jq -e '.status == "running"' >/dev/null || return 13
        kill -0 "$pid" 2>/dev/null && [ "$(readlink "/proc/$pid/exe")" = "$binary" ] || return 13
        [ "$(cat "$syno_pkg/var/ddnsto.pid")" = "$pid" ] || return 13
        [ "$probe" = 3 ] || sleep 1
    done
}

ddnsto_synology_ensure_locked() (
    umask 077
    ddnsto_synology_preflight || exit $?
    case "$TOKEN" in ''|*[!a-zA-Z0-9_-]*) ddnsto_flow_error E_TOKEN 'Token 格式不适用于群晖套件' '请从控制台重新复制'; exit 2 ;; esac
    need_install=1; existing=0
    if [ -e "$syno_pkg/INFO" ]; then
        existing=1
        ddnsto_synology_account || exit $?
        ddnsto_synology_version || { ddnsto_flow_error E_VERSION '无法识别当前套件版本' '请检查套件中心，不会强制覆盖'; exit 2; }
        order=$(ddnsto_version_order "$syno_release" 4.2.8) || exit 2
        if [ "$order" = 1 ] || { [ "$order" = 0 ] && [ "$syno_revision" -ge 7 ]; }; then need_install=0; fi
    elif [ -e "$syno_config" ] || [ -e "$syno_pkg/target" ] || [ -L "$syno_pkg/target" ]; then
        ddnsto_flow_error E_OWNERSHIP '发现未登记的群晖套件残留' '请在套件中心检查，不会覆盖原配置'; exit 2
    else
        ddnsto_synology_fresh_preflight || exit $?
    fi
    if [ "$need_install" = 1 ]; then
        syno_work=$(mktemp -d "$syno_storage/package.XXXXXX") || exit 12
        # Keep private backup and package for recovery; never auto-uninstall.
        [ "$existing" = 0 ] || cp -p "$syno_config" "$syno_work/config.before.json" || exit 12
        ddnsto_synology_fetch "$syno_work/package.spk" || {
            ddnsto_flow_error E_DOWNLOAD '群晖套件下载或校验失败，尚未修改套件' '请检查下载连通性后重试'; exit 11;
        }
        if [ "$existing" = 1 ]; then
            ddnsto_synology_account || exit $?
            cmp -s "$syno_config" "$syno_work/config.before.json" || { ddnsto_flow_error E_CONFIG '下载期间配置已改变' '请重新执行，不会覆盖修改'; exit 2; }
            ddnsto_synology_version || exit 2
            order=$(ddnsto_version_order "$syno_release" 4.2.8) || exit 2
            [ "$order" != 1 ] && { [ "$order" != 0 ] || [ "$syno_revision" -le 7 ]; } || {
                ddnsto_flow_error E_VERSION '下载期间已安装版本变更' '请重新执行，不会降级'; exit 2;
            }
        fi
        ddnsto_flow_note installing
        if [ "$existing" = 0 ]; then
            ddnsto_synology_fresh_install "$syno_work/package.spk" || exit $?
        else
            ddnsto_synopkg install "$syno_work/package.spk" >/dev/null 2>&1 || {
            ddnsto_flow_error E_PACKAGE 'DSM 套件安装失败，未自动卸载或删除配置' "请检查套件中心；私有备份目录：$syno_work"; exit 11;
            }
        fi
        ddnsto_synology_version && [ "$syno_version" = 4.2.8-7 ] || {
            ddnsto_flow_error E_PACKAGE '套件版本未达到预期' '请检查套件中心安装记录'; exit 11;
        }
        if [ "$existing" = 1 ]; then
            cmp -s "$syno_config" "$syno_work/config.before.json" || {
                ddnsto_flow_error E_CONFIG '升级后配置与备份不一致' "停止自动操作，请检查私有备份：$syno_work"; exit 12;
            }
        fi
    fi
    ddnsto_synology_account || exit $?
    ddnsto_flow_note installed
    ddnsto_flow_note starting
    ddnsto_synopkg start ddnsto >/dev/null 2>&1 && ddnsto_synology_running || {
        ddnsto_flow_error E_START '套件已安装，但未确认稳定启动' '请检查套件中心和套件运行日志，配置已保留'; exit 13;
    }
    ddnsto_flow_note started
)

ddnsto_synology_ensure() { ddnsto_machine_locked ddnsto_synology_ensure_locked; }
