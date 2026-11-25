# Reuse the native verified, bounded download/extraction and transaction owner.
ddnsto_process_fetch() {
    INSTALLER_REMOTE_APP=ddnsto
    installer_download "linux-binary/ddnsto-standard-$PROCESS_VERSION.tar.gz" "$transaction_dir/package.tar.gz" "$PROCESS_DIGEST" || {
        ddnsto_process_error E_DOWNLOAD '客户端包下载或 SHA-256 校验失败，未更改运行中的客户端'; return 11;
    }
    installer_extract_member "$transaction_dir/ddnsto" tar -xOzf "$transaction_dir/package.tar.gz" \
        "ddnsto-standard-$PROCESS_VERSION/ddnsto.$arch" || {
        ddnsto_process_error E_EXTRACT '无法解出对应架构客户端，请检查空间和 tar 工具'; return 11;
    }
    chmod 0700 "$transaction_dir/ddnsto" || return 12
    process_version=$("$transaction_dir/ddnsto" -v 2>/dev/null) || {
        ddnsto_process_error E_BINARY '已校验的客户端无法运行，可能是内核、ABI 或执行权限不兼容'; return 13;
    }
    [ "$process_version" = "$PROCESS_VERSION" ] || { ddnsto_process_error E_VERSION '客户端实际版本与推荐版本不一致'; return 11; }
    ddnsto_linux_environment_capability "$transaction_dir/ddnsto"
}

ddnsto_process_rollback() {
    [ "${PROCESS_CHANGED:-0}" = 1 ] && [ -n "$PROCESS_OLD_VERSION" ] || return 0
    ddnsto_process_stop || return 13
    cp -p "$transaction_dir/old-ddnsto" "$PROCESS_PREFIX/ddnsto" || return 12
    cp -p "$transaction_dir/old-receipt" "$PROCESS_PREFIX/receipt" || return 12
    BUSINESS_ENV=$PROCESS_OLD_ENV
    [ "$PROCESS_WAS_RUNNING" = 0 ] || ddnsto_process_start || return 13
    PROCESS_CHANGED=0
}

ddnsto_process_install() {
    PROCESS_VERSION=$(ddnsto_pinned_version standard linux) || return 2
    PROCESS_DIGEST=$(ddnsto_pinned_sha "linux-binary/ddnsto-standard-$PROCESS_VERSION.tar.gz") || return 11
    [ "$ACTION" != update ] || [ -n "$PROCESS_OLD_VERSION" ] || {
        ddnsto_process_error E_NOT_INSTALLED '尚无可升级的后台进程安装'; return 2;
    }
    if [ -n "$PROCESS_OLD_VERSION" ]; then
        process_order=$(ddnsto_version_order "$PROCESS_OLD_VERSION" "$PROCESS_VERSION") || return 2
        [ "$process_order" != 1 ] || { ddnsto_process_error E_VERSION '已安装版本高于推荐版本，不会降级'; return 2; }
        if [ "$process_order" = 0 ]; then
            [ "$PROCESS_DIGEST" = "$PROCESS_OLD_DIGEST" ] || { ddnsto_process_error E_VERSION '相同版本的安装包摘要发生变化'; return 11; }
            [ "$BUSINESS_ENV" != "$PROCESS_OLD_ENV" ] || return 0
        fi
    fi
    installer_policy ddnsto || return $?
    PROCESS_CHANGED=0; PROCESS_WAS_RUNNING=0
    INSTALLER_CLEANUP_HOOK=ddnsto_process_rollback
    ddnsto_flow_note installing
    ddnsto_process_fetch || return $?
    mkdir -p "$PROCESS_PREFIX/tmp" "$PROCESS_PREFIX/logs" || return 12
    if [ -n "$PROCESS_OLD_VERSION" ]; then
        cp -p "$PROCESS_PREFIX/ddnsto" "$transaction_dir/old-ddnsto" || return 12
        cp -p "$PROCESS_PREFIX/receipt" "$transaction_dir/old-receipt" || return 12
        if ddnsto_process_running; then PROCESS_WAS_RUNNING=1; fi
        PROCESS_CHANGED=1
        ddnsto_process_stop || return 13
    else
        installer_service_replace "$PROCESS_PREFIX" "'" "''"
        process_config_prefix=$service_replaced
        printf "userToken: '%s'\nbootConfigPath: '%s/.ddnsto_boot.cfg'\nlogPath: '%s/logs'\nhttpAddr: '127.0.0.1:0'\n" \
            "$TOKEN" "$process_config_prefix" "$process_config_prefix" > "$PROCESS_PREFIX/config.yaml" || return 12
    fi
    mv "$transaction_dir/ddnsto" "$PROCESS_PREFIX/ddnsto" || return 12
    printf '%s\n' ddnsto-process-v1 "$PROCESS_VERSION" "$PROCESS_DIGEST" "$arch" "$BUSINESS_ENV" > "$transaction_dir/receipt" || return 12
    mv "$transaction_dir/receipt" "$PROCESS_PREFIX/receipt" || return 12
}
