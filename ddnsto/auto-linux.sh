# Linux default workflow: protected installation receipts + data-only identity.
ddnsto_ensure_tty_available() ( : <>/dev/tty ) 2>/dev/null

ddnsto_ensure_authorize() {
    if [ -x /usr/bin/sudo ]; then
        /usr/bin/sudo -n true 2>/dev/null && return 0
        # Only the operating system password prompt is interactive. The
        # existing verified-copy privilege bridge owns the actual root phase.
        if ddnsto_ensure_tty_available && /usr/bin/sudo -v </dev/tty >/dev/tty 2>&1; then return 0; fi
    fi
    ddnsto_flow_error E_PERMISSION '未取得系统服务所需的管理员权限' '请执行 sudo -i 后重新粘贴命令，或请管理员安装'
}

ddnsto_ensure_protected_config() {
    [ -f "$SERVICE_CONFIG" ] && [ ! -L "$SERVICE_CONFIG" ] || return 2
    [ "$("$ZSETUP_BIN" storage "$SERVICE_CONFIG" get system_protected)" = true ] || return 2
    ensure_config_size=$(wc -c < "$SERVICE_CONFIG") || return 2
    [ "$ensure_config_size" -le 16384 ]
}

ddnsto_ensure_linux_account() {
    ddnsto_ensure_protected_config &&
        DDNSTO_EXPECTED_ACCOUNT="$ENSURE_TOKEN" jq -e -s '
        length == 1 and (.[0] | type == "object" and
        (.token | type == "string" and length > 0) and
        .token == env.DDNSTO_EXPECTED_ACCOUNT)' "$SERVICE_CONFIG" >/dev/null 2>&1 || {
        ddnsto_flow_error E_ACCOUNT '现有安装不属于当前账号，或无法确认配置归属' '请使用原账号管理；不会自动换绑或覆盖配置'; return 2;
    }
}

ddnsto_ensure_jq() {
    command -v jq >/dev/null 2>&1 && return 0
    # Fixed dependency only, using configured system repositories. Never add a
    # repository, update the OS, install unsigned packages or disable TLS.
    if command -v apt-get >/dev/null 2>&1; then
        "$ZSETUP_BIN" run -- env DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends install jq >/dev/null 2>&1 || return 2
    elif command -v dnf >/dev/null 2>&1; then
        "$ZSETUP_BIN" run -- dnf -y install jq >/dev/null 2>&1 || return 2
    elif command -v yum >/dev/null 2>&1; then
        "$ZSETUP_BIN" run -- yum -y install jq >/dev/null 2>&1 || return 2
    else return 2; fi
    command -v jq >/dev/null 2>&1
}

ddnsto_ensure_linux_running() {
    ensure_pid=$(ddnsto_managed_property MainPID) || return 13
    case "$ensure_pid" in ''|0|*[!0-9]*) return 13 ;; esac
    ensure_probe=0
    while [ "$ensure_probe" -lt 3 ]; do
        [ "$(ddnsto_managed_property ActiveState)" = active ] || return 13
        [ "$(ddnsto_managed_property MainPID)" = "$ensure_pid" ] || return 13
        ensure_probe=$((ensure_probe + 1))
        [ "$ensure_probe" = 3 ] || sleep 1
    done
}

ddnsto_ensure_linux() {
    case "$arch" in x86_64|aarch64) ;; *)
        ddnsto_flow_error E_ARCH '此 Linux CPU 架构尚未支持自动安装' '请使用对应平台的手动安装包'; return 2 ;; esac
    [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1 || {
        ddnsto_flow_error E_SERVICE_MANAGER '当前系统没有可用的 systemd 服务管理器' '请使用该平台手动安装方式；不会自动切换 Docker'; return 2;
    }
    installer_layout ddnsto system || return $?
    SERVICE_CONFIG=/etc/ddnsto/ddnsto-config.json
    ensure_current=
    if [ -e "$INSTALLER_PREFIX/.managed" ] || [ -L "$INSTALLER_PREFIX/.managed" ]; then
        ddnsto_managed_owned || {
            ddnsto_flow_error E_OWNERSHIP '现有安装不完整或不是可管理的安装' '请先检查安装来源和残留事务'; return 2;
        }
        ddnsto_ensure_jq || {
            ddnsto_flow_error E_DEPENDENCY '无法从现有软件源补齐 jq，不能安全确认账号' '请用系统包管理器安装 jq 后重试'; return 2;
        }
        ddnsto_ensure_linux_account || return $?
        ensure_current=${SERVICE_OLD#versions/}
    elif [ -e "$SERVICE_CONFIG" ] || [ -L "$SERVICE_CONFIG" ]; then
        ddnsto_flow_error E_OWNERSHIP '发现未归属的历史配置' '请先人工确认历史安装；不会自动覆盖'; return 2
    fi
    ddnsto_ensure_decision "$ensure_current" "$(ddnsto_pinned_version standard)" || return $?
    if [ "$ENSURE_ACTION" = start ]; then
        ddnsto_flow_note installed
        ddnsto_flow_note starting
        ( ACTION=start; TOKEN=; ddnsto_managed_write ) || return $?
    else
        ddnsto_flow_note installing
        if [ "$ENSURE_ACTION" = install ]; then
            ddnsto_install --action install --token "$ENSURE_TOKEN" || return $?
        else
            ddnsto_install --action update || return $?
        fi
        ddnsto_flow_note installed
    fi
    ddnsto_ensure_linux_running || return 13
    ddnsto_flow_note started
}

# Called again while holding the shared machine lease, before mutation.
ddnsto_ensure_linux_locked() {
    [ "${DDNSTO_ENSURE_ACTIVE:-0}" = 1 ] || return 0
    if [ -n "${SERVICE_OLD:-}" ]; then
        ddnsto_ensure_linux_account || return $?
        if [ "${ACTION:-}" = update ]; then
            ensure_locked_order=$(ddnsto_version_order "${SERVICE_OLD#versions/}" "$(ddnsto_pinned_version standard)") || return 2
            [ "$ensure_locked_order" != 1 ] || {
                ddnsto_flow_error E_VERSION '已安装版本在执行期间变为更高版本' '请重新执行同一命令；不会降级'; return 2;
            }
        fi
    elif [ -e "$SERVICE_CONFIG" ] || [ -L "$SERVICE_CONFIG" ]; then
        ddnsto_flow_error E_OWNERSHIP '执行期间出现未归属的配置' '请检查并发安装；不会覆盖'; return 2
    fi
}
