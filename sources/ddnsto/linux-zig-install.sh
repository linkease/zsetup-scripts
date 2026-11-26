# Uses the ordinary protected service transaction, not an independent installer.
ddnsto_zig_install() {
    if [ -n "$SERVICE_OLD" ]; then
        [ "$(ddnsto_linux_current_variant)" = zig ] && [ "${SERVICE_OLD#versions/}" = "$version_num" ] || {
            ddnsto_error 'E_VERSION: cross-client migration or downgrade is not permitted'; return 2;
        }
    fi
    if [ "$SERVICE_CACHED" = 0 ]; then
        mkdir -p "$transaction_dir/products" || return 12
        installer_download "$PROCESS_PRODUCT_PATH" "$transaction_dir/products/ddnsto" "$digest" 0 "$PROCESS_DOWNLOAD_BYTES" || return $?
        chmod 0755 "$transaction_dir/products/ddnsto" || return 12
        installer_exec_native "$ZSETUP_BIN" capture -o "$transaction_dir/client-version" --max-bytes 128 \
            --min-free-bytes "$INSTALLER_RESERVE" -- "$transaction_dir/products/ddnsto" -v || return $?
        [ "$(cat "$transaction_dir/client-version")" = "$version_num" ] || {
            ddnsto_error 'E_VERSION: raw Zig version differs from reviewed product metadata'; return 11;
        }
        installer_service_stage || return $?
        ddnsto_zig_service_wrapper "$SERVICE_EXEC" "${SERVICE_CONFIG%/*}/.ddnsto-zig.yaml" > "$SERVICE_CANDIDATE/bin/.service-run" || return 12
        installer_service_copy ddnsto || return $?
        installer_service_commit_version || return $?
    fi
    installer_service_activate
}

ddnsto_zig_register() {
    [ "${BUSINESS_ENV:-production}" = production ] || return 2
    DDNSTO_ZIG_NEW_RUNTIME=0
    zig_state=${SERVICE_CONFIG%/*}
    if [ "${ACTION:-install}" = update ]; then
        SERVICE_CONFIG_TOUCHED=0
        ddnsto_managed_rewrite_unit || return $?
        ddnsto_linux_register_environment
        return $?
    fi
    [ "$SERVICE_HAD_CONFIG" = 0 ] && [ "$SERVICE_HAD_UNIT" = 0 ] || {
        ddnsto_error 'E_OWNERSHIP: existing configuration must not be overwritten'; return 2;
    }
    # Unknown runtime data is not an invitation to take over an old identity.
    for zig_existing in "$zig_state/.ddnsto-zig.yaml" "$zig_state/.ddnsto_boot.cfg"; do
        [ ! -e "$zig_existing" ] && [ ! -L "$zig_existing" ] || {
            ddnsto_error 'E_OWNERSHIP: existing Zig state requires explicit migration'; return 2;
        }
    done
    mkdir -p "$zig_state/logs" || return 12
    [ "$("$ZSETUP_BIN" storage "$zig_state/logs" get system_protected)" = true ] || return 12
    installer_exec_native "$ZSETUP_BIN" capture -o "$SERVICE_CONFIG" --max-bytes 16384 \
        --min-free-bytes "$INSTALLER_RESERVE" -- jq -n --arg token "$TOKEN" \
        '{token:$token,routeridx:0,supplierCode:""}' || return $?
    chmod 0600 "$SERVICE_CONFIG" || return 12
    installer_service_escape_exec "${SERVICE_EXEC%/*}/.service-run"
    printf '[Unit]\nDescription=DDNSTO Zig\nAfter=network.target\n[Service]\nType=simple\nExecStart=/bin/sh "%s"\nRestart=always\nRestartSec=5\n[Install]\nWantedBy=multi-user.target\n' \
        "$service_escaped" > "$transaction_dir/zig-unit" || return 12
    installer_exec_native "$ZSETUP_BIN" capture -o "$SERVICE_UNIT" --max-bytes 16384 \
        --min-free-bytes "$INSTALLER_RESERVE" -- cat "$transaction_dir/zig-unit" || return $?
    chmod 0644 "$SERVICE_UNIT" || return 12
    DDNSTO_ZIG_NEW_RUNTIME=1
    ddnsto_linux_register_environment
}
