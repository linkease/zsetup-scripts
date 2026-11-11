# Controlled transaction. OS/package/service boundaries live in ASUS adapters.
# No vendor install.sh, uninstall.sh, base.sh or dbus export is executed.
ddnsto_asus_identity() {
    if [ "$#" = 2 ]; then
        asus_existing_token=$1 asus_version=$2
    else
        asus_existing_token=$(ddnsto_asus_get ddnsto_token) || return 2
        asus_version=$(ddnsto_asus_get ddnsto_version) || return 2
    fi
    [ -z "$asus_existing_token" ] || [ "$asus_existing_token" = "$TOKEN" ] || {
        ddnsto_flow_error E_ACCOUNT '插件属于其他账号，未执行换绑' '请使用原账号重新复制命令'; return 2;
    }
    if [ -n "$asus_version" ]; then
        asus_order=$(ddnsto_version_order "$asus_version" 4.2.8) || asus_order=unknown
        case "$asus_order" in -1|0) ;; *)
            ddnsto_flow_error E_VERSION '插件版本更新或无法识别，未覆盖现有版本' '请使用对应版本安装器；不会降级'; return 2 ;;
        esac
        [ -n "$asus_existing_token" ] || {
            ddnsto_flow_error E_ACCOUNT '已安装插件缺少账号信息，未修改配置' '请先在软件中心检查 Token'; return 2;
        }
    fi
}

ddnsto_asus_checkpoint() {
    [ -z "${ASUS_CANCEL:-}" ] || [ ! -f "$ASUS_CANCEL" ] || {
        ddnsto_flow_error E_CANCELLED '安装已取消，正在完成必要恢复' '请等待当前命令结束后检查状态'; return 143;
    }
}

ddnsto_asus_snapshot_config() {
    mkdir "$ASUS_ATTEMPT/config" || return 12
    for key in ddnsto_token ddnsto_enable ddnsto_version ddnsto_client_version \
        ddnsto_feat_enabled ddnsto_feat_username ddnsto_feat_password \
        ddnsto_feat_port ddnsto_feat_disk_path_selected; do
        ddnsto_asus_get "$key" > "$ASUS_ATTEMPT/config/$key" || return 12
    done
}

ddnsto_asus_config_unchanged() {
    for key in ddnsto_token ddnsto_enable ddnsto_version ddnsto_client_version \
        ddnsto_feat_enabled ddnsto_feat_username ddnsto_feat_password \
        ddnsto_feat_port ddnsto_feat_disk_path_selected; do
        ddnsto_asus_get "$key" > "$ASUS_ATTEMPT/compare" || return 12
        cmp -s "$ASUS_ATTEMPT/config/$key" "$ASUS_ATTEMPT/compare" || return 2
    done
}

ddnsto_asus_ensure_locked() (
    umask 077
    ddnsto_asus_preflight || exit $?
    case "$TOKEN" in ''|*[!a-zA-Z0-9_-]*)
        ddnsto_flow_error E_TOKEN 'Token 格式无效' '请从控制台重新复制'; exit 2 ;;
    esac
    ddnsto_asus_busy || { ddnsto_flow_error E_BUSY '软件中心正在安装其他插件' '请等待软件中心任务结束'; exit 16; }
    ddnsto_asus_identity || exit $?
    ASUS_ATTEMPT=$(ddnsto_asus_mktemp "$ASUS_STATE") || exit 12
    # Keep the private evidence/backup on both success and failure. Never clean
    # arbitrary /tmp/ddnsto* paths; no credentials reach the diagnostic stream.
    ddnsto_asus_snapshot_config || exit $?
    ddnsto_asus_identity "$(cat "$ASUS_ATTEMPT/config/ddnsto_token")" "$(cat "$ASUS_ATTEMPT/config/ddnsto_version")" || exit $?
    ddnsto_asus_checkpoint || exit $?
    if [ "$asus_version" = 4.2.8 ] && [ "$(cat "$ASUS_ATTEMPT/config/ddnsto_enable")" = 1 ] &&
        ddnsto_asus_reusable && ddnsto_asus_running; then
        ddnsto_asus_config_unchanged && ddnsto_asus_checkpoint || exit 2
        ddnsto_flow_note installed
        ddnsto_flow_note starting
        ddnsto_flow_note started
        exit 0
    fi
    ddnsto_asus_fetch "$ASUS_ATTEMPT/package.tar.gz" || {
        ddnsto_flow_error E_DOWNLOAD '插件下载或校验失败，现有服务未停止' '请检查 HTTPS 下载后重试'; exit 11;
    }
    ddnsto_asus_extract "$ASUS_ATTEMPT/package.tar.gz" "$ASUS_ATTEMPT/payload" "$ASUS_CHANNEL" "$ASUS_ARCH" || {
        ddnsto_flow_error E_PACKAGE '插件包结构或平台标记不符合审核记录' '请联系发布者检查安装包，未执行包内脚本'; exit 11;
    }
    ddnsto_asus_checkpoint || exit $?
    ddnsto_asus_busy && ddnsto_asus_config_unchanged || {
        ddnsto_flow_error E_CONFIG '下载期间软件中心或配置发生变化' '请稍后重新执行，未覆盖修改'; exit 2;
    }
    ddnsto_asus_backup_plugin || {
        ddnsto_flow_error E_BACKUP '无法安全备份现有插件' '请检查存储和插件文件，未停止服务'; exit 12;
    }
    changed=0
    finish_asus() {
        result=$?
        trap - EXIT HUP INT TERM
        if [ "$result" != 0 ] && [ "$changed" = 1 ]; then
            if ! ddnsto_asus_restore_plugin; then
                ddnsto_flow_error E_RECOVERY '安装失败且恢复未完成，已保留私有备份' "请检查 $ASUS_ATTEMPT" || :
            fi
        fi
        exit "$result"
    }
    trap finish_asus EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    ddnsto_asus_checkpoint || exit $?
    ddnsto_flow_note installing
    changed=1
    ddnsto_asus_stop || { ddnsto_flow_error E_STOP '未确认旧进程停止，未覆盖文件' '请检查客户端进程'; exit 13; }
    ddnsto_asus_install_plugin || {
        ddnsto_flow_error E_PACKAGE '插件文件安装失败，正在尝试恢复' "备份位于 $ASUS_ATTEMPT"; exit 11;
    }
    ddnsto_asus_checkpoint || exit $?
    # Only initialize an empty account. Existing feature settings are untouched.
    [ "$(ddnsto_asus_get ddnsto_token)" = "$asus_existing_token" ] || {
        ddnsto_flow_error E_ACCOUNT '安装期间账号发生变化，不覆盖新配置' '请检查软件中心账号后重试'; exit 2;
    }
    if [ -z "$asus_existing_token" ]; then
        printf '%s' "$TOKEN" > "$ASUS_ATTEMPT/changed/ddnsto_token" || exit 12
        ddnsto_asus_set ddnsto_token "$TOKEN" || exit 12
    fi
    printf '1' > "$ASUS_ATTEMPT/changed/ddnsto_enable" || exit 12
    ddnsto_asus_set ddnsto_enable 1 || exit 12
    [ "$(ddnsto_asus_get ddnsto_token)" = "$TOKEN" ] || {
        ddnsto_flow_error E_ACCOUNT '启动前账号发生变化，不覆盖新配置' '请停止并发修改后重试'; exit 2;
    }
    ddnsto_flow_note installed
    ddnsto_flow_note starting
    ddnsto_asus_start && ddnsto_asus_running || {
        ddnsto_flow_error E_START '插件安装后未确认稳定启动，正在尝试恢复' "请检查私有备份 $ASUS_ATTEMPT"; exit 13;
    }
    ddnsto_asus_checkpoint || exit $?
    [ "$(ddnsto_asus_get ddnsto_token)" = "$TOKEN" ] || {
        ddnsto_flow_error E_ACCOUNT '启动期间账号发生变化，不能确认安装成功' '请停止并发修改后检查软件中心配置'; exit 2;
    }
    changed=0
    ddnsto_flow_note started
)
