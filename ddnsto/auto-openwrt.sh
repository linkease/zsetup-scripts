# Default OpenWrt workflow; package ownership and UCI stay authoritative.
ddnsto_ensure_ow_account() {
    ddnsto_openwrt_protected || {
        ddnsto_flow_error E_OWNERSHIP '现有路由器安装文件归属不明或权限不安全' '请检查包管理器记录及配置权限；不会覆盖'; return 2;
    }
    ensure_pending=$(uci -c "${config%/*}" -q changes ddnsto 2>/dev/null) && [ -z "$ensure_pending" ] || {
        ddnsto_flow_error E_CONFIG '存在尚未提交的 UCI 修改，无法安全处理' '请在路由器管理界面保存或撤销修改后重试'; return 2;
    }
    [ "$(uci -c "${config%/*}" -q get 'ddnsto.@ddnsto[0]' 2>/dev/null)" = ddnsto ] &&
        ! uci -c "${config%/*}" -q get 'ddnsto.@ddnsto[1]' >/dev/null 2>&1 || {
        ddnsto_flow_error E_CONFIG '配置中缺少唯一的 DDNSTO 服务段' '请人工核对 UCI 配置；不会自动合并或覆盖'; return 2;
    }
    ensure_account=$(uci -c "${config%/*}" -q get 'ddnsto.@ddnsto[0].token' 2>/dev/null) || ensure_account=
    if [ -z "$ensure_account" ] || [ "$ensure_account" != "$ENSURE_TOKEN" ]; then
        unset ensure_account
        ddnsto_flow_error E_ACCOUNT '设备已绑定其他账号，或无法确认账号归属' '请使用原账号管理；不会自动换绑'; return 2
    fi
    unset ensure_account
}

ddnsto_ensure_ow_version() (
    if [ "$package_manager" = opkg ]; then
        listing=$(opkg list-installed 2>/dev/null) || exit 2
        count=0; installed=
        while read -r name dash version rest; do
            [ "$name" = ddnsto ] || continue
            [ "$dash" = - ] || exit 2
            count=$((count + 1)); installed=$version
        done <<EOF
$listing
EOF
        [ "$count" = 1 ] || exit 2
    else
        installed=$(apk info -v ddnsto 2>/dev/null) || exit 2
        case "$installed" in ddnsto-*) installed=${installed#ddnsto-} ;; *) exit 2 ;; esac
    fi
    # Official OpenWrt packages use PKG_SOURCE_DATE~ARCH_HEXCODE-rREV.
    # Accept only the publisher's exact architecture tag, not arbitrary
    # tilde/prerelease versions, and compare the underlying client release.
    case "$installed" in
        *~*)
            case "${arch:-}" in
                x86_64) arch_tag=8664 ;; aarch64) arch_tag=aa64 ;;
                armv7) arch_tag=aa32 ;; mipsel) arch_tag=1b0c ;;
                *) exit 2 ;;
            esac
            case "${installed#*~}" in "$arch_tag"-*) ;; *) exit 2 ;; esac
            suffix=${installed#*~}
            suffix=${suffix#"$arch_tag"-}
            installed="${installed%%~*}-$suffix"
            ;;
    esac
    case "$installed" in ''|*[!0-9.r-]*) exit 2 ;; esac
    release=${installed%%-*}
    if [ "$release" != "$installed" ]; then
        revision=${installed#*-}
        revision=${revision#r}
        case "$revision" in ''|*[!0-9]*) exit 2 ;; esac
    fi
    ddnsto_version_parts "$release" >/dev/null || exit 2
    printf '%s\n' "$release"
)

ddnsto_ensure_ow_pid() {
    # Do not log the ubus document: service command arguments may be sensitive.
    ensure_procd=$(ubus call service list '{"name":"ddnsto"}' 2>/dev/null) || return 13
    printf '%s\n' "$ensure_procd" | jsonfilter -e '@.ddnsto.instances.*.pid' 2>/dev/null
}

ddnsto_ensure_ow_running() {
    ensure_pid=$(ddnsto_ensure_ow_pid) || return 13
    case "$ensure_pid" in ''|0|*[!0-9]*) return 13 ;; esac
    ensure_probe=0
    while [ "$ensure_probe" -lt 3 ]; do
        "$service_path" status >/dev/null 2>&1 || return 13
        [ "$(ddnsto_ensure_ow_pid)" = "$ensure_pid" ] || return 13
        ensure_probe=$((ensure_probe + 1))
        [ "$ensure_probe" = 3 ] || sleep 1
    done
}

ddnsto_ensure_ow_start() {
    ddnsto_ensure_ow_account || return $?
    ddnsto_flow_note starting
    ( ACTION=start; TOKEN=; ddnsto_openwrt_local ) || return $?
    ddnsto_ensure_ow_running || return 13
}

ddnsto_ensure_openwrt() {
    case "$arch:$package_manager" in
        x86_64:opkg|aarch64:opkg|armv7:opkg|mipsel:opkg|x86_64:apk|aarch64:apk|armv7:apk|mipsel:apk) ;;
        *) ddnsto_flow_error E_ARCH '此路由器架构或包管理器不受支持' '请使用设备厂商支持的安装方式'; return 2 ;;
    esac
    for ensure_tool in uci ubus jsonfilter; do
        command -v "$ensure_tool" >/dev/null 2>&1 || {
            ddnsto_flow_error E_DEPENDENCY '缺少路由器 UCI/procd 状态检查工具' '请恢复固件自带的 uci、ubus、jsonfilter 后重试'; return 2;
        }
    done
    ddnsto_openwrt_paths
    ow_packages=$(ddnsto_ow_packages) || return 2
    ensure_current=
    if ddnsto_ow_has_package ddnsto; then
        ddnsto_ensure_ow_account || return $?
        ensure_current=$(ddnsto_ensure_ow_version) || {
            ddnsto_flow_error E_VERSION '无法识别当前路由器客户端版本' '请检查包管理器记录；不会强制覆盖'; return 2;
        }
    else
        for ensure_path in "$config" "$binary" "$service_path"; do
            [ ! -e "$ensure_path" ] && [ ! -L "$ensure_path" ] || {
                ddnsto_flow_error E_OWNERSHIP '发现未归属的历史安装或配置' '请先确认原安装来源；不会自动覆盖'; return 2;
            }
        done
    fi
    ddnsto_ensure_decision "$ensure_current" "$(ddnsto_pinned_version standard)" || return $?
    if [ "$ENSURE_ACTION" != start ]; then
        ddnsto_flow_note installing
        if [ "$ENSURE_ACTION" = install ]; then
            ddnsto_install --action install --token "$ENSURE_TOKEN" || return $?
        else ddnsto_install --action update || return $?; fi
    fi
    ddnsto_flow_note installed
    ddnsto_machine_locked ddnsto_ensure_ow_start || return $?
    ddnsto_flow_note started
}

ddnsto_ensure_ow_locked() {
    [ "${DDNSTO_ENSURE_ACTIVE:-0}" = 1 ] || return 0
    [ "${ACTION:-}" = update ] || return 0
    ddnsto_ensure_ow_account || return $?
    ensure_current=$(ddnsto_ensure_ow_version) || return 2
    ensure_order=$(ddnsto_version_order "$ensure_current" "$(ddnsto_pinned_version standard)") || return 2
    [ "$ensure_order" != 1 ] || {
        ddnsto_flow_error E_VERSION '执行期间已安装版本变为更高版本' '请重新执行；不会降级'; return 2;
    }
}
