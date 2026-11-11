ddnsto_usage() {
    printf '%s\n' 'Usage: ddnsto-install.sh [--plan] [--action ensure|install|update|status|start|stop|restart|repair|configure|uninstall|download] [--platform auto|linux|openwrt|macos|windows|synology|asus|qnap|unraid] [--method auto|native|docker] [--token TOKEN | --token-file FILE] [--force-version lite|standard] [--verify-status]' \
        '默认 ensure：必须提供 Token，自动安装/升级/启用启动，不降级，不切换账号；仅验证本地稳定运行，不判断设备在线。' \
        '群晖 DSM 7 支持自动安装/升级/启动，需管理员 sudo；其他 NAS/Docker 暂不支持默认自动安装。以下选项用于高级操作。' \
        '华硕软件中心自动识别 rogsoft/armsoft/mtksoft/ipq32soft/ipq64soft/qcasoft；安装后在软件中心管理。' \
        '--plan: read-only local preflight; no downloads, token, or service changes.' \
        'Platform is a constraint, not an override. QNAP/Unraid are unavailable; Windows requires install.ps1.' \
        'Synology: DSM 7 default ensure installs/starts a verified SPK; DS220j / DSM 7.1 tested, ARM64 limited to DS220j. DSM 6 and explicit download/install use manual handoff.' \
        'Docker: explicit selection only; no automatic native/container migration.' \
        'Linux: protected systemd install/update and owned-service lifecycle.' \
        'OpenWrt: package install/update and offline procd lifecycle; update preserves UCI identity and enabled state.' \
        'Shared options precede business options: --installer-prefix PATH --installer-work-dir PATH --installer-scope system.' \
        'Explicit install on OpenWrt: token optional; automatic Lite selection below 900 MB.' \
        'Linux x86_64/aarch64: --token required without an interactive terminal.'
}

ddnsto_parse_args() {
    TOKEN=
    TOKEN_FILE=
    FORCE_VERSION=
    VERIFY_STATUS=0
    REQUESTED_PLATFORM=auto
    REQUESTED_METHOD=auto
    PLAN_ONLY=0
    ACTION=ensure
    OUTPUT_DIR=
    DEVICE_NAME=
    NETWORK=
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --token|--token-file|--force-version|--platform|--method|--action|--output-dir|--device-name|--network)
                [ "$#" -ge 2 ] && [ -n "$2" ] || { ddnsto_error "$1 requires a value"; return 2; }
                case "$1" in
                    --token) TOKEN=$2 ;; --token-file) TOKEN_FILE=$2 ;;
                    --platform) REQUESTED_PLATFORM=$2 ;; --method) REQUESTED_METHOD=$2 ;;
                    --action) ACTION=$2 ;;
                    --output-dir) OUTPUT_DIR=$2 ;;
                    --device-name) DEVICE_NAME=$2 ;; --network) NETWORK=$2 ;;
                    *) FORCE_VERSION=$2 ;;
                esac
                shift 2 ;;
            --token=*) TOKEN=${1#--token=}; [ -n "$TOKEN" ] || return 2; shift ;;
            --force-version=*) FORCE_VERSION=${1#--force-version=}; shift ;;
            --verify-status) VERIFY_STATUS=1; shift ;;
            --plan) PLAN_ONLY=1; shift ;;
            *) ddnsto_error 'unknown argument (use --help)'; return 2 ;;
        esac
    done
    case "$REQUESTED_PLATFORM" in auto|linux|openwrt|macos|windows|synology|asus|qnap|unraid) ;; *) ddnsto_error 'unknown platform'; return 2 ;; esac
    case "$REQUESTED_METHOD" in auto|native|docker) ;; *) ddnsto_error 'unknown installation method'; return 2 ;; esac
    [ "$REQUESTED_METHOD" = docker ] || [ -z "$DEVICE_NAME$NETWORK" ] || { ddnsto_error 'device-name/network require explicit Docker'; return 2; }
    case "$NETWORK" in ''|bridge|host) ;; *) ddnsto_error 'network must be bridge or host'; return 2 ;; esac
    if [ -n "$OUTPUT_DIR" ]; then
        case "$ACTION" in install|download) ;; *) ddnsto_error 'output-dir only applies to Synology downloads'; return 2 ;; esac
    fi
    case "$FORCE_VERSION" in ''|lite|standard) ;; *) ddnsto_error 'version must be lite or standard'; return 2 ;; esac
    case "$ACTION" in
        ensure|install|update) ;;
        download)
            [ -z "$TOKEN$TOKEN_FILE$FORCE_VERSION" ] && [ "$VERIFY_STATUS" = 0 ] || {
                ddnsto_error 'download does not accept credentials or installation options'; return 2;
            } ;;
        status|start|stop|restart|repair|uninstall)
            [ -z "$TOKEN$TOKEN_FILE$FORCE_VERSION" ] && [ "$PLAN_ONLY$VERIFY_STATUS" = 00 ] || {
                ddnsto_error 'service actions do not accept credentials, plan, or installation options'; return 2;
            } ;;
        configure)
            [ -z "$FORCE_VERSION" ] && [ "$PLAN_ONLY$VERIFY_STATUS" = 00 ] || {
                ddnsto_error 'configure does not accept plan or installation options'; return 2;
            } ;;
        *) ddnsto_error 'unknown action'; return 2 ;;
    esac
    if [ "$ACTION" = update ]; then
        [ -z "$TOKEN$TOKEN_FILE" ] || { ddnsto_error 'update preserves existing Token; do not supply credentials'; return 2; }
        [ "$PLAN_ONLY" = 0 ] || { ddnsto_error '--plan cannot be combined with update'; return 2; }
    fi
    if [ "$PLAN_ONLY" = 1 ]; then
        [ -z "$TOKEN$TOKEN_FILE" ] || { ddnsto_error '--plan does not accept credentials'; return 2; }
        return 0
    fi
    if [ -n "$TOKEN_FILE" ]; then
        [ -z "$TOKEN" ] || { ddnsto_error 'choose token or token-file'; return 2; }
        [ -f "$TOKEN_FILE" ] && [ ! -L "$TOKEN_FILE" ] && [ -r "$TOKEN_FILE" ] || { ddnsto_error 'token file must be readable and regular'; return 2; }
        token_bytes=$(wc -c < "$TOKEN_FILE") || return 2
        [ "$token_bytes" -le 16384 ] || { ddnsto_error 'token file exceeds 16 KiB'; return 2; }
        TOKEN=$(cat "$TOKEN_FILE"; printf '.')
        TOKEN=${TOKEN%.}
        TOKEN=${TOKEN%"
"}
        [ -n "$TOKEN" ] || { ddnsto_error 'empty token file'; return 2; }
    fi
    case "$TOKEN" in *"
"*|*"$(printf '\r')"*) ddnsto_error 'token must be one line'; return 2 ;; esac
}

# Inspect marker existence only. Never source vendor configuration as shell code.
ddnsto_appliance_platform() {
    appliance_root=${1:-}
    if [ -f "$appliance_root/etc/synoinfo.conf" ] || [ -d "$appliance_root/usr/syno" ]; then
        printf '%s\n' synology
    elif [ -f "$appliance_root/etc/config/uLinux.conf" ]; then
        printf '%s\n' qnap
    elif [ -f "$appliance_root/etc/unraid-version" ]; then
        printf '%s\n' unraid
    elif [ -x "$appliance_root/bin/nvram" ] && { [ -d "$appliance_root/koolshare" ] || [ -f "$appliance_root/www/Advanced_System_Content.asp" ]; }; then
        printf '%s\n' asus
    fi
}

ddnsto_detect_platform() {
    detected_platform=$(ddnsto_appliance_platform)
    if [ -z "$detected_platform" ]; then
        # Some released zsetup versions report appliances in os, others may
        # report device. Missing device is tolerated; it is not a new dependency.
        for platform_fact in "$os" "${device:-}"; do
            case "$platform_fact" in
                synology|dsm) detected_platform=synology; break ;;
                qnap|qts) detected_platform=qnap; break ;;
                unraid) detected_platform=unraid; break ;;
            esac
        done
    fi
    if [ -z "$detected_platform" ]; then
        case "$os:$package_manager" in
            openwrt:opkg|openwrt:apk) detected_platform=openwrt ;;
            ubuntu:apt|debian:apt|centos:yum|centos:dnf|rhel:yum|rhel:dnf|linux:*) detected_platform=linux ;;
            *) ddnsto_error "unsupported platform: $os/$package_manager"; return 2 ;;
        esac
    fi
    if [ "$REQUESTED_PLATFORM" != auto ] && [ "$REQUESTED_PLATFORM" != "$detected_platform" ]; then
        ddnsto_error "platform mismatch: requested $REQUESTED_PLATFORM, detected $detected_platform; use the matching device command"
        return 2
    fi
}

ddnsto_validate_action_options() {
    case "$ACTION" in
        ensure|install|update|download) return 0 ;;
        *) [ -z "$FORCE_VERSION${OUTPUT_DIR:-}" ] && [ "$VERIFY_STATUS" = 0 ] || {
            ddnsto_error 'selected service action does not accept installation options'; return 2;
        } ;;
    esac
}

ddnsto_validate_platform_options() {
    ddnsto_validate_action_options || return $?
    if [ "$detected_platform" != synology ]; then
        [ -z "${OUTPUT_DIR:-}" ] && [ "$ACTION" != download ] || { ddnsto_error 'download and output-dir require Synology'; return 2; }
    fi
    if [ "$detected_platform" = linux ]; then
        [ "$FORCE_VERSION" != lite ] && [ "$VERIFY_STATUS" = 0 ] || { ddnsto_error 'OpenWrt options are not supported on Linux'; return 2; }
    fi
}

ddnsto_local_platform() {
    [ "$(uname -s)" = Linux ] || { ddnsto_error 'unsupported platform'; return 2; }
    os=linux package_manager=unknown device=
    if [ -f /etc/openwrt_release ]; then
        os=openwrt
        if command -v opkg >/dev/null 2>&1; then package_manager=opkg
        elif command -v apk >/dev/null 2>&1; then package_manager=apk; fi
    fi
    ddnsto_detect_platform || return $?
}

ddnsto_plan() {
    # No bootstrap in preview mode. Actual installation uses zsetup context;
    # local preflight is deliberately labelled, not an installation guarantee.
    ddnsto_local_platform || return $?
    if [ "$detected_platform" = synology ]; then ddnsto_synology_download; return $?; fi
    if [ "$detected_platform" = asus ]; then
        ddnsto_asus_facts || return $?
        printf '%s\n' 'facts_source=local-preflight' 'platform=asus' "channel=$ASUS_CHANNEL" "arch=$ASUS_ARCH" 'client_version=4.2.8' 'native_status=requires-plugin-preflight' 'installation_performed=false'
        return 0
    fi
    [ -z "${OUTPUT_DIR:-}" ] && [ "$ACTION" != download ] || { ddnsto_error 'download and output-dir require Synology'; return 2; }
    case "$(uname -m)" in
        x86_64|amd64) arch=x86_64 ;;
        aarch64|arm64) arch=aarch64 ;;
        armv7l|armv7) arch=armv7 ;;
        mipsel|mipsle) arch=mipsel ;;
        *) ddnsto_error 'unsupported architecture'; return 2 ;;
    esac
    native_status=executor-unavailable client_version=unavailable
    case "$detected_platform:$arch" in
        linux:x86_64|linux:aarch64)
            [ "${DDNSTO_VERSION:-4.2.8}" = 4.2.8 ] || { ddnsto_error 'no pinned artifact for requested version'; return 2; }
            [ "$FORCE_VERSION" != lite ] && [ "$VERIFY_STATUS" = 0 ] || { ddnsto_error 'OpenWrt options are not supported on Linux'; return 2; }
            native_status=requires-service-preflight
            client_version=${DDNSTO_VERSION:-4.2.8} ;;
        openwrt:*)
            native_status=requires-package-preflight
            client_version=standard-4.2.8-or-lite-4.2.8 ;;
    esac
    printf '%s\n' 'facts_source=local-preflight' "platform=$detected_platform" "arch=$arch" \
        "requested_method=$REQUESTED_METHOD" "native_status=$native_status" "client_version=$client_version" \
        "docker_probe=$(ddnsto_probe_docker)" 'docker_installable=false' 'installation_performed=false'
    [ "$REQUESTED_METHOD" != docker ] && [ "$native_status" != executor-unavailable ] || return 2
}

ddnsto_prompt_token() (
    exec 3<>/dev/tty
    terminal_state=$(stty -g <&3)
    trap 'stty "$terminal_state" <&3; printf "\n" >&3' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    stty echo <&3
    printf 'DDNSTO token: ' >&3
    IFS= read -r entered_token <&3
    printf '%s' "$entered_token"
)
