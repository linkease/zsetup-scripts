# Included at build time; only install.sh is a public installer.
ddnsto_error() { printf 'DDNSTO: %s\n' "$*" >&2; }

ddnsto_usage() {
    printf '%s\n' 'Usage: install.sh [--plan] [--action install|update|status|start|stop|restart|repair|configure|uninstall|download] [--platform auto|linux|openwrt|macos|windows|synology|qnap|unraid] [--method auto|native|docker] [--token TOKEN | --token-file FILE] [--force-version lite|standard] [--verify-status]' \
        '--plan: read-only local preflight; no downloads, token, or service changes.' \
        'Platform is a constraint, not an override. QNAP/Unraid are unavailable; Windows requires install.ps1.' \
        'Synology: verified SPK download, manual DSM installation required; optional --output-dir DIR.' \
        'Docker: experimental local Linux amd64/root only; first install requires --device-name NAME --network bridge|host and Token.' \
        'Docker replacement/recreation is blocked pending identity validation. No native/container migration.' \
        'Linux repair/configure/uninstall require owned systemd service; configure also requires jq.' \
        'OpenWrt: token optional; automatic Lite selection below 900 MB.' \
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
    ACTION=install
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
    case "$REQUESTED_PLATFORM" in auto|linux|openwrt|macos|windows|synology|qnap|unraid) ;; *) ddnsto_error 'unknown platform'; return 2 ;; esac
    case "$REQUESTED_METHOD" in auto|native|docker) ;; *) ddnsto_error 'unknown installation method'; return 2 ;; esac
    [ "$REQUESTED_METHOD" = docker ] || [ -z "$DEVICE_NAME$NETWORK" ] || { ddnsto_error 'device-name/network require explicit Docker'; return 2; }
    case "$NETWORK" in ''|bridge|host) ;; *) ddnsto_error 'network must be bridge or host'; return 2 ;; esac
    if [ -n "$OUTPUT_DIR" ]; then
        case "$ACTION" in install|download) ;; *) ddnsto_error 'output-dir only applies to Synology downloads'; return 2 ;; esac
    fi
    case "$FORCE_VERSION" in ''|lite|standard) ;; *) ddnsto_error 'version must be lite or standard'; return 2 ;; esac
    case "$ACTION" in
        install|update) ;;
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
        install|update|download) return 0 ;;
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

ddnsto_native_conflict_guard() {
    [ "${business_platform:-${detected_platform:-}}" = linux ] || return 0
    native_docker_state=${DDNSTO_DOCKER_STATE_DIR:-/etc/ddnsto-docker}
    if ddnsto_privileged test -e "$native_docker_state" || ddnsto_privileged test -L "$native_docker_state"; then
        ddnsto_error 'Docker state conflicts with native installation; automatic migration is not supported'
        return 2
    fi
}

ddnsto_select_platform() {
    ddnsto_detect_platform || return $?
    [ -z "${OUTPUT_DIR:-}" ] && [ "$ACTION" != download ] || { ddnsto_error 'download and output-dir require Synology'; return 2; }
    if [ "$REQUESTED_METHOD" = docker ]; then
        ddnsto_error 'Docker installer is not available in this candidate; use the official Docker guide; native installation was not attempted'
        return 2
    fi
    case "$detected_platform" in
        linux|openwrt) business_platform=$detected_platform ;;
        *) ddnsto_error "$detected_platform installer is not available in this candidate; use the official device guide; generic Linux installation was not attempted"; return 2 ;;
    esac
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
            [ "${DDNSTO_VERSION:-4.2.3}" = 4.2.3 ] || { ddnsto_error 'no pinned artifact for requested version'; return 2; }
            [ "$FORCE_VERSION" != lite ] && [ "$VERIFY_STATUS" = 0 ] || { ddnsto_error 'OpenWrt options are not supported on Linux'; return 2; }
            native_status=requires-service-preflight
            client_version=${DDNSTO_VERSION:-4.2.3} ;;
        openwrt:*)
            native_status=requires-package-preflight
            client_version=standard-4.2.6-or-lite-4.2.2 ;;
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

ddnsto_prepare_token() {
    [ "${RETAINED_CONFIG:-0}" != 1 ] || return 0
    if [ "${ACTION:-install}" = update ] && [ "$business_platform" = linux ]; then return 0; fi
    [ -z "$TOKEN" ] || return 0
    if [ "$business_platform" = openwrt ]; then
        TOKEN=$(uci -q get 'ddnsto.@ddnsto[0].token' 2>/dev/null) || TOKEN=
        [ -z "$TOKEN" ] || return 0
    fi
    if [ -t 0 ]; then
        TOKEN=$(ddnsto_prompt_token) || { ddnsto_error 'could not read token'; return 2; }
        [ -n "$TOKEN" ] || { ddnsto_error 'empty token'; return 2; }
    elif [ "$business_platform" = linux ]; then
        ddnsto_error 'Linux needs --token or --token-file without an interactive terminal'
        return 2
    fi
    # Preserve the existing unattended OpenWrt package-only contract.
}

ddnsto_choose_existing_action() (
    [ -t 0 ] || { printf exit; return; }
    exec 3<>/dev/tty
    printf '%s\n' 'Existing DDNSTO installation detected.' '0) Exit without changes (default)' '1) Update using existing configuration' \
        '2) Repair managed service' '3) Change Token explicitly' '4) Status' '5) Stop and disable startup' \
        '6) Start and enable startup' '7) Uninstall managed program (retain configuration)' >&3
    printf 'Choose [0]: ' >&3
    IFS= read -r choice <&3 || choice=
    case "$choice" in ''|0) printf exit ;; 1) printf update ;; 2) printf repair ;; 3) printf configure ;;
        4) printf status ;; 5) printf stop ;; 6) printf start ;; 7) printf uninstall ;; *) return 2 ;; esac
)

ddnsto_existing_policy() {
    INSTALL_SKIPPED=0
    RETAINED_CONFIG=0
    if [ "$business_platform" = openwrt ]; then
        existing_binary=${DDNSTO_OPENWRT_BIN_PATH:-/usr/sbin/ddnstod}
        existing_config=${DDNSTO_CONFIG_PATH:-/etc/config/ddnsto}
        existing_service=${DDNSTO_SERVICE_PATH:-/etc/init.d/ddnsto}
        existing_marker=${existing_config%/*}/.uninstalled-openwrt-v1
        for existing_path in "$existing_binary" "$existing_config" "$existing_service" "$existing_marker"; do
            ddnsto_ow_safe_path "$existing_path" || {
                ddnsto_error 'unsafe OpenWrt installation path'; return 2
            }
        done
        if [ -e "$existing_marker" ]; then
            ddnsto_openwrt_retained_state_valid || {
                ddnsto_error 'unrecognized retained OpenWrt marker; no migration attempted'; return 2
            }
            [ "$ACTION" = install ] && [ -z "$TOKEN$TOKEN_FILE" ] || {
                ddnsto_error 'retained OpenWrt installation: use install without credentials to reuse configuration'; return 2
            }
            RETAINED_CONFIG=1
            return 0
        fi
        if [ -e "$existing_binary" ] || [ -e "$existing_config" ] || [ -e "$existing_service" ]; then
            [ -f "$existing_binary" ] && [ -f "$existing_config" ] || {
                ddnsto_error 'incomplete or unrecognized OpenWrt installation; automatic package replacement is unavailable'; return 2
            }
            if [ "$ACTION" = install ]; then
                [ -z "$TOKEN$TOKEN_FILE" ] || { ddnsto_error 'existing installation preserves Token; use configure explicitly'; return 2; }
                selected_action=$(ddnsto_choose_existing_action) || { ddnsto_error 'invalid action; no changes made'; return 2; }
                if [ "$selected_action" = exit ]; then
                    printf '%s\n' 'operation=none installation=existing cloud_status=unverified' 'No changes made. Use --action update to update explicitly.'
                    INSTALL_SKIPPED=1
                    return 0
                fi
                ACTION=$selected_action
            fi
        elif [ "$ACTION" = update ]; then
            ddnsto_error 'no existing installation; use the install action first'; return 2
        fi
        return 0
    else
        existing_binary=${DDNSTO_BIN_PATH:-/usr/local/bin/ddnsto}
        existing_dir=${DDNSTO_LINUX_CONFIG_DIR:-/etc/ddnsto}
        existing_config=$existing_dir/ddnsto-config.json
        if [ -d "$existing_dir" ] && [ ! -x "$existing_dir" ] && [ "$(id -u)" != 0 ]; then
            command -v sudo >/dev/null 2>&1 || { ddnsto_error 'root or sudo required to inspect protected existing configuration'; return 2; }
            SUDO=sudo
            sudo -v || return 2
        fi
        if ! ddnsto_privileged test -e "$existing_binary" && ! ddnsto_privileged test -L "$existing_binary" &&
           ddnsto_linux_state_valid "${DDNSTO_LINUX_CONFIG_DIR:-/etc/ddnsto}/.uninstalled-linux-v1"; then
            [ "$ACTION" = install ] && [ -z "$TOKEN$TOKEN_FILE" ] || {
                ddnsto_error 'retained installation: use install without credentials to reuse configuration'; return 2;
            }
            ddnsto_privileged test ! -e "$existing_dir/.installer-linux-v1" || return 2
            ddnsto_privileged test -f "$existing_config" && ddnsto_privileged test ! -L "$existing_config" || return 2
            RETAINED_CONFIG=1
            return 0
        fi
    fi
    if ddnsto_privileged test -e "$existing_binary" || ddnsto_privileged test -L "$existing_binary" || ddnsto_privileged test -e "$existing_config" || ddnsto_privileged test -L "$existing_config"; then
        ddnsto_privileged test -f "$existing_binary" && ddnsto_privileged test ! -L "$existing_binary" && ddnsto_privileged test -f "$existing_config" && ddnsto_privileged test ! -L "$existing_config" || {
            ddnsto_error 'incomplete or unrecognized installation; check files and permissions before retrying'; return 2;
        }
        if [ "$ACTION" = install ]; then
            [ -z "$TOKEN$TOKEN_FILE" ] || { ddnsto_error 'existing installation preserves Token; use --action update without credentials'; return 2; }
            selected_action=$(ddnsto_choose_existing_action) || { ddnsto_error 'invalid action; no changes made'; return 2; }
            if [ "$selected_action" = exit ]; then
                printf '%s\n' 'operation=none installation=existing cloud_status=unverified' 'No changes made. Use --action update to update explicitly.'
                INSTALL_SKIPPED=1
                return 0
            fi
            ACTION=$selected_action
        fi
    elif [ "$ACTION" = update ]; then
        ddnsto_error 'no existing installation; use the install action first'; return 2
    fi
}

ddnsto_download() {
    download_relative=$1
    download_output=$2
    download_sha=${3:-}
    download_fresh=${4:-0}
    set -- "$ZSETUP_BIN" download -o "$download_output"
    [ -z "$download_sha" ] || set -- "$@" --sha256 "$download_sha"
    [ "$download_fresh" = 0 ] || set -- "$@" --no-cache
    [ -z "${ZSETUP_CA_FILE:-}" ] || set -- "$@" --ca-file "$ZSETUP_CA_FILE"
    for download_base in $ZSETUP_SOURCE_BASES; do
        set -- "$@" "${download_base%/}/ddnsto/$download_relative"
    done
    [ -z "${ZSETUP_SOURCE_FALLBACK:-}" ] || set -- "$@" --fallback-url "${ZSETUP_SOURCE_FALLBACK%/}/ddnsto/$download_relative"
    "$@"
}

# Markers are written only after zsetup has verified and committed an artifact.
ddnsto_verified_download() {
    verified_relative=$1
    verified_output=$2
    verified_sha=$3
    verified_marker="$verified_output.verified"
    # A size/marker match cannot authenticate cached bytes. Let zsetup verify
    # the digest on every use; its own verified download cache avoids transfers.
    ddnsto_download "$verified_relative" "$verified_output" "$verified_sha" || return $?
    [ -f "$verified_output" ] && [ ! -L "$verified_output" ] || return 11
    verified_size=$(wc -c < "$verified_output") || return $?
    verified_size=$(printf '%s' "$verified_size" | tr -d '[:space:]')
    printf '%s:%s\n' "$verified_sha" "$verified_size" > "$transaction_dir/verified" || return $?
    mv -f "$transaction_dir/verified" "$verified_marker" || return $?
}

ddnsto_rollback() {
    [ "${replacement_started:-0}" = 1 ] || return 0
    ddnsto_linux_restore || {
        ddnsto_error "manual recovery needed; binary/config backup retained at $backup"
        return 1
    }
}

ddnsto_cleanup() {
    ddnsto_rollback || true
    [ -z "${install_candidate:-}" ] || ddnsto_privileged rm -f "$install_candidate"
    if [ "${replacement_started:-0}" = 0 ] && [ -n "${backup:-}" ]; then
        ddnsto_privileged rm -rf "$backup"
    fi
    if [ "${deprecated_config:-0}" = 1 ] && [ -f "${transaction_dir:-}/deprecated-config" ]; then
        cp -p "$transaction_dir/deprecated-config" "$config_path"
    fi
    [ -z "${transaction_dir:-}" ] || rm -rf "$transaction_dir"
}

ddnsto_privileged() {
    if [ -n "${SUDO:-}" ]; then "$SUDO" "$@"; else "$@"; fi
}

ddnsto_linux_state_valid() {
    state_file=$1
    ddnsto_privileged test -f "$state_file" && ddnsto_privileged test ! -L "$state_file" || return 1
    state_expected=$(printf 'ddnsto-linux-v1\n%s\n%s\n' "${DDNSTO_BIN_PATH:-/usr/local/bin/ddnsto}" "${DDNSTO_LINUX_CONFIG_DIR:-/etc/ddnsto}/ddnsto-config.json")
    state_actual=$(ddnsto_privileged cat "$state_file") || return 1
    [ "$state_actual" = "$state_expected" ]
}

ddnsto_linux_write_state() (
    state_target=$1
    state_dir=${DDNSTO_LINUX_CONFIG_DIR:-/etc/ddnsto}
    ddnsto_privileged test ! -L "$state_dir" && ddnsto_privileged test ! -L "$state_target" || exit 2
    state_temp=$(ddnsto_privileged mktemp "$state_dir/.installer-state.XXXXXX") || exit $?
    trap 'ddnsto_privileged rm -f "$state_temp"' EXIT
    printf 'ddnsto-linux-v1\n%s\n%s\n' "${DDNSTO_BIN_PATH:-/usr/local/bin/ddnsto}" "$state_dir/ddnsto-config.json" |
        ddnsto_privileged tee "$state_temp" >/dev/null || exit $?
    ddnsto_privileged chmod 0644 "$state_temp" || exit $?
    ddnsto_privileged mv -f "$state_temp" "$state_target"
)

# One machine-wide lock, independent of bootstrap cache and client version.
# The callback gets its own shell so its transaction traps cannot replace the
# lock owner's EXIT trap. Do not call this function from a conditional: callbacks
# rely on errexit to stop at the first failed installation command.
ddnsto_with_operation_lock() {
    set -e
    SUDO=
    if [ "$(id -u)" != 0 ]; then
        [ "${business_platform:-${detected_platform:-linux}}" != openwrt ] || {
            ddnsto_error 'OpenWrt changes require root'; exit 2;
        }
        command -v sudo >/dev/null 2>&1 || { ddnsto_error 'service changes require root or sudo'; exit 2; }
        SUDO=sudo
        sudo -v || exit 2
    fi
    operation_lock=${DDNSTO_LOCK_DIR:-/var/lock/ddnsto-installer.lock}
    case "$operation_lock" in /*) ;; *) ddnsto_error 'operation lock path must be absolute'; exit 2 ;; esac
    # No mkdir -p, no following existing links, and no stale-lock auto-removal.
    if ! ddnsto_privileged mkdir -m 700 "$operation_lock" 2>/dev/null; then
        ddnsto_error 'operation lock unavailable: another action may be active; check permissions or stale lock only after confirming no installer is running'
        exit 16
    fi
    trap 'lock_code=$?; trap - EXIT HUP INT TERM; ddnsto_privileged rmdir "$operation_lock" || { ddnsto_error "could not release operation lock"; [ "$lock_code" != 0 ] || lock_code=16; }; exit "$lock_code"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    ( "$@" )
    lock_code=0
    ddnsto_privileged rmdir "$operation_lock" || { ddnsto_error 'could not release operation lock'; lock_code=16; }
    trap - EXIT HUP INT TERM
    return "$lock_code"
}

ddnsto_openwrt() {
    SUDO=
    [ "$(id -u)" = 0 ] || { ddnsto_error 'OpenWrt installation requires root'; return 2; }
    binary=${DDNSTO_OPENWRT_BIN_PATH:-/usr/sbin/ddnstod}
    config=${DDNSTO_CONFIG_PATH:-/etc/config/ddnsto}
    service_path=${DDNSTO_SERVICE_PATH:-/etc/init.d/ddnsto}
    ow_retained_marker=${config%/*}/.uninstalled-openwrt-v1
    for ow_path in "$binary" "$config" "$service_path" "$ow_retained_marker"; do
        ddnsto_ow_safe_path "$ow_path" || { ddnsto_error 'unsafe OpenWrt installation path'; return 2; }
    done
    ow_preserve_config=0
    if [ -e "$config" ]; then
        [ -f "$config" ] || { ddnsto_error 'regular UCI config required'; return 2; }
        if [ -e "$ow_retained_marker" ]; then
            ddnsto_openwrt_retained_state_valid || { ddnsto_error 'unrecognized retained OpenWrt marker'; return 2; }
        else
            ddnsto_ow_owned "$config" || { ddnsto_error 'OpenWrt configuration ownership unavailable; migration refused'; return 2; }
        fi
        ow_preserve_config=1
    elif [ "$ACTION" = update ] || [ -e "$binary" ] || [ -e "$service_path" ] || [ -e "$ow_retained_marker" ]; then
        ddnsto_error 'incomplete or unrecognized OpenWrt installation; configuration must be recovered first'; return 2
    fi
    case "$package_manager" in opkg) pkg_ext=ipk ;; apk) pkg_ext=apk ;; *) ddnsto_error 'OpenWrt requires opkg or apk'; return 2 ;; esac
    if [ "$ow_preserve_config" = 0 ]; then
        ow_packages=$(ddnsto_ow_packages) || { ddnsto_error 'package metadata unavailable'; return 2; }
        if ddnsto_ow_has_package ddnsto; then
            ddnsto_error 'registered DDNSTO package has no managed configuration; external migration refused'; return 2
        fi
    fi
    case "$arch" in
        x86_64|aarch64|mipsel) package_arch=$arch ;;
        armv7|arm) package_arch=arm ;;
        *) ddnsto_error "unsupported OpenWrt architecture: $arch"; return 2 ;;
    esac
    SELECTED_VERSION=$FORCE_VERSION
    if [ -z "$SELECTED_VERSION" ]; then
        mem_mb=${DDNSTO_MEM_MB:-${ZSETUP_MEMORY_TOTAL_MB:-$("$ZSETUP_BIN" context get memory_total_mb)}}
        case "$mem_mb" in ''|*[!0123456789]*) mem_mb=0 ;; esac
        if [ "$mem_mb" -gt 0 ] && [ "$mem_mb" -lt 900 ]; then SELECTED_VERSION=lite; else SELECTED_VERSION=standard; fi
    fi
    status "[2/4] Checking DDNSTO $SELECTED_VERSION version ($package_manager/$arch)..."
    version_num=$(ddnsto_pinned_version "$SELECTED_VERSION") || return $?
    version_folder=$SELECTED_VERSION
    [ "$pkg_ext" != apk ] || version_folder="$version_folder-apk"
    relative_folder="openwrt/$version_folder/$version_num"
    status "      DDNSTO $version_num ($SELECTED_VERSION; Lite below 900 MB)"
    status '[3/4] Downloading and verifying DDNSTO packages...'
    package_cache="$work_dir/cache/$version_folder/$version_num/$arch"
    mkdir -p "$package_cache" || return $?
    main_package="ddnsto_$package_arch.$pkg_ext"
    ui_package="luci-app-ddnsto.$pkg_ext"
    language_package="luci-i18n-ddnsto-zh-cn.$pkg_ext"
    for package in "$main_package" "$ui_package" "$language_package"; do
        case "$package" in
            ddnsto_*) product_path="$relative_folder/$package" ;;
            *) product_path="openwrt/$package" ;;
        esac
        digest=$(ddnsto_pinned_sha "$product_path") || return $?
        ddnsto_verified_download "$product_path" "$package_cache/$package" "$digest" || return $?
    done
    status '[4/4] Installing DDNSTO packages...'
    # All packages are verified before touching dependencies or installed packages.
    # Package-only callback: the retention wrapper disables UCI and stops the
    # old service before hooks run. Explicit errors work even in conditionals.
    ddnsto_openwrt_install_packages() {
        if [ "$package_manager" = opkg ]; then
            if [ -f /www/luci-static/resources/luci.js ] && [ ! -f /usr/lib/lua/luci/cbi.lua ]; then
                opkg update && opkg install luci-compat || return $?
            fi
            if ! opkg list-installed | grep -q '^luci-lua-runtime '; then
                opkg update && opkg install luci-lua-runtime || return $?
            fi
        else
            if [ -f /www/luci-static/resources/luci.js ] && [ ! -f /usr/lib/lua/luci/cbi.lua ]; then
                apk update && apk add luci-compat || return $?
            fi
            if ! apk info -e luci-lua-runtime >/dev/null 2>&1; then
                apk update && apk add luci-lua-runtime || return $?
            fi
        fi
        ow_packages=$(ddnsto_ow_packages) || return 2
        set --
        for package in app-meta-ddnsto luci-i18n-ddnsto-zh-cn luci-app-ddnsto ddnsto; do
            if ddnsto_ow_has_package "$package"; then set -- "$@" "$package"; fi
        done
        if [ "$#" -gt 0 ]; then
            if [ "$package_manager" = opkg ]; then opkg remove "$@" || return $?
            else apk del "$@" || return $?; fi
        fi
        for package in "$main_package" "$ui_package" "$language_package"; do
            if [ "$package_manager" = opkg ]; then opkg install "$package_cache/$package" || return $?
            else apk add --allow-untrusted "$package_cache/$package" || return $?; fi
        done
    }
    if [ "$ow_preserve_config" = 1 ]; then
        ddnsto_openwrt_with_retained_config ddnsto_openwrt_install_packages || return $?
        ddnsto_openwrt_resume_config || return $?
        if [ -e "$ow_retained_marker" ]; then
            ddnsto_openwrt_retained_state_valid && rm -f "$ow_retained_marker" || {
                ddnsto_error 'reinstall completed but retained marker cleanup failed'; return 15
            }
        fi
    else
        ddnsto_openwrt_install_packages || return $?
        if [ -n "$TOKEN" ]; then
            ( ACTION=configure; ddnsto_openwrt_lifecycle ) || return $?
        else
            status 'DDNSTO: get a token at https://www.ddnsto.com and configure it in LuCI'
        fi
    fi
    "$binary" -v || return $?
    if [ "$VERIFY_STATUS" = 1 ]; then
        pgrep -x ddnstod >/dev/null || { ddnsto_error 'DDNSTO process not found'; return 1; }
        ddnsto -w
    fi
    status 'DDNSTO packages installed; cloud_status=unverified'
    status 'Confirm this device is online in the DDNSTO console: https://www.ddnsto.com/; refresh LuCI if its menu is missing'
}

ddnsto_linux() {
    case "$arch" in x86_64|aarch64) ;; *) ddnsto_error "unsupported Linux architecture: $arch"; return 2 ;; esac
    [ "$FORCE_VERSION" != lite ] || { ddnsto_error 'Linux only supports standard'; return 2; }
    [ "$VERIFY_STATUS" = 0 ] || { ddnsto_error '--verify-status is for OpenWrt'; return 2; }
    [ -n "$TOKEN" ] || [ "$ACTION" = update ] || [ "${RETAINED_CONFIG:-0}" = 1 ] || { ddnsto_error 'empty token'; return 2; }
    ddnsto_linux_preflight
    version_num=${DDNSTO_VERSION:-4.2.3}
    case "$version_num" in ''|*[!0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._+-]*) ddnsto_error 'invalid DDNSTO_VERSION'; return 2 ;; esac
    status "[2/4] Checking DDNSTO standard $version_num ($arch)..."
    archive_name="ddnsto-standard-$version_num.tar.gz"
    digest=$(ddnsto_pinned_sha "linux-binary/$archive_name")
    mkdir -p "$work_dir/cache/linux-binary"
    archive_path="$work_dir/cache/linux-binary/$archive_name"
    status '[3/4] Downloading DDNSTO (verified cached artifacts are reused)...'
    ddnsto_verified_download "linux-binary/$archive_name" "$archive_path" "$digest"
    member="ddnsto-standard-$version_num/ddnsto.$arch"
    tar -xzf "$archive_path" -C "$transaction_dir" "$member"
    extracted="$transaction_dir/$member"
    [ -f "$extracted" ] && [ ! -L "$extracted" ] || { ddnsto_error 'archive binary is missing or is a symlink'; return 11; }
    chmod 0755 "$extracted"
    "$extracted" -v
    bin_path=${DDNSTO_BIN_PATH:-/usr/local/bin/ddnsto}
    bin_dir=$(dirname "$bin_path")
    [ ! -L "$bin_path" ] || { ddnsto_error 'installed binary must not be a symlink'; return 2; }
    status '[4/4] Installing and starting DDNSTO...'
    ddnsto_privileged mkdir -p "$bin_dir"
    install_candidate="$bin_dir/.ddnsto-candidate.$$"
    backup=$(ddnsto_privileged mktemp -d "$bin_dir/.ddnsto-backup.XXXXXX")
    ddnsto_privileged cp "$extracted" "$install_candidate"
    ddnsto_privileged chmod 0755 "$install_candidate"
    had_old=0
    had_config=0
    if ddnsto_privileged test -f "$linux_config_file"; then
        ddnsto_privileged cp -p "$linux_config_file" "$backup/config"
        had_config=1
    fi
    [ "$ACTION" != update ] || [ "$had_config" = 1 ] || { ddnsto_error 'existing configuration disappeared; refusing update'; return 2; }
    if [ -f "$bin_path" ]; then
        ddnsto_privileged cp -p "$bin_path" "$backup/binary"
        had_old=1
        ddnsto_linux_stop
        if ddnsto_linux_running >/dev/null 2>&1; then
            ddnsto_error 'old service is still running; refusing binary replacement'
            return 13
        fi
    fi
    replacement_started=1
    ddnsto_privileged mv -f "$install_candidate" "$bin_path"
    install_candidate=
    set -- "$bin_path" -daemon
    if [ "$ACTION" != update ] && [ "${RETAINED_CONFIG:-0}" != 1 ]; then set -- "$bin_path" -u "$TOKEN" -daemon; fi
    if ddnsto_privileged "$@"; then
        ddnsto_linux_wait_healthy
        ddnsto_privileged chmod 0600 "$linux_config_file"
        ddnsto_privileged chmod 0700 "$linux_config_dir"
        ddnsto_linux_write_state "$linux_config_dir/.installer-linux-v1"
        ddnsto_privileged rm -f "$linux_config_dir/.uninstalled-linux-v1"
        replacement_started=0
        ddnsto_privileged rm -rf "$backup"
    else
        start_code=$?
        ddnsto_error 'start failed; restoring previous binary'
        return "$start_code"
    fi
    status 'DDNSTO installed; local_service=healthy cloud_status=unverified'
    status 'Confirm this device is online in the DDNSTO console: https://www.ddnsto.com/'
}

ddnsto_install() {
    : "${ZSETUP_BIN:?zsetup is required}" "${ZSETUP_SOURCE_BASES:?source group is required}"
    ddnsto_parse_args "$@"
    os=${ZSETUP_OS:-$("$ZSETUP_BIN" context get os)}
    package_manager=${ZSETUP_PACKAGE_MANAGER:-$("$ZSETUP_BIN" context get package_manager)}
    arch=${ZSETUP_ARCH:-$("$ZSETUP_BIN" context get arch)}
    device=$("$ZSETUP_BIN" context get device 2>/dev/null) || device=
    ddnsto_detect_platform || return $?
    if [ "$detected_platform" = synology ]; then ddnsto_synology_download; return $?; fi
    ddnsto_select_platform
    ddnsto_validate_platform_options || return $?
    ddnsto_native_conflict_guard || return $?
    ddnsto_existing_policy || return $?
    [ "$INSTALL_SKIPPED" = 0 ] || return 0
    case "$ACTION" in install|update) ;; *) ddnsto_dispatch_local_action; return $? ;; esac
    ddnsto_prepare_token
    ddnsto_with_operation_lock ddnsto_install_locked
}

ddnsto_install_locked() {
    ddnsto_native_conflict_guard || return $?
    # Recheck after acquiring the lock; a competing install may have completed
    # while the user was choosing an action or entering credentials.
    ddnsto_existing_policy </dev/null || return $?
    [ "$INSTALL_SKIPPED" = 0 ] || return 0
    work_dir=${ZSETUP_WORK_DIR:-${WORK_ROOT}/ddnsto}
    mkdir -p "$work_dir"
    chmod 0700 "$work_dir"
    transaction_dir=$(mktemp -d "$work_dir/.transaction.XXXXXX")
    install_candidate=
    backup=
    replacement_started=0
    trap ddnsto_cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [ "$business_platform" = openwrt ]; then ddnsto_openwrt; else ddnsto_linux; fi
    ddnsto_cleanup
    transaction_dir=
    trap - EXIT HUP INT TERM
}
