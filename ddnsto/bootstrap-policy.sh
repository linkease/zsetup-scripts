#!/bin/sh
# DDNSTO Linux/OpenWrt only. Embed AFTER lib/bootstrap.sh, only in DDNSTO.
# Call ddnsto_bootstrap_zsetup instead of bootstrap_zsetup at the business
# bootstrap call site. The shared function remains intact; no alias is needed.
# Desktop entrypoints retain their separate 0.3.0 / 0.4.0 policies.

# dl.istoreos.com redirects native downloads (verified 2026-11-09). The
# bootstrap deliberately never follows redirects. Use direct HTTPS mirrors
# only here; preserve shared bootstrap and native product source selection.
if [ -z "${ZSETUP_BOOTSTRAP_BASES:-}" ]; then
    BOOTSTRAP_BASES='https://fw.koolcenter.com/binary https://fw.d4ctech.com/binary https://fw20.koolcenter.com/binary'
fi

fetch_bootstrap_metadata() {
    # Deliberately ignore remote stable and SHA256SUMS, including fixture files.
    # Pins verified against HTTPS fw.koolcenter.com/binary/zsetup/0.5.0/SHA256SUMS.
    RESCUE_VERSION=0.5.0
    EXPECTED_SHA256=
    case "${ZSETUP_ARCH:-}" in
        x86_64) EXPECTED_SHA256=9563b8442a75957792bb82a2d98a736142fc52be57dd2dc42005490096897617 ;;
        aarch64) EXPECTED_SHA256=70cc54fcfdc6c6516965485879f0929e7dc9aabc1bd0fe09cbab099dd4619020 ;;
        armv7) EXPECTED_SHA256=16eca14c00167ef45dac13e536c5ef2880f682ec48c70661044ee453724a66aa ;;
        mipsel) EXPECTED_SHA256=4821bbeae11fdcdfa9eb5e0b46b63e9751e069c21b1e0e598c5658eb73383a7b ;;
        *) printf '%s\n' 'DDNSTO: no fixed zsetup release for this architecture' >&2; return 2 ;;
    esac
}

confirm_insecure_http() {
    # Always called inside the wrapper's subprocess. Exit also fails closed
    # when a caller uses the wrapper in an if/|| context (POSIX disables -e).
    printf '%s\n' 'DDNSTO: HTTPS bootstrap failed; HTTP bootstrap is disabled' >&2
    exit 1
}

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

bootstrap_fetch_from_base() (
    # DDNSTO-only transport policy; retain the shared mirror/download lifecycle
    # and URL construction. A valid pin does not authorize HTTP transport.
    [ "$1" = https ] || return 42
    case "$2" in https://*) ;; *) return 42 ;; esac
    url=$(bootstrap_url "$1" "$2" "$3") || return 42
    rm -f "$4" || return 42
    ddnsto_https_fetch "$url" "$4" 16777216
)

# Override only DDNSTO's mirror loop: security failures never try another source.
bootstrap_fetch() {
    for fetch_base in $BOOTSTRAP_BASES; do
        fetch_code=0
        bootstrap_fetch_from_base "$1" "$fetch_base" "$2" "$3" || fetch_code=$?
        case "$fetch_code" in 0) return 0 ;; 41) ;; *) return "$fetch_code" ;; esac
    done
    return 41
}

ddnsto_bootstrap_safe_ancestors() (
    # Validate before creating anything. Symlink components, dot components,
    # untrusted owners and writable ancestors can redirect a privileged cache.
    case "$1" in /*) ;; *) return 1 ;; esac
    case "$1/" in *//*|*/./*|*/../*) [ "$1" = / ] || return 1 ;; esac
    directory=$1
    while :; do
        [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
        owner=$(stat -c %u "$directory") || return 1
        mode=$(stat -c %a "$directory") || return 1
        [ "$owner" = 0 ] || [ "$owner" = "$(id -u)" ] || return 1
        # A root-owned sticky /tmp is safe for an owned, private child.
        if [ "$((0$mode & 0022))" -ne 0 ]; then
            [ "$owner" = 0 ] && [ "$((0$mode & 01000))" -ne 0 ] || return 1
        fi
        [ "$directory" != / ] || break
        directory=${directory%/*}
        [ -n "$directory" ] || directory=/
    done
)

ddnsto_bootstrap_private_dir() (
    [ ! -L "$1" ] || return 1
    if [ ! -e "$1" ]; then
        (umask 077; mkdir "$1") || return 1
    fi
    [ -d "$1" ] && [ "$(stat -c %u "$1")" = "$(id -u)" ] &&
        [ "$(stat -c %a "$1")" = 700 ]
)

is_expected_zsetup() (
    # Never use --version to establish trust. Even a cached or explicit native
    # must have reviewed bytes before its first instruction executes.
    [ -f "$1" ] && [ ! -L "$1" ] && [ -x "$1" ] || return 1
    [ -n "${EXPECTED_SHA256:-}" ] && have_hash_tool || return 1
    case "$1" in /*) ;; *) return 1 ;; esac
    ddnsto_bootstrap_safe_ancestors "${1%/*}" || return 1
    owner=$(stat -c %u "$1") || return 1
    mode=$(stat -c %a "$1") || return 1
    [ "$owner" = 0 ] || [ "$owner" = "$(id -u)" ] || return 1
    [ "$((0$mode & 0022))" -eq 0 ] || return 1
    [ "$(stat -c %h "$1")" = 1 ] || return 1
    hash_matches "$1" || return 1
    [ "$("$1" --version 2>/dev/null)" = "zsetup $RESCUE_VERSION" ]
)

ddnsto_bootstrap_zsetup() {
    ACTIVE_ZSETUP=
    bootstrap_arch || return $?
    fetch_bootstrap_metadata https '' '' || return $?
    have_hash_tool || {
        printf '%s\n' 'DDNSTO: SHA-256 verification requires sha256sum or openssl' >&2
        return 1
    }
    # Use the existing override; no host services or global installation paths.
    # Do not chmod/chown an existing cache to "repair" someone else's directory.
    ACTIVE_ZSETUP=$(
        umask 077
        case "$WORK_ROOT" in /*) ;; *) exit 1 ;; esac
        case "$WORK_ROOT/" in *//*|*/./*|*/../*) exit 1 ;; esac
        ddnsto_bootstrap_safe_ancestors "${WORK_ROOT%/*}" &&
            ddnsto_bootstrap_private_dir "$WORK_ROOT" || {
            printf '%s\n' 'DDNSTO: bootstrap cache must be owned, private and free of symlinks' >&2
            exit 1
        }
        # Serialize cache publication; never remove or steal an existing lock.
        lock="$WORK_ROOT/.ddnsto-bootstrap-lock"
        mkdir "$lock" 2>/dev/null || {
            printf '%s\n' 'DDNSTO: bootstrap cache is locked' >&2
            exit 16
        }
        trap 'rmdir "$lock" 2>/dev/null || true' EXIT
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM
        for directory in "$WORK_ROOT/bootstrap" "$WORK_ROOT/rescue" "$WORK_ROOT/rescue/$RESCUE_VERSION"; do
            ddnsto_bootstrap_private_dir "$directory" || {
                printf '%s\n' 'DDNSTO: unsafe bootstrap cache directory' >&2
                exit 1
            }
        done
        # Shared helper uses PID-specific temporary names. Refuse stale or
        # redirected entries before its cleanup traps can touch those paths.
        for temporary in "$WORK_ROOT/bootstrap/.stable.$$" "$WORK_ROOT/bootstrap/.SHA256SUMS.$$" \
            "$WORK_ROOT/rescue/$RESCUE_VERSION/.zsetup-download.$$"; do
            [ ! -e "$temporary" ] && [ ! -L "$temporary" ] || exit 1
        done
        [ ! -L "$WORK_ROOT/rescue/$RESCUE_VERSION/zsetup" ] || exit 1
        if [ -e "$WORK_ROOT/rescue/$RESCUE_VERSION/zsetup" ]; then
            [ -f "$WORK_ROOT/rescue/$RESCUE_VERSION/zsetup" ] || exit 1
        fi
        # Inner scope preserves the lock cleanup when shared bootstrap installs
        # and removes its own traps. Only the verified path crosses back out.
        (
            candidate=
            bootstrap_zsetup || exit $?
            # Shared code assumes errexit for mv/chmod. Revalidate publication
            # explicitly because conditional callers disable that assumption.
            is_expected_zsetup "$ACTIVE_ZSETUP" || {
                [ -z "$candidate" ] || rm -f "$candidate"
                exit 1
            }
            printf '%s\n' "$ACTIVE_ZSETUP"
        )
    ) || return $?
    [ -n "$ACTIVE_ZSETUP" ]
}
