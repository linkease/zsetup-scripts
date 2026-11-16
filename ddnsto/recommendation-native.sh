# Opt-in local candidate only. Caller owns checked private work, HTTPS fetch,
# hash_file, fail and child cleanup. Never trust an environment-selected core.
ddnsto_recommend_native_prepare() {
    recommend_native=
    [ "$(uname -s)" = Linux ] || return 0
    # Appliance bootstrap locations and old kernels remain their own adapters.
    [ "$asus_entry" = 0 ] || return 0
    [ ! -f /etc/synoinfo.conf ] && [ ! -f /etc.defaults/VERSION ] &&
        [ ! -f /etc/config/uLinux.conf ] || return 0
    case "$(uname -m)" in
        x86_64) ZSETUP_ARCH=x86_64 ;;
        aarch64) ZSETUP_ARCH=aarch64 ;;
        *) return 0 ;;
    esac
    fetch_bootstrap_metadata || fail '缺少固定核心信息' '使用已审核的普通入口' 2
    core_rc=41
    for core_base in https://fw.koolcenter.com/binary https://fw.d4ctech.com/binary https://fw20.koolcenter.com/binary; do
        core_rc=0
        fetch "$core_base/zsetup/$RESCUE_VERSION/zsetup-linux-$ZSETUP_ARCH" "$work/native" 16777216 || core_rc=$?
        [ "$core_rc" = 41 ] || break
    done
    [ "$core_rc" = 0 ] || fail '固定核心下载失败' '检查 HTTPS 网络或使用普通入口；不会自动降级' 11
    [ -f "$work/native" ] && [ ! -L "$work/native" ] &&
        [ "$(hash_file "$work/native")" = "$EXPECTED_SHA256" ] ||
        fail '固定核心校验失败' '联系发布者核对核心；未执行下载内容' 11
    chmod 700 "$work/native" || fail '无法保护固定核心' '检查私有工作目录' 12
    recommend_native=$work/native
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
