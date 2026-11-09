#!/bin/sh
# Stable template. Package locally; do not source this file or pipe a manifest
# into a shell. Only the immutable, size+SHA verified installer is executed.
set +x
set -eu
umask 077
base='@@SOURCE_URL@@'
cache_key='@@CACHE_KEY@@'
fail() { printf 'DDNSTO：%s；状态=推荐入口未执行安装；下一步=%s；code=%s\n' "$1" "$2" "$3" >&2; exit "$3"; }
case "$(uname -s)" in Linux|Darwin) ;; *) fail '不支持此系统' '使用对应平台入口' 2 ;; esac
case "$base" in https://*) ;; *) fail '入口尚未打包' '使用已审核的发布入口' 2 ;; esac
for tool in stat wc cmp mktemp; do
    command -v "$tool" >/dev/null 2>&1 || fail '缺少校验依赖' '安装系统文件校验工具' 2
done
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
uid=$(id -u)
stat_fields() {
    if [ "$(uname -s)" = Darwin ]; then stat -f '%u %Lp %l' "$1"
    else stat -c '%u %a %h' "$1"; fi
}
# Validate every ancestor before creating anything. Root-owned sticky ancestors
# (e.g. /tmp) are allowed; cache itself must belong to this user, mode 0700.
safe_ancestors() (
    p=$1
    while :; do
        [ ! -L "$p" ] && [ -d "$p" ] || return 1
        fields=$(stat_fields "$p") || return 1
        set -- $fields
        [ "$#" = 3 ] || return 1
        [ "$1" = "$uid" ] || [ "$1" = 0 ] || return 1
        perm=$((0$2))
        if [ "$((perm & 0022))" != 0 ]; then
            [ "$1" = 0 ] && [ "$((perm & 01000))" != 0 ] || return 1
        fi
        [ "$p" != / ] || break
        p=${p%/*}; [ -n "$p" ] || p=/
    done
)
private_dir() {
    [ ! -L "$1" ] && [ -d "$1" ] || return 1
    [ "$(stat_fields "$1")" = "$uid 700 2" ] && return 0
    fields=$(stat_fields "$1") || return 1
    set -- $fields
    [ "$1" = "$uid" ] && [ "$2" = 700 ]
}
safe_file() {
    [ ! -L "$1" ] && [ -f "$1" ] || return 1
    fields=$(stat_fields "$1") || return 1
    set -- $fields
    [ "$1" = "$uid" ] && [ "$3" = 1 ] && [ "$((0$2 & 0077))" = 0 ]
}
cache_root=${DDNSTO_RECOMMEND_CACHE:-${HOME:?}/.ddnsto-recommendation}
case "$cache_root" in /*) ;; *) fail '缓存路径无效' '使用绝对私有目录' 12 ;; esac
# Reject ambiguous path components; paths are never interpreted as shell code.
case "$cache_root/" in *'/../'*|*'/./'*|*'//'*) fail '缓存路径无效' '使用规范私有目录' 12 ;; esac
parent=${cache_root%/*}; [ -n "$parent" ] || parent=/
safe_ancestors "$parent" || fail '缓存父目录不安全' '检查目录所有者及权限' 12
if [ ! -e "$cache_root" ] && [ ! -L "$cache_root" ]; then mkdir -m 700 "$cache_root" 2>/dev/null || fail '无法创建缓存' '检查目录权限' 12; fi
private_dir "$cache_root" || fail '缓存目录不安全' '使用本人所有的 0700 目录' 12
cache="$cache_root/$cache_key"
if [ ! -e "$cache" ] && [ ! -L "$cache" ]; then mkdir -m 700 "$cache" 2>/dev/null || fail '无法创建缓存' '检查目录权限' 12; fi
private_dir "$cache" || fail '缓存目录不安全' '检查目录所有者及权限' 12
mkdir "$cache/lock" 2>/dev/null || fail '推荐缓存被占用' '等待其他安装完成；异常中断后检查 lock' 12
work=
cleanup() {
    [ -z "$work" ] || rm -rf -- "$work"
    rmdir "$cache/lock" 2>/dev/null || :
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
work=$(mktemp -d "$cache/attempt.XXXXXXXX") || fail '无法创建工作目录' '检查缓存空间' 12
# A narrow bootstrap transport, not a zsetup replacement. Do not execute a
# caller-supplied/downloading zsetup just to ask its version. Reject ALL redirects.
# ulimit bounds even chunked bodies on older curl; max-filesize adds exact limits.
# Kept identical in the three standalone DDNSTO bootstrap sources; tested together.
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
    safe_file "$1" || return 1
    [ "$(wc -c < "$1")" -le 128 ] || return 1
    {
        IFS= read -r magic && IFS= read -r digest && IFS= read -r size
    } < "$1" || return 1
    [ "$magic" = ddnsto-recommendation-v1-shell ] || return 1
    case "$digest" in ''|*[!0-9a-f]*) return 1 ;; esac
    [ "${#digest}" = 64 ] || return 1
    case "$size" in ''|0*|*[!0-9]*) return 1 ;; esac
    [ "${#size}" -le 7 ] && [ "$size" -le 8388608 ] || return 1
    printf '%s\n' "$magic" "$digest" "$size" > "$work/canonical.txt"
    cmp -s "$1" "$work/canonical.txt"
}
verify() {
    safe_file "$1" && [ "$(wc -c < "$1")" -eq "$size" ] && [ "$(hash_file "$1")" = "$digest" ]
}
offline() { printf '%s\n' 'DDNSTO：推荐源暂不可用；状态=离线使用已校验缓存（可能非最新）；下一步=联网后重试；code=0' >&2; }
rc=0
fetch "$base/recommended-shell.txt" "$work/recommended.txt" 128 || rc=$?
case "$rc" in
    0) parse "$work/recommended.txt" || fail '推荐清单非法' '联系发布者核对清单' 11 ;;
    41)
        parse "$cache/recommended.txt" || fail '推荐源不可用且无完整缓存' '检查网络后重试' 11
        verify "$cache/$digest.sh" || fail '离线脚本缺失或校验失败' '联网重新取得完整推荐' 11
        cp "$cache/recommended.txt" "$work/recommended.txt"
        cp "$cache/$digest.sh" "$work/install.sh"
        offline ;;
    *) fail '推荐源响应或 TLS 校验异常' '检查 HTTPS 证书和发布路径' 11 ;;
esac
if [ "$rc" = 0 ]; then
    download_rc=0
    fetch "$base/immutable/$digest/install.sh" "$work/install.sh" "$size" || download_rc=$?
    case "$download_rc" in
        0) verify "$work/install.sh" || fail '安装脚本校验失败' '联系发布者核对摘要和大小' 11 ;;
        41)
            verify "$cache/$digest.sh" || fail '安装脚本不可用且无匹配缓存' '检查网络后重试' 11
            cp "$cache/$digest.sh" "$work/install.sh"
            offline ;;
        *) fail '安装脚本响应异常' '检查 HTTPS 证书和不可变路径' 11 ;;
    esac
fi
verify "$work/install.sh" || fail '执行前校验失败' '检查缓存完整性' 11
# Commit the complete pair under the lock. A crash before metadata replacement
# leaves the previous complete pair; every reuse rehashes the script bytes.
cp "$work/install.sh" "$work/cached.sh"
mv -f "$work/cached.sh" "$cache/$digest.sh"
mv -f "$work/recommended.txt" "$cache/recommended.txt"
# Preserve exact argv and executor status. No token, manifest or exception dump.
# Lifecycle success (including stable local service checks) belongs to executor.
result=0
sh "$work/install.sh" "$@" || result=$?
exit "$result"
