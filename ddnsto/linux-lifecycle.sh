# Only the installer owns these actions. Never infer ownership from a filename.
ddnsto_linux_unit_exists() {
    case "$linux_service_manager" in
        systemd)
            unit_load=$(ddnsto_privileged systemctl show --property=LoadState --value "$linux_service_name") || return 2
            case "$unit_load" in loaded) return 0 ;; not-found) return 1 ;; *) return 2 ;; esac ;;
        openrc) ddnsto_privileged rc-service --exists "$linux_service_name" ;;
    esac
}

ddnsto_linux_unit_path() {
    printf '/etc/systemd/system/%s.service\n' "$linux_service_name"
}

ddnsto_linux_unit_environment_path() {
    printf '/etc/sysconfig/%s\n' "$linux_service_name"
}

ddnsto_linux_lifecycle_stopped() (
    active_state=$(ddnsto_privileged systemctl show --property=ActiveState --value "$linux_service_name") || exit 2
    case "$active_state" in inactive|failed) exit 0 ;; active) exit 1 ;; *) exit 2 ;; esac
)

ddnsto_linux_lifecycle_safe_path() (
    # Do not follow a symlink in any component, including a dangling leaf.
    case "$1" in /*) ;; *) exit 2 ;; esac
    checked_path=$1
    while [ "$checked_path" != / ]; do
        ddnsto_privileged test ! -L "$checked_path" || exit 2
        checked_path=$(dirname "$checked_path")
    done
)

ddnsto_linux_lifecycle_file_target() {
    ddnsto_linux_lifecycle_safe_path "$1" || return 2
    # cp treats a directory destination as a container; that is never recovery.
    if ddnsto_privileged test -e "$1"; then ddnsto_privileged test -f "$1" || return 2; fi
}

ddnsto_linux_unit_owned() (
    # The old marker records binary/config paths, NOT ownership of a unit.
    # Validate the effective systemd command, its backing file, and overrides.
    ddnsto_linux_lifecycle_safe_path "$unit_path" || exit 2
    ddnsto_privileged test -f "$unit_path" || exit 2
    fragment=$(ddnsto_privileged systemctl show --property=FragmentPath --value "$linux_service_name") || exit 2
    [ "$fragment" = "$unit_path" ] || exit 2
    definition=$(ddnsto_privileged cat "$unit_path") || exit 2
    starts=0 section=
    while IFS= read -r line; do
        case "$line" in
            '['*']') section=$line ;;
            ExecStart=*)
                [ "$section" = '[Service]' ] || exit 2
                case "$line" in
                    "ExecStart=$bin_path run"|"ExecStart=$bin_path \"run\""|"ExecStart=\"$bin_path\" \"run\""|"ExecStart=\"$bin_path\" run") ;;
                    *) exit 2 ;;
                esac
                starts=$((starts + 1)) ;;
        esac
    done <<EOF
$definition
EOF
    [ "$starts" = 1 ] || exit 2
    reload=$(ddnsto_privileged systemctl show --property=NeedDaemonReload --value "$linux_service_name") || exit 2
    [ "$reload" = no ] || exit 2
    for property in DropInPaths ExecCondition ExecStartPre ExecStartPost ExecStop ExecStopPost ExecReload RootDirectory RootImage Environment User Group WorkingDirectory; do
        value=$(ddnsto_privileged systemctl show "--property=$property" --value "$linux_service_name") || exit 2
        [ -z "$value" ] || exit 2
    done
    environment_files=$(ddnsto_privileged systemctl show --property=EnvironmentFiles --value "$linux_service_name") || exit 2
    if [ -n "$environment_files" ]; then
        optional_environment=$(ddnsto_linux_unit_environment_path) || exit 2
        [ "$environment_files" = "$optional_environment (ignore_errors=yes)" ] || exit 2
        # kardianos/service v1.2.2 always declares this optional file. Only its
        # absence is safe without authenticating arbitrary environment settings.
        ddnsto_linux_lifecycle_safe_path "$optional_environment" || exit 2
        ddnsto_privileged test ! -e "$optional_environment" || exit 2
    fi
    execution=$(ddnsto_privileged systemctl show --property=ExecStart --value "$linux_service_name") || exit 2
    case "$execution" in
        "{ path=$bin_path ; argv[]=$bin_path run ; ignore_errors=no ; "*' }') ;;
        *) exit 2 ;;
    esac
    # Multiple ExecStart entries must not be mistaken for a single owned command.
    [ -z "${execution#*\}}" ] || exit 2
)

ddnsto_linux_lifecycle_restore() {
    # Called from a conditional trap: check every operation explicitly.
    ddnsto_linux_lifecycle_file_target "$unit_path" || return 1
    if ! ddnsto_privileged test -e "$unit_path"; then
        # A legacy uninstaller may have removed the file without daemon-reload.
        ddnsto_privileged systemctl daemon-reload || return 1
    fi
    restore_unit_rc=0
    ddnsto_linux_unit_exists || restore_unit_rc=$?
    case "$restore_unit_rc" in
        0)
            ddnsto_linux_unit_owned || return 1
            ddnsto_linux_stop >/dev/null 2>&1 || return 1
            ddnsto_linux_lifecycle_stopped || return 1 ;;
        1) ddnsto_linux_lifecycle_stopped || return 1 ;;
        *) return 1 ;;
    esac
    ddnsto_linux_lifecycle_file_target "$linux_config_file" || return 1
    ddnsto_linux_lifecycle_file_target "$bin_path" || return 1
    ddnsto_privileged cp -p "$lifecycle_backup/config" "$linux_config_file" || return 1
    ddnsto_privileged cp -p "$lifecycle_backup/binary" "$bin_path" || return 1
    if [ "$unit_present" = 1 ]; then
        ddnsto_privileged cp -p "$lifecycle_backup/unit" "$unit_path" || return 1
        ddnsto_privileged systemctl daemon-reload || return 1
        case "$unit_enabled" in
            enabled) ddnsto_privileged systemctl enable "$linux_service_name" >/dev/null 2>&1 || return 1 ;;
            disabled) ddnsto_privileged systemctl disable "$linux_service_name" >/dev/null 2>&1 || return 1 ;;
        esac
        if [ "$was_running" = 1 ]; then
            ddnsto_privileged systemctl start "$linux_service_name" || return 1
            ddnsto_linux_wait_healthy || return 1
        fi
    elif [ "$restore_unit_rc" = 0 ]; then
        ddnsto_privileged systemctl disable "$linux_service_name" >/dev/null 2>&1 || return 1
        ddnsto_privileged rm -f "$unit_path" || return 1
        ddnsto_privileged systemctl daemon-reload || return 1
    fi
    ddnsto_linux_lifecycle_file_target "$managed" || return 1
    ddnsto_linux_lifecycle_file_target "$retained" || return 1
    ddnsto_privileged cp -p "$lifecycle_backup/managed" "$managed" || return 1
    ddnsto_privileged rm -f "$retained" || return 1
}

ddnsto_linux_lifecycle() (
    set -e
    ddnsto_linux_preflight
    case "$ACTION" in repair|configure|uninstall) ;; *) exit 2 ;; esac
    # OpenRC definitions are executable shell scripts. The legacy marker cannot
    # authenticate them; refuse rather than execute/delete a same-named script.
    [ "$linux_service_manager" = systemd ] || {
        ddnsto_error 'Linux lifecycle requires verifiable systemd ownership; OpenRC lifecycle is not supported'; exit 2;
    }
    bin_path=${DDNSTO_BIN_PATH:-/usr/local/bin/ddnsto}
    managed="$linux_config_dir/.installer-linux-v1"
    retained="$linux_config_dir/.uninstalled-linux-v1"
    unit_path=$(ddnsto_linux_unit_path)
    for path in "$bin_path" "$linux_config_file" "$managed" "$retained" "$unit_path"; do
        ddnsto_linux_lifecycle_safe_path "$path" || exit 2
    done
    if [ "$ACTION" = uninstall ] && ddnsto_linux_state_valid "$retained" &&
       ! ddnsto_privileged test -e "$bin_path" && ! ddnsto_privileged test -L "$bin_path"; then
        ddnsto_privileged test -f "$linux_config_file" && ddnsto_privileged test ! -L "$linux_config_file" || exit 2
        ddnsto_privileged test ! -e "$managed" || exit 2
        unit_rc=0
        ddnsto_linux_unit_exists || unit_rc=$?
        [ "$unit_rc" = 1 ] && ddnsto_privileged test ! -e "$unit_path" || {
            ddnsto_error 'retained installation has an unexpected service or unknown service state'; exit 2;
        }
        ddnsto_linux_lifecycle_stopped || { ddnsto_error 'retained service is not confirmed stopped'; exit 2; }
        printf '%s\n' 'operation=none installation=uninstalled config=retained cloud_status=unverified'
        exit 0
    fi
    ddnsto_linux_state_valid "$managed" || {
        ddnsto_error 'managed Linux installation required; use an explicit reviewed update to register an older installation first'; exit 2;
    }
    for path in "$bin_path" "$linux_config_file"; do
        ddnsto_privileged test -f "$path" && ddnsto_privileged test ! -L "$path" || exit 2
    done
    ddnsto_privileged test ! -e "$retained" || { ddnsto_error 'conflicting lifecycle markers; manual recovery required'; exit 2; }
    if [ "$ACTION" = configure ]; then
        [ -n "$TOKEN" ] || { TOKEN=$(ddnsto_prompt_token) || exit 2; }
        [ -n "$TOKEN" ] || { ddnsto_error 'configure requires a nonempty Token'; exit 2; }
        command -v jq >/dev/null 2>&1 || { ddnsto_error 'Linux configure requires jq to preserve all JSON configuration fields'; exit 2; }
    fi
    unit_present=1
    unit_rc=0
    ddnsto_linux_unit_exists || unit_rc=$?
    case "$unit_rc" in 0) ;; 1) unit_present=0 ;; *) ddnsto_error 'cannot determine service ownership/state'; exit 2 ;; esac
    unit_enabled=disabled
    if [ "$unit_present" = 1 ]; then
        ddnsto_linux_unit_owned || { ddnsto_error 'service does not belong to this managed installation'; exit 2; }
        unit_enabled=$(ddnsto_privileged systemctl is-enabled "$linux_service_name") || [ "$unit_enabled" = disabled ] || exit 2
        case "$unit_enabled" in enabled|disabled) ;; *) ddnsto_error 'unsupported service enablement state'; exit 2 ;; esac
    else
        ddnsto_privileged test ! -e "$unit_path" || exit 2
    fi
    was_running=0
    active_state=$(ddnsto_privileged systemctl show --property=ActiveState --value "$linux_service_name") || exit 2
    case "$active_state" in
        active) [ "$unit_present" = 1 ] || exit 2; was_running=1 ;;
        inactive|failed) ;;
        *) ddnsto_error 'unknown or transitioning service state'; exit 2 ;;
    esac
    lifecycle_backup=$(ddnsto_privileged mktemp -d "$linux_config_dir/.lifecycle.XXXXXX")
    changed=0 keep_backup=0 lifecycle_success=
    lifecycle_cleanup() {
        lifecycle_code=$?
        trap - EXIT HUP INT TERM
        if [ "$changed" = 1 ]; then
            ddnsto_linux_lifecycle_restore || keep_backup=1
            [ "$lifecycle_code" != 0 ] || lifecycle_code=1
        fi
        if [ "$keep_backup" = 1 ]; then
            ddnsto_error "recovery incomplete; inspect service and retained backup: $lifecycle_backup"
        else
            ddnsto_privileged rm -rf "$lifecycle_backup" || {
                lifecycle_code=1
                ddnsto_error "backup cleanup failed: $lifecycle_backup"
            }
        fi
        if [ "$lifecycle_code" = 0 ] && [ -n "$lifecycle_success" ]; then printf '%s\n' "$lifecycle_success"; fi
        exit "$lifecycle_code"
    }
    trap lifecycle_cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    ddnsto_privileged cp -p "$linux_config_file" "$lifecycle_backup/config"
    ddnsto_privileged cp -p "$bin_path" "$lifecycle_backup/binary"
    ddnsto_privileged cp -p "$managed" "$lifecycle_backup/managed"
    if [ "$unit_present" = 1 ]; then ddnsto_privileged cp -p "$unit_path" "$lifecycle_backup/unit"; fi
    if [ "$ACTION" = configure ]; then
        # Do not log jq's input or the Token; only change the documented field.
        # Capture jq's status directly: a valid prefix followed by invalid JSON
        # must not be accepted just because tee succeeded. Require one object.
        staged_config=$(ddnsto_privileged jq -e -s --arg token "$TOKEN" 'if length == 1 and (.[0] | type == "object" and (.token | type == "string")) then .[0] | .token = $token else error("unsupported configuration") end' "$linux_config_file" 2>/dev/null) || {
            ddnsto_error 'configuration must contain exactly one valid JSON object with a token field'; exit 2;
        }
        printf '%s\n' "$staged_config" | ddnsto_privileged tee "$lifecycle_backup/config-new" >/dev/null
        ddnsto_privileged jq -e 'type == "object" and (.token | type == "string")' "$lifecycle_backup/config-new" >/dev/null || exit 2
    fi
    # Recheck after staging and before the first service mutation.
    if [ "$unit_present" = 1 ]; then
        ddnsto_linux_unit_owned || exit 2
        ddnsto_privileged cmp -s "$unit_path" "$lifecycle_backup/unit" || exit 2
    else
        unit_rc=0
        ddnsto_linux_unit_exists || unit_rc=$?
        [ "$unit_rc" = 1 ] && ddnsto_privileged test ! -e "$unit_path" || exit 2
    fi
    changed=1
    if [ "$unit_present" = 1 ]; then ddnsto_linux_stop; fi
    ddnsto_linux_lifecycle_stopped || { ddnsto_error 'service is not confirmed stopped'; exit 13; }
    if [ "$unit_present" = 1 ]; then
        ddnsto_linux_unit_owned || exit 2
        ddnsto_privileged cmp -s "$unit_path" "$lifecycle_backup/unit" || exit 2
    fi
    for path in "$bin_path" "$linux_config_file" "$managed"; do
        ddnsto_linux_lifecycle_file_target "$path" && ddnsto_privileged test -f "$path" || exit 2
    done
    if [ "$ACTION" = uninstall ]; then
        if [ "$unit_present" = 1 ]; then ddnsto_privileged "$bin_path" uninstall; fi
        ddnsto_linux_lifecycle_safe_path "$unit_path" || exit 2
        ddnsto_privileged test ! -e "$unit_path" || { ddnsto_error 'service definition still exists'; exit 13; }
        ddnsto_privileged systemctl daemon-reload
        unit_rc=0
        ddnsto_linux_unit_exists || unit_rc=$?
        [ "$unit_rc" = 1 ] || { ddnsto_error 'service registration still exists or cannot be verified'; exit 13; }
        # Preserve original bytes even if a legacy client touches config on exit.
        ddnsto_linux_lifecycle_file_target "$linux_config_file" || exit 2
        ddnsto_privileged cp -p "$lifecycle_backup/config" "$linux_config_file"
        ddnsto_privileged rm -f "$bin_path"
        ddnsto_linux_write_state "$retained"
        ddnsto_privileged rm -f "$managed"
        changed=0
        lifecycle_success='operation=uninstall local_service=not-installed config=retained cloud_status=unverified'
    else
        if [ "$ACTION" = configure ]; then
            ddnsto_privileged chmod 0600 "$lifecycle_backup/config-new"
            ddnsto_privileged mv -f "$lifecycle_backup/config-new" "$linux_config_file"
        fi
        if [ "$unit_present" = 1 ]; then
            ddnsto_privileged systemctl enable "$linux_service_name" >/dev/null 2>&1
            ddnsto_privileged systemctl start "$linux_service_name"
        else
            ddnsto_privileged "$bin_path" -daemon >/dev/null 2>&1
            ddnsto_linux_unit_owned || exit 2
        fi
        ddnsto_linux_wait_healthy
        changed=0
        lifecycle_success="operation=$ACTION local_service=healthy cloud_status=unverified"
    fi
)
