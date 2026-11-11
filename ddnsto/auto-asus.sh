# ASUS appliance adapter. Never dispatch through the generic Linux installer.
ddnsto_asus_get() { /usr/bin/dbus get "$1"; }
ddnsto_asus_set() { /usr/bin/dbus set "$1=$2"; }

ddnsto_asus_busy() {
    [ -z "$(ddnsto_asus_get softcenter_installing_name)" ] &&
        [ -z "$(ddnsto_asus_get softcenter_installing_todo)" ]
}

ddnsto_asus_facts() {
    [ -x /bin/nvram ] && [ -x /usr/bin/dbus ] && [ -d /koolshare ] || {
        ddnsto_flow_error E_PLATFORM '需要兼容的华硕软件中心固件' '不会自动刷机或安装软件中心'; return 2;
    }
    asus_model=$(/bin/nvram get odmpid)
    [ -n "$asus_model" ] || asus_model=$(/bin/nvram get productid)
    ASUS_ARCH=$(uname -m)
    ASUS_CHANNEL=$(ddnsto_asus_channel "$asus_model" "$(uname -r)" "$ASUS_ARCH" "$(/bin/nvram get sc_url)") || {
        ddnsto_flow_error E_PLATFORM '无法安全确定华硕插件渠道或处理器兼容性' '请核对软件中心来源和机型'; return 2;
    }
}

ddnsto_asus_preflight() {
    # Do not load plugin-supplied commands or exported shell expressions.
    PATH=/usr/sbin:/usr/bin:/sbin:/bin; export PATH
    ddnsto_asus_facts || return $?
    ddnsto_asus_storage || { ddnsto_flow_error E_STORAGE '华硕私有目录不安全或不可写' '请检查 /jffs 挂载及剩余空间'; return 12; }
    for tool in awk openssl curl tar cmp wc readlink df; do
        ddnsto_asus_has "$tool" || { ddnsto_flow_error E_DEPENDENCY '固件缺少安装校验工具' "缺少 $tool，请通过软件中心手动安装"; return 2; }
    done
    asus_available=$(df -Pk /jffs | awk 'NR==2 { print $4 }')
    case "$asus_available" in ''|*[!0-9]*) return 12 ;; esac
    [ "$asus_available" -ge 98304 ] || {
        ddnsto_flow_error E_SPACE '安装及恢复备份需要至少 96 MiB 可用空间' '请释放 JFFS 空间后重试，不会删除现有插件'; return 12;
    }
}

ddnsto_asus_transport() (
    # Reuse the audited bounded HTTPS transport without changing other shells.
    if ! type command >/dev/null 2>&1; then
        command() { [ "$1" = -v ] && [ "$#" = 2 ] && type "$2"; }
    fi
    ddnsto_https_fetch "$@"
)

ddnsto_asus_native() {
    umask 077
    case "$ASUS_ARCH" in aarch64) ZSETUP_ARCH=aarch64 ;; armv7l) ZSETUP_ARCH=armv7 ;; *) return 2 ;; esac
    fetch_bootstrap_metadata || return $?
    native_cache=$ASUS_STATE/native-$RESCUE_VERSION-$ZSETUP_ARCH
    ddnsto_asus_private_dir "$native_cache" || return 12
    ASUS_ZSETUP=$native_cache/zsetup
    if [ -e "$ASUS_ZSETUP" ] || [ -L "$ASUS_ZSETUP" ]; then
        ddnsto_asus_safe_file "$ASUS_ZSETUP" && [ -x "$ASUS_ZSETUP" ] &&
            [ "$(ddnsto_asus_hash "$ASUS_ZSETUP")" = "$EXPECTED_SHA256" ] || return 11
        return 0
    fi
    native_dir=$(ddnsto_asus_mktemp "$native_cache") || return 12
    native_code=0
    ddnsto_asus_transport "https://fw.koolcenter.com/binary/zsetup/$RESCUE_VERSION/zsetup-linux-$ZSETUP_ARCH" "$native_dir/zsetup" 16777216 || native_code=11
    if [ "$native_code" = 0 ]; then
        [ "$(ddnsto_asus_hash "$native_dir/zsetup")" = "$EXPECTED_SHA256" ] || native_code=11
    fi
    if [ "$native_code" = 0 ]; then
        chmod 700 "$native_dir/zsetup" && (cd "$native_cache" && mv -f "$native_dir/zsetup" .) || native_code=12
    fi
    rm -f "$native_dir/zsetup"
    rmdir "$native_dir" || return 12
    return "$native_code"
}

ddnsto_asus_fetch() {
    package_facts=$(ddnsto_asus_package "$ASUS_CHANNEL") || return 2
    set -- "$1" $package_facts
    asus_output=$1 asus_url=$2 asus_size=$5 asus_digest=$6
    if [ "$ASUS_CHANNEL" = armsoft ]; then
        # Explicitly approved Linux 2.6 compatibility path. Never unverified
        # execution or silent fallback after a modern native download fails.
        ddnsto_asus_transport "$asus_url" "$asus_output" "$asus_size" || return 11
    else
        ddnsto_asus_native || return $?
        "$ASUS_ZSETUP" download -o "$asus_output" --sha256 "$asus_digest" \
            --max-bytes "$asus_size" --min-free-bytes 8388608 "$asus_url" || return 11
    fi
    [ "$(wc -c < "$asus_output")" -eq "$asus_size" ] &&
        [ "$(ddnsto_asus_hash "$asus_output")" = "$asus_digest" ] || return 11
}

ddnsto_asus_ensure() {
    ddnsto_asus_preflight || return $?
    mkdir -m 700 "$ASUS_STATE/install.lock" 2>/dev/null || {
        ddnsto_flow_error E_BUSY '另一安装或恢复任务持有华硕安装锁' '请确认任务结束后再处理残留锁'; return 16;
    }
    ASUS_CANCEL=$ASUS_STATE/install.lock/cancel
    asus_cancel_rc=0 asus_worker= asus_worker_rc=0
    # Cancel at transaction checkpoints, then join recovery. Killing only an
    # intermediate shell can orphan its installer or release the lock too early.
    trap 'asus_cancel_rc=129; : > "$ASUS_CANCEL"' HUP
    trap 'asus_cancel_rc=130; : > "$ASUS_CANCEL"' INT
    trap 'asus_cancel_rc=143; : > "$ASUS_CANCEL"' TERM
    ddnsto_asus_ensure_locked &
    asus_worker=$!
    while :; do
        asus_worker_rc=0
        wait "$asus_worker" || asus_worker_rc=$?
        kill -0 "$asus_worker" 2>/dev/null || break
    done
    trap - HUP INT TERM
    rm -f "$ASUS_CANCEL"
    rmdir "$ASUS_STATE/install.lock" || return 16
    [ "$asus_cancel_rc" = 0 ] || return "$asus_cancel_rc"
    return "$asus_worker_rc"
}
