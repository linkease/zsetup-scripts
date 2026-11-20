#!/bin/sh
# Stable template. Package locally; do not source this file or pipe a manifest
# into a shell. Only the immutable, size+SHA verified installer is executed.
set +x
set -eu
umask 077
base='@@SOURCE_URL@@'
fail() { printf 'DDNSTO：%s；状态=推荐入口未执行安装；下一步=%s；code=%s\n' "$1" "$2" "$3" >&2; exit "$3"; }
case "$(uname -s)" in Linux|Darwin) ;; *) fail '不支持此系统' '使用对应平台入口' 2 ;; esac
case "$base" in https://*) ;; *) fail '入口尚未打包' '使用已审核的发布入口' 2 ;; esac
@@ASUS_STORAGE@@
@@PORTABLE_FILES@@
asus_entry=0
if [ -d /koolshare ] && [ -x /usr/bin/dbus ] && [ -x /bin/nvram ]; then
    asus_entry=1
    # Old ASUS ash omits the command builtin. Only -v is used by this entry.
    if ! type command >/dev/null 2>&1; then
        command() { [ "$1" = -v ] && [ "$#" = 2 ] && type "$2"; }
    fi
    ddnsto_asus_storage || fail '华硕私有存储检查失败' '检查 /jffs 挂载及权限，不要修改系统目录权限' 12
    required_tools='wc'
else
    required_tools='wc mktemp'
fi
# A hash backend is mandatory before any downloaded program can execute.
# Also expose the BusyBox SHA applet to child bootstrap scripts.
if ! command -v sha256sum >/dev/null 2>&1 && ! command -v openssl >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    required_tools="$required_tools sha256sum"
fi
missing_tools= busybox_tools= busybox_applets= busybox_checked=0
for tool in $required_tools; do
    command -v "$tool" >/dev/null 2>&1 && continue
    if [ "$busybox_checked" = 0 ]; then
        busybox_checked=1
        if command -v busybox >/dev/null 2>&1; then
            busybox_applets=$(busybox --list 2>/dev/null) || busybox_applets=
        fi
    fi
    # Match complete applet names. BusyBox existing does not mean an applet was
    # compiled in; never silently replace permission or integrity checks.
    case "
$busybox_applets
" in
        *"
$tool
"*)
            busybox_tools="$busybox_tools $tool"
            # Bootstrap the private workspace without modifying system links.
            # Explicit functions avoid eval of command names or firmware output.
            case "$tool" in
                sha256sum) sha256sum() { busybox sha256sum "$@"; } ;;
                wc) wc() { busybox wc "$@"; } ;;
                mktemp) mktemp() { busybox mktemp "$@"; } ;;
            esac ;;
        *) missing_tools="${missing_tools}${missing_tools:+ }$tool" ;;
    esac
done
[ -z "$missing_tools" ] || fail "缺少校验依赖：$missing_tools" "检查 PATH 或安装上述命令（BusyBox 也未提供对应功能），然后重试；不会跳过校验" 2
if command -v sha256sum >/dev/null 2>&1; then hash_tool=sha256sum
elif command -v shasum >/dev/null 2>&1; then hash_tool=shasum
elif command -v openssl >/dev/null 2>&1; then hash_tool=openssl
else fail '缺少 SHA256 工具' '安装系统 SHA256 工具后重试' 2; fi
hash_file() {
    case "$hash_tool" in
        sha256sum) h=$(sha256sum "$1") || return 1; printf '%s\n' "${h%% *}" ;;
        shasum) h=$(shasum -a 256 "$1") || return 1; printf '%s\n' "${h%% *}" ;;
        openssl) h=$(openssl dgst -sha256 "$1") || return 1; printf '%s\n' "${h##* }" ;;
    esac
}
# No persistent recommendation cache. Old cache overrides are deliberately
# ignored: every invocation fetches a fresh recommendation into a private dir.
# /tmp is a platform trust anchor, not an arbitrary caller-selected directory.
if [ "$asus_entry" = 0 ]; then
    temp_parent=$(CDPATH= cd -P /tmp && pwd -P) || fail '无法访问临时目录' '检查系统 /tmp' 12
    case "$temp_parent" in /tmp|/private/tmp) ;; *) fail '临时目录位置不受支持' '检查系统 /tmp，不要放宽目录权限' 12 ;; esac
    for parent in / ${temp_parent%/tmp} "$temp_parent"; do
        [ -n "$parent" ] || continue
        [ -d "$parent" ] && [ ! -L "$parent" ] || fail '临时目录不安全' '检查系统目录类型' 12
        fields=$(ddnsto_file_fields "$parent") || fail '无法检查临时目录权限' '检查系统 ls/stat 功能；不会跳过权限检查' 12
        field_owner=${fields%% *}; field_rest=${fields#* }; field_mode=${field_rest%% *}
        [ "$field_owner" = 0 ] || fail '临时目录所有者不安全' '检查系统目录所有者' 12
        permissions=$((0$field_mode))
        if [ "$((permissions & 0022))" != 0 ]; then
            [ "$parent" = "$temp_parent" ] && [ "$((permissions & 01000))" != 0 ] ||
                fail '临时目录可被其他用户改写' '检查系统目录权限；不要关闭权限检查' 12
        fi
    done
fi
work=
entry_child=
cleanup() {
    cleanup_rc=$?
    trap - EXIT
    trap '' HUP INT TERM
    # Retain the verified source until the installer has joined
    # its worker/recovery. Only signal our own child, never a global process set.
    if [ -n "$entry_child" ]; then
        kill -TERM "$entry_child" 2>/dev/null || :
        wait "$entry_child" 2>/dev/null || :
        entry_child=
    fi
    [ -z "$work" ] || rm -rf -- "$work"
    exit "$cleanup_rc"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
if [ "$asus_entry" = 1 ]; then
    work=$(ddnsto_asus_mktemp "$ASUS_STATE") || fail '无法创建工作目录' '检查缓存空间' 12
else
    work=$(mktemp -d "$temp_parent/ddnsto-entry.XXXXXXXX") || fail '无法创建工作目录' '检查缓存空间' 12
fi
if [ -n "$busybox_tools" ]; then
    # POSIX functions are not inherited by the installer child. Provide only
    # missing commands in this checked 0700 workspace, retained until child exit.
    mkdir -m 700 "$work/tools" || fail '无法准备兼容命令' '检查私有缓存空间' 12
    for tool in $busybox_tools; do
        printf '#!/bin/sh\nexec busybox %s "$@"\n' "$tool" > "$work/tools/$tool" || fail '无法准备兼容命令' '检查私有缓存空间' 12
        chmod 700 "$work/tools/$tool" || fail '无法保护兼容命令' '检查私有缓存权限' 12
    done
    PATH="$work/tools:$PATH"
    export PATH
fi
# A narrow bootstrap transport, not a zsetup replacement. Do not execute a
# caller-supplied/downloading zsetup just to ask its version. Curl follows at
# most five HTTPS-only redirects; wget safely refuses redirects (see below).
# ulimit bounds even chunked bodies on older curl; max-filesize adds exact limits.
# Recommendation transport policy is independent of executor bootstrap policy.
# Only installer/native bootstrap uses this transport. Products use zsetup.
ddnsto_https_fetch() (
    case "$1" in https://*) ;; *) return 42 ;; esac
    url=$1 destination=$2 limit=$3
    ulimit -c 0 || return 42
    # POSIX shells use 512-byte blocks (some shells use 1024). Bound body AND
    # response diagnostics; final byte count is exact even for chunked bodies.
    ulimit -f "$(((limit + 511) / 512 + 128))" || return 42
    code=0 status=
    if command -v curl >/dev/null 2>&1; then
        status=$(curl -q --silent --proto '=https' --proto-redir '=https' \
            --location --max-redirs 5 \
            --connect-timeout 5 --max-time 20 --max-filesize "$limit" \
            --output "$destination" --write-out '%{http_code}' "$url" 2>/dev/null) || code=$?
        case "$code" in 0) ;; 6|7|28) return 41 ;; *) return 42 ;; esac
        case "$status" in 404|500|502|503|504) return 41 ;; esac
    else
        # --no-config must cover system wgetrc, ~/.wgetrc AND WGETRC. A plain
        # -e check_certificate=on cannot neutralize input/output/redirect config.
        version=$(LC_ALL=C wget --no-config --version 2>/dev/null) || version=
        case "$version" in
            'GNU Wget '*)
                case "$version" in *+https*) ;; *) version= ;; esac ;;
            *) version= ;;
        esac
        if [ -z "$version" ]; then
            printf '%s\n' 'DDNSTO: TLS certificate validation requires curl or GNU Wget with HTTPS and --no-config; BusyBox/uclient wget is unsupported' >&2
            return 42
        fi
        log="$destination.wget-response"
        pid= timer=
        finish_fetch() {
            [ -z "$pid" ] || { kill "$pid" 2>/dev/null || :; wait "$pid" 2>/dev/null || :; }
            [ -z "$timer" ] || { kill "$timer" 2>/dev/null || :; wait "$timer" 2>/dev/null || :; }
            rm -f "$log"
        }
        trap finish_fetch EXIT
        trap 'exit 42' HUP INT TERM
        LC_ALL=C wget --no-config --execute=check_certificate=on \
            --https-only --max-redirect=0 --tries=1 --timeout=5 \
            --no-netrc --no-hsts --no-verbose --server-response \
            -O "$destination" "$url" 2>"$log" &
        pid=$!
        # Wget's timeout is an idle timeout, not a total deadline. Reap both
        # watchdog and sleeper on success, failure, and signal.
        (
            sleeper=
            trap '[ -z "$sleeper" ] || { kill "$sleeper" 2>/dev/null; wait "$sleeper" 2>/dev/null; }; exit 0' HUP INT TERM
            sleep 20 & sleeper=$!
            wait "$sleeper" || exit 0
            kill "$pid" 2>/dev/null || :
        ) </dev/null >/dev/null 2>&1 &
        timer=$!
        wait "$pid" || code=$?
        pid=
        kill "$timer" 2>/dev/null || :
        wait "$timer" 2>/dev/null || :
        timer=
        # C-locale TLS diagnostics only veto fallback; HTTP status is parsed
        # structurally. Never expose response headers/URLs. GNU
        # --server-response emits indented HTTP status lines; headers cannot
        # masquerade as status lines without an HTTP/ prefix.
        set -f
        tls_error=0
        while IFS= read -r line; do
            # Exit 5 already rejects certificate errors below. Exit 4 also
            # covers handshake failures: recognize only GNU's nonindented
            # diagnostics, never TLS words in response headers or URLs.
            if [ "$code" = 4 ]; then
                case "$line" in
                    'Unable to establish SSL connection.'*|'GnuTLS: '*|'OpenSSL: '*) tls_error=1 ;;
                esac
            fi
            set -- $line
            case "${1:-}" in HTTP/*) status=${2:-} ;; esac
        done < "$log"
        [ "$tls_error" = 0 ] || return 42
        # GNU wget --https-only governs recursive link selection, not redirect
        # schemes. Keep max-redirect=0: never contact an HTTP Location, and do
        # not turn a refused redirect into an availability/cache fallback.
        case "$status" in 301|302|303|307|308)
            printf '%s\n' 'DDNSTO：下载地址需要重定向，wget 已安全拒绝；请安装 curl 后重试（最多五次 HTTPS 跳转，不允许降级 HTTP）' >&2
            return 42 ;;
        esac
        case "$code" in 0|8)
            case "$status" in 404|500|502|503|504) return 41 ;; esac ;;
        esac
        case "$status" in ''|200) ;; *) return 42 ;; esac
        case "$code" in 0) ;; 4|143) return 41 ;; *) return 42 ;; esac
    fi
    [ "$status" = 200 ] || return 42
    [ -f "$destination" ] && [ "$(wc -c < "$destination")" -le "$limit" ] || return 42
)

fetch() (
    ddnsto_https_fetch "$@"
)
parse() {
    [ -f "$1" ] && [ ! -L "$1" ] || return 1
    manifest_bytes=$(wc -c < "$1") || return 1
    [ "$manifest_bytes" -le 128 ] || return 1
    {
        IFS= read -r magic && IFS= read -r digest && IFS= read -r size
    } < "$1" || return 1
    [ "$magic" = ddnsto-recommendation-v1-shell ] || return 1
    case "$digest" in ''|*[!0-9a-f]*) return 1 ;; esac
    [ "${#digest}" = 64 ] || return 1
    case "$size" in ''|0*|*[!0-9]*) return 1 ;; esac
    [ "${#size}" -le 7 ] && [ "$size" -le 8388608 ] || return 1
    # Fields are ASCII-only; exact byte length rejects NULs discarded by some
    # shells, extra lines, CRLF and missing final newline without requiring cmp.
    [ "$manifest_bytes" -eq "$((${#magic} + ${#digest} + ${#size} + 3))" ]
}
verify() {
    [ -f "$1" ] && [ ! -L "$1" ] &&
        [ "$(wc -c < "$1")" -eq "$size" ] && [ "$(hash_file "$1")" = "$digest" ]
}
recommend_native=
# @@NATIVE_FIRST@@
rc=0
fetch "$base/recommended-shell.txt" "$work/recommended.txt" 128 || rc=$?
case "$rc" in
    0) parse "$work/recommended.txt" || fail '推荐清单非法' '联系发布者核对清单' 11 ;;
    41) fail '推荐源暂不可用，本入口需要联网' '检查网络后重新运行；也可使用官方手动安装指引' 11 ;;
    *) fail '推荐源响应或 TLS 校验异常' '检查 HTTPS 证书、系统时间和下载工具' 11 ;;
esac
download_rc=0
if [ -n "${recommend_native:-}" ]; then
    ddnsto_recommend_native_download
else
    fetch "$base/immutable/$digest/install.sh" "$work/install.sh" "$size" || download_rc=$?
fi
case "$download_rc" in
    0) verify "$work/install.sh" || fail '安装脚本校验失败' '联系发布者核对摘要和大小' 11 ;;
    41) fail '安装脚本暂不可用' '检查网络后重试；不会执行旧缓存' 11 ;;
    *) fail '安装脚本响应异常' '检查 HTTPS 证书和不可变路径' 11 ;;
esac
verify "$work/install.sh" || fail '执行前校验失败' '重新下载或联系发布者' 11
# Preserve exact argv and executor status. No token, manifest or exception dump.
# Lifecycle success (including stable local service checks) belongs to executor.
result=0
# Async POSIX shells replace fd 0 before applying redirections. Preserve the
# original via a separate descriptor, then close it in both parent and child.
exec 3<&0
sh "$work/install.sh" "$@" <&3 3<&- &
entry_child=$!
exec 3<&-
wait "$entry_child" || result=$?
entry_child=
exit "$result"
