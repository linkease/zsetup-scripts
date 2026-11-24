# Opt-in local candidate only. Caller owns checked private work, fail and child
# cleanup. Core selection is delegated to the same platform stable bootstrap
# used by every app; DDNSTO does not maintain a private zsetup release pin.
ddnsto_recommend_native_prepare() {
    recommend_native=
    [ "$(uname -s)" = Linux ] || return 0
    # Appliance bootstrap locations and old kernels remain their own adapters.
    [ "$asus_entry" = 0 ] || return 0
    [ ! -f /etc/synoinfo.conf ] && [ ! -f /etc.defaults/VERSION ] &&
        [ ! -f /etc/config/uLinux.conf ] || return 0
    case "$(uname -m)" in x86_64|aarch64) ;; *) return 0 ;; esac
    WORK_ROOT=$work/zsetup-bootstrap
    ZSETUP_BIN=
    export WORK_ROOT ZSETUP_BIN
    recommend_native=$(bootstrap_zsetup_path) ||
        fail '最新稳定核心下载或校验失败' '检查 HTTPS 网络或使用普通入口' 11
}

ddnsto_recommend_native_download() {
    # Recommendation freshness and parsing remain shell-owned. The immutable
    # body requires the exact approved digest and size, never a native cache hit.
    native_rc=0
    "$recommend_native" download --quiet --no-cache --sha256 "$digest" --size "$size" \
        --max-bytes "$size" --min-free-bytes 8388608 --overall-timeout 20s \
        -o "$work/install.sh" "$base/immutable/$digest/install.sh" &
    entry_child=$!
    wait "$entry_child" || native_rc=$?
    entry_child=
    [ "$native_rc" = 0 ] || fail '原生下载或校验失败' '检查核心运行条件和 HTTPS；不会执行旧缓存或回退' 11
}
