#!/bin/sh
if [ "$(uname -s)" = Darwin ]; then
(
#!/bin/sh
# Engineering candidate: bootstraps zsetup automatically; native canary pending.
set -eu
umask 077
VERSION=${DDNSTO_VERSION:-4.2.1}
INSTALL_DIR=${DDNSTO_INSTALL_DIR:-$HOME/.local/bin}
CONFIG_DIR=${DDNSTO_CONFIG_DIR:-$HOME/Library/Application Support/DDNSTO}
AGENTS_DIR=${DDNSTO_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}
LABEL=com.ddnsto.client
TOKEN=
TOKEN_FILE=
fail() { printf 'DDNSTO: %s\n' "$1" >&2; exit "${2:-2}"; }
while [ "$#" -gt 0 ]; do
    case "$1" in
        --token|--token-file|--version)
            [ "$#" -ge 2 ] || fail 'argument requires a value'
            case "$1" in --token) TOKEN=$2 ;; --token-file) TOKEN_FILE=$2 ;; *) VERSION=$2 ;; esac
            shift 2 ;;
        --token=*) TOKEN=${1#--token=}; shift ;;
        --help|-h) printf '%s\n' 'Usage: install-macos.sh [--token TOKEN | --token-file FILE] [--version 4.2.1]' 'Updates preserve existing configuration when token is omitted.'; exit 0 ;;
        *) fail 'unknown argument' ;;
    esac
done
[ "$(uname -s)" = Darwin ] || fail 'this installer requires macOS'
case "$(uname -m)" in x86_64|amd64) member=ddnsto_cli.amd64 ;; arm64|aarch64) member=ddnsto_cli.arm64 ;; *) fail 'unsupported macOS architecture' ;; esac
[ "$VERSION" = 4.2.1 ] || fail 'no pinned artifact for requested version'
archive_sha=46aad0f28da7ad67175cfed1bc973b1eea68bed4242c8779d8cbd1ba57ed31d7
ZSETUP_BIN=${ZSETUP_BIN:-}
for tool in launchctl tar sed grep; do command -v "$tool" >/dev/null || fail "missing dependency: $tool"; done
for directory in "$INSTALL_DIR" "$CONFIG_DIR" "$AGENTS_DIR"; do
    case "$directory" in /*) ;; *) fail 'installation paths must be absolute' ;; esac
    [ ! -L "$directory" ] || fail 'installation directories must not be symlinks'
done
config="$CONFIG_DIR/ddnsto.yaml"
binary="$INSTALL_DIR/ddnsto"
plist="$AGENTS_DIR/$LABEL.plist"
marker="$CONFIG_DIR/.installer-macos-v1"
for file in "$config" "$binary" "$plist" "$marker"; do [ ! -L "$file" ] || fail 'managed files must not be symlinks'; done
if [ -e "$binary" ] || [ -e "$config" ] || [ -e "$plist" ]; then
    [ -f "$marker" ] && [ -f "$binary" ] && [ -f "$config" ] && [ -f "$plist" ] || fail 'existing unmanaged or incomplete installation; migrate it before retrying'
fi
if [ -n "$TOKEN_FILE" ]; then
    [ -z "$TOKEN" ] || fail 'choose either token or token-file'
    [ -f "$TOKEN_FILE" ] && [ ! -L "$TOKEN_FILE" ] || fail 'token file must be regular'
    TOKEN=$(cat "$TOKEN_FILE"; printf '.')
    TOKEN=${TOKEN%.}
    TOKEN=${TOKEN%"
"}
fi
read_token() (
    [ -t 0 ] || exit 2
    exec 3<>/dev/tty
    terminal_state=$(stty -g <&3)
    trap 'stty "$terminal_state" <&3; printf "\n" >&3' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    stty echo <&3
    printf 'DDNSTO token: ' >&3
    IFS= read -r entered_token <&3
    printf '%s' "$entered_token"
)
if [ -z "$TOKEN" ] && [ ! -f "$config" ] && [ -z "$TOKEN_FILE" ]; then
    TOKEN=$(read_token) || fail 'token required: use an interactive terminal or --token-file FILE'
fi
case "$TOKEN" in *"
"*|*"$(printf '\r')"*) fail 'token must be one line' ;; esac
yaml_token=$(printf '%s' "$TOKEN" | sed "s/'/''/g")
token_line="userToken: '$yaml_token'"
if [ -f "$config" ]; then
    [ -z "$TOKEN" ] || grep -F -x -q -- "$token_line" "$config" || fail 'existing token differs; edit configuration explicitly before reinstalling'
else
    [ -n "$TOKEN" ] || fail 'token is required on first installation'
fi
uid=$(id -u)
domain="gui/$uid"
work=$(mktemp -d "${TMPDIR:-/tmp}/ddnsto.XXXXXX")
changed=0
had_old=0
was_running=0
was_disabled=0
restore_disabled=0
candidate=
locked=0
cleanup() {
    code=$?
    trap - EXIT HUP INT TERM
    recovery_failed=0
    if [ "$changed" = 1 ]; then
        launchctl bootout "$domain/$LABEL" >/dev/null 2>&1 || true
        if [ "$had_old" = 1 ]; then
            cp -p "$work/old-binary" "$binary" || recovery_failed=1
            cp -p "$work/old-config" "$config" || recovery_failed=1
            cp -p "$work/old-plist" "$plist" || recovery_failed=1
            if [ "$was_running" = 1 ]; then launchctl bootstrap "$domain" "$plist" >&2 || recovery_failed=1; fi
        else
            rm -f "$binary" "$config" "$plist" "$marker" || recovery_failed=1
        fi
        printf '%s\n' 'DDNSTO: installation failed; recovery attempted' >&2
    fi
    # Also restore the override if enable itself failed before any file/job change.
    if [ "$code" != 0 ] && [ "$restore_disabled" = 1 ]; then
        launchctl disable "$domain/$LABEL" >&2 || recovery_failed=1
    fi
    [ -z "$candidate" ] || rm -f "$candidate"
    [ "$locked" = 0 ] || rmdir "$CONFIG_DIR/.install-lock"
    if [ "$recovery_failed" = 1 ]; then
        printf 'DDNSTO: recovery incomplete; backup retained at %s\n' "$work" >&2
        exit 1
    fi
    rm -rf "$work"
    exit "$code"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
ensure_zsetup() {
    if [ -n "$ZSETUP_BIN" ]; then
        [ -x "$ZSETUP_BIN" ] && [ "$("$ZSETUP_BIN" --version)" = 'zsetup 0.3.0' ] || fail 'explicit zsetup must be executable version 0.3.0'
        return
    fi
    command -v curl >/dev/null || fail 'curl is required for initial bootstrap'
    command -v shasum >/dev/null || fail 'shasum is required for initial bootstrap verification'
    case "$member" in
        ddnsto_cli.amd64) native=zsetup-macos-x86_64; native_sha=608323145bcd8f083c0845b4bd0481eabccf0d74b99aa2aa6a88e59b34ce5b31 ;;
        *) native=zsetup-macos-aarch64; native_sha=06ec453f851bd0395cf9ea8539de168f80a9628d1a25597dd598c85f9dc633b0 ;;
    esac
    printf '%s\n' 'DDNSTO: downloading and verifying zsetup 0.3.0...' >&2
    for base in https://dl.istoreos.com/binary https://fw.d4ctech.com/binary https://fw20.koolcenter.com/binary https://fw.koolcenter.com/binary; do
        if curl -fLsS --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 120 \
            -o "$work/zsetup.part" "$base/zsetup/0.3.0/$native"; then
            actual=$(shasum -a 256 "$work/zsetup.part")
            if [ "${actual%% *}" = "$native_sha" ]; then
                mv "$work/zsetup.part" "$work/zsetup"
                chmod 700 "$work/zsetup"
                ZSETUP_BIN="$work/zsetup"
                [ "$("$ZSETUP_BIN" --version)" = 'zsetup 0.3.0' ] || fail 'unexpected zsetup version'
                return
            fi
        fi
    done
    fail 'zsetup bootstrap download/checksum failed; no client changes made' 11
}
printf 'DDNSTO: selected client version %s (pinned by this installer; latest release not checked).\n' "$VERSION" >&2
ensure_zsetup
"$ZSETUP_BIN" download -o "$work/client.tar.gz" --sha256 "$archive_sha" \
    "https://fw.koolcenter.com/binary/ddnsto/macOS/ddnsto_darwin_cli_${VERSION}.tar.gz"
tar -xzf "$work/client.tar.gz" -C "$work" "$member"
[ -f "$work/$member" ] && [ ! -L "$work/$member" ] || fail 'missing regular client binary' 11
mkdir -p "$CONFIG_DIR" "$INSTALL_DIR" "$AGENTS_DIR"
chmod 700 "$CONFIG_DIR"
mkdir "$CONFIG_DIR/.install-lock" 2>/dev/null || fail 'another installation is active'
locked=1
# Revalidate ownership after locking; another installer may have just finished.
for file in "$config" "$binary" "$plist" "$marker"; do [ ! -L "$file" ] || fail 'managed files must not be symlinks'; done
if [ -e "$binary" ] || [ -e "$config" ] || [ -e "$plist" ] || [ -e "$marker" ]; then
    [ -f "$marker" ] && [ -f "$binary" ] && [ -f "$config" ] && [ -f "$plist" ] || fail 'existing unmanaged or incomplete installation'
    [ -z "$TOKEN" ] || grep -F -x -q -- "$token_line" "$config" || fail 'existing token differs'
elif launchctl print "$domain/$LABEL" >/dev/null 2>&1; then
    fail 'existing unmanaged launchd job; migrate it before retrying'
else
    [ -n "$TOKEN" ] || fail 'token is required on first installation'
fi
if [ -f "$binary" ]; then
    cp -p "$binary" "$work/old-binary"
    cp -p "$config" "$work/old-config"
    cp -p "$plist" "$work/old-plist"
    had_old=1
    if launchctl print "$domain/$LABEL" >/dev/null 2>&1; then was_running=1; fi
fi
# Disabled overrides survive bootout and removal of the plist. Read them before
# changing files/services; macOS reports either "disabled" or "true".
launchctl print-disabled "$domain" > "$work/disabled-status" || fail 'cannot inspect launchd disabled state; no client changes made'
if grep -E -q '^[[:space:]]*"com\.ddnsto\.client"[[:space:]]*=>[[:space:]]*(disabled|true)[[:space:]]*[;,]?[[:space:]]*$' "$work/disabled-status"; then
    was_disabled=1
fi
xml() { printf '%s' "$1" | sed 's/\&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }
if [ "$had_old" = 0 ]; then
    printf '%s\n' "$token_line" > "$work/config"
    printf "logPath: '%s'\n" "$(printf '%s' "$CONFIG_DIR/logs" | sed "s/'/''/g")" >> "$work/config"
fi
cat > "$work/plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>$(xml "$binary")</string><string>--config</string><string>$(xml "$config")</string></array>
<key>WorkingDirectory</key><string>$(xml "$CONFIG_DIR")</string>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>StandardOutPath</key><string>$(xml "$CONFIG_DIR/stdout.log")</string>
<key>StandardErrorPath</key><string>$(xml "$CONFIG_DIR/stderr.log")</string>
</dict></plist>
EOF
candidate=$(mktemp "$INSTALL_DIR/.ddnsto.XXXXXX")
cp "$work/$member" "$candidate"
chmod 755 "$candidate"
if [ "$was_disabled" = 1 ]; then
    printf '%s\n' 'DDNSTO: re-enabling the disabled user service for installation.' >&2
    restore_disabled=1
    launchctl enable "$domain/$LABEL"
fi
changed=1
if [ "$was_running" = 1 ]; then launchctl bootout "$domain/$LABEL"; fi
mv -f "$candidate" "$binary"
candidate=
if [ "$had_old" = 0 ]; then cp "$work/config" "$config"; fi
chmod 600 "$config"
cp "$work/plist" "$plist"
launchctl bootstrap "$domain" "$plist"
launchctl kickstart -k "$domain/$LABEL"
sleep 1
launchctl print "$domain/$LABEL" > "$work/service-status"
grep -E -q 'pid = [1-9][0-9]*' "$work/service-status" || fail 'launchd job has no running process' 1
printf '%s\n' 'ddnsto-macos-v1' > "$marker"
changed=0
printf '%s\n' "DDNSTO $VERSION: local_service=running cloud_status=unverified" \
    'Runs after user login. Confirm device online in the DDNSTO console: https://www.ddnsto.com/'
)
exit "$?"
fi

#!/bin/sh
set -eu

WORK_ROOT=${ZSETUP_ROOT:-/tmp/zsetup}
DEFAULT_PRIMARY_BASES="https://dl.istoreos.com/binary https://fw.d4ctech.com/binary https://fw20.koolcenter.com/binary"
DEFAULT_FALLBACK_BASE="https://fw.koolcenter.com/binary"
if [ -n "${ZSETUP_BOOTSTRAP_BASES:-}" ]; then
    BOOTSTRAP_BASES=$ZSETUP_BOOTSTRAP_BASES
    DIRECT_PRIMARY_BASES=$ZSETUP_BOOTSTRAP_BASES
    DIRECT_FALLBACK_BASE=
else
    BOOTSTRAP_BASES="$DEFAULT_PRIMARY_BASES $DEFAULT_FALLBACK_BASE"
    DIRECT_PRIMARY_BASES=$DEFAULT_PRIMARY_BASES
    DIRECT_FALLBACK_BASE=$DEFAULT_FALLBACK_BASE
fi
INSECURE_CONFIRMED=0

status() {
    printf '%s\n' "$*" >&2
}

bootstrap_mips_byte_order() {
    command -v od >/dev/null 2>&1 || return 1
    set -- $(od -An -tu1 -N6 /bin/sh 2>/dev/null)
    [ "$#" -eq 6 ] && [ "$1" = 127 ] && [ "$2" = 69 ] && [ "$3" = 76 ] && [ "$4" = 70 ] && [ "$6" = 1 ]
}

bootstrap_arch() {
    case "$(uname -m 2>/dev/null || true)" in
        x86_64|amd64) ZSETUP_ARCH=x86_64 ;;
        aarch64|arm64) ZSETUP_ARCH=aarch64 ;;
        armv7l|armv7) ZSETUP_ARCH=armv7 ;;
        mipsel|mipsle) ZSETUP_ARCH=mipsel ;;
        mips)
            # uname alone does not identify byte order. ELF EI_DATA=1 is little endian.
            bootstrap_mips_byte_order || { echo "zsetup: MIPS byte order is unsupported or unknown" >&2; return 2; }
            ZSETUP_ARCH=mipsel ;;
        *) echo "zsetup: unsupported architecture" >&2; return 2 ;;
    esac
    ZSETUP_ARTIFACT="zsetup-linux-$ZSETUP_ARCH"
}

bootstrap_url() {
    scheme=$1
    base=$2
    path=$3
    authority_path=${base#*://}
    printf '%s://%s/%s\n' "$scheme" "${authority_path%/}" "$path"
}

bootstrap_fetch_from_base() {
    scheme=$1
    base=$2
    remote_path=$3
    destination=$4
    found=0
    url=$(bootstrap_url "$scheme" "$base" "$remote_path")
    if command -v curl >/dev/null 2>&1; then
        found=1
        rm -f "$destination" 2>/dev/null || true
        if curl -fsSL --connect-timeout 10 --max-time 30 -o "$destination" "$url"; then
            return 0
        fi
    fi
    if command -v wget >/dev/null 2>&1; then
        found=1
        rm -f "$destination" 2>/dev/null || true
        if wget -q -T 10 -O "$destination" "$url"; then
            return 0
        fi
    fi
    [ "$found" -eq 1 ] || echo "zsetup: curl or wget is required for first bootstrap" >&2
    return 1
}

bootstrap_fetch() {
    scheme=$1
    remote_path=$2
    destination=$3
    for base in $BOOTSTRAP_BASES; do
        if bootstrap_fetch_from_base "$scheme" "$base" "$remote_path" "$destination"; then
            return 0
        fi
    done
    return 1
}

confirm_insecure_http() {
    [ "$INSECURE_CONFIRMED" -eq 0 ] || return 0
    echo "zsetup: all HTTPS bootstrap sources failed." >&2
    echo "WARNING: HTTP can be intercepted; both zsetup and checksum metadata may be replaced." >&2
    printf 'Continue with insecure HTTP bootstrap? [y/N] ' >&2
    confirm_file=${ZSETUP_CONFIRM_FILE:-/dev/tty}
    answer=
    if ! IFS= read -r answer < "$confirm_file"; then
        echo >&2
        echo "zsetup: HTTP bootstrap refused because no interactive confirmation is available" >&2
        return 1
    fi
    case "$answer" in
        y|Y|yes|YES) INSECURE_CONFIRMED=1; echo "zsetup: user accepted insecure HTTP bootstrap" >&2 ;;
        *) echo "zsetup: insecure HTTP bootstrap declined" >&2; return 1 ;;
    esac
}

read_stable_version() {
    file=$1
    IFS= read -r RESCUE_VERSION < "$file" || return 1
    case "$RESCUE_VERSION" in
        ''|*[!0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._+-]*) return 1 ;;
    esac
    [ -n "$RESCUE_VERSION" ] && [ "${#RESCUE_VERSION}" -le 64 ] || return 1
    compatibility_version=${RESCUE_VERSION%%[-+]*}
    compatibility_major=${compatibility_version%%.*}
    compatibility_rest=${compatibility_version#*.}
    compatibility_minor=${compatibility_rest%%.*}
    compatibility_patch=${compatibility_rest#*.}
    case "$compatibility_major:$compatibility_minor:$compatibility_patch" in *[!0123456789:]*|::*|*::*) return 1 ;; esac
    if [ "$compatibility_major" -eq 0 ]; then
        [ "$compatibility_minor" -ge 2 ] || return 1
        if [ "$compatibility_minor" -eq 2 ]; then [ "$compatibility_patch" -ge 4 ] || return 1; fi
    fi
}

read_expected_sha256() {
    file=$1
    EXPECTED_SHA256=
    while IFS=' ' read -r digest name remainder; do
        name=${name#\*}
        if [ "$name" = "$ZSETUP_ARTIFACT" ] && [ -z "${remainder:-}" ]; then
            EXPECTED_SHA256=$digest
            break
        fi
    done < "$file"
    [ "${#EXPECTED_SHA256}" -eq 64 ] || return 1
    case "$EXPECTED_SHA256" in *[!0123456789abcdefABCDEF]*) return 1 ;; esac
}

have_hash_tool() {
    command -v sha256sum >/dev/null 2>&1 || command -v openssl >/dev/null 2>&1
}

hash_matches() {
    [ -f "$1" ] || return 1
    if [ -z "${EXPECTED_SHA256:-}" ]; then
        echo "zsetup: bootstrap SHA-256 verification skipped; HTTPS transport remains required" >&2
        return 0
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "$1")
        actual=${actual%% *}
    elif command -v openssl >/dev/null 2>&1; then
        actual=$(openssl dgst -sha256 "$1")
        actual=${actual##*= }
    else
        echo "zsetup: bootstrap SHA-256 tool disappeared before verification" >&2
        return 1
    fi
    [ "$actual" = "$EXPECTED_SHA256" ]
}

is_expected_zsetup() {
    [ -x "$1" ] && [ "$("$1" --version 2>/dev/null || true)" = "zsetup $RESCUE_VERSION" ]
}

find_existing_zsetup() {
    if [ -n "${ZSETUP_BIN:-}" ] && is_expected_zsetup "$ZSETUP_BIN"; then
        ACTIVE_ZSETUP=$ZSETUP_BIN
        return 0
    fi
    if is_expected_zsetup "$WORK_ROOT/rescue/$RESCUE_VERSION/zsetup"; then
        ACTIVE_ZSETUP="$WORK_ROOT/rescue/$RESCUE_VERSION/zsetup"
        return 0
    fi
    if command -v zsetup >/dev/null 2>&1; then
        system_zsetup=$(command -v zsetup)
        if is_expected_zsetup "$system_zsetup"; then
            ACTIVE_ZSETUP=$system_zsetup
            return 0
        fi
    fi
    return 1
}

fetch_bootstrap_metadata() {
    scheme=$1
    stable_file=$2
    sums_file=$3
    for base in $BOOTSTRAP_BASES; do
        bootstrap_fetch_from_base "$scheme" "$base" zsetup/stable "$stable_file" || continue
        read_stable_version "$stable_file" || continue
        EXPECTED_SHA256=
        if have_hash_tool && bootstrap_fetch_from_base "$scheme" "$base" "zsetup/$RESCUE_VERSION/SHA256SUMS" "$sums_file"; then
            read_expected_sha256 "$sums_file" || EXPECTED_SHA256=
        fi
        return 0
    done
    echo "zsetup: no source returned valid stable metadata over $scheme" >&2
    return 1
}

bootstrap_zsetup() {
    bootstrap_arch
    state_dir="$WORK_ROOT/bootstrap"
    mkdir -p "$state_dir"
    stable_file="$state_dir/.stable.$$"
    sums_file="$state_dir/.SHA256SUMS.$$"
    trap 'rm -f "$stable_file" "$sums_file" "${candidate:-}" 2>/dev/null || true' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    metadata_scheme=https
    if ! fetch_bootstrap_metadata https "$stable_file" "$sums_file"; then
        confirm_insecure_http
        metadata_scheme=http
        fetch_bootstrap_metadata http "$stable_file" "$sums_file"
    fi

    if find_existing_zsetup; then
        trap - EXIT HUP INT TERM
        rm -f "$stable_file" "$sums_file" 2>/dev/null || true
        return 0
    fi

    rescue_dir="$WORK_ROOT/rescue/$RESCUE_VERSION"
    rescue_bin="$rescue_dir/zsetup"
    candidate="$rescue_dir/.zsetup-download.$$"
    mkdir -p "$rescue_dir"
    if ! bootstrap_fetch https "zsetup/$RESCUE_VERSION/$ZSETUP_ARTIFACT" "$candidate"; then
        confirm_insecure_http
        bootstrap_fetch http "zsetup/$RESCUE_VERSION/$ZSETUP_ARTIFACT" "$candidate"
    fi
    hash_matches "$candidate" || {
        echo "zsetup: bootstrap checksum mismatch" >&2
        return 1
    }
    chmod 0755 "$candidate"
    is_expected_zsetup "$candidate" || {
        echo "zsetup: downloaded bootstrap has the wrong product or version" >&2
        return 1
    }
    mv -f "$candidate" "$rescue_bin"
    ACTIVE_ZSETUP=$rescue_bin
    trap - EXIT HUP INT TERM
    rm -f "$stable_file" "$sums_file" 2>/dev/null || true
    [ "$metadata_scheme" = https ] || echo "zsetup: insecure HTTP bootstrap completed with user consent" >&2
}


# Business logic: maintained in ddnsto/business.sh
# Included at build time; only install.sh is a public installer.
ddnsto_error() { printf 'DDNSTO: %s\n' "$*" >&2; }

ddnsto_usage() {
    printf '%s\n' 'Usage: install.sh [--token TOKEN | --token-file FILE] [--force-version lite|standard] [--verify-status]' \
        'OpenWrt: token optional; automatic Lite selection below 900 MB.' \
        'Linux x86_64/aarch64: --token required without an interactive terminal.'
}

ddnsto_parse_args() {
    TOKEN=
    TOKEN_FILE=
    FORCE_VERSION=
    VERIFY_STATUS=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --token|--token-file|--force-version)
                [ "$#" -ge 2 ] && [ -n "$2" ] || { ddnsto_error "$1 requires a value"; return 2; }
                case "$1" in --token) TOKEN=$2 ;; --token-file) TOKEN_FILE=$2 ;; *) FORCE_VERSION=$2 ;; esac
                shift 2 ;;
            --token=*) TOKEN=${1#--token=}; [ -n "$TOKEN" ] || return 2; shift ;;
            --force-version=*) FORCE_VERSION=${1#--force-version=}; shift ;;
            --verify-status) VERIFY_STATUS=1; shift ;;
            *) ddnsto_error 'unknown argument (use --help)'; return 2 ;;
        esac
    done
    case "$FORCE_VERSION" in ''|lite|standard) ;; *) ddnsto_error 'version must be lite or standard'; return 2 ;; esac
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

ddnsto_prompt_token() (
    exec 3<>/dev/tty
    terminal_state=$(stty -g <&3)
    trap 'stty "$terminal_state" <&3; printf "\n" >&3' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    stty -echo <&3
    printf 'DDNSTO token: ' >&3
    IFS= read -r entered_token <&3
    printf '%s' "$entered_token"
)

ddnsto_prepare_token() {
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
    if [ -s "$verified_output" ] && [ -f "$verified_marker" ]; then
        verified_size=$(wc -c < "$verified_output" | tr -d '[:space:]')
        if [ "$(cat "$verified_marker")" = "$verified_sha:$verified_size" ]; then
            status "      Using verified cached ${verified_output##*/}"
            return 0
        fi
    fi
    ddnsto_download "$verified_relative" "$verified_output" "$verified_sha"
    verified_size=$(wc -c < "$verified_output" | tr -d '[:space:]')
    printf '%s:%s\n' "$verified_sha" "$verified_size" > "$transaction_dir/verified"
    mv -f "$transaction_dir/verified" "$verified_marker"
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

ddnsto_openwrt() {
    case "$package_manager" in opkg) pkg_ext=ipk ;; apk) pkg_ext=apk ;; *) ddnsto_error 'OpenWrt requires opkg or apk'; return 2 ;; esac
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
    version_num=$(ddnsto_pinned_version "$SELECTED_VERSION")
    version_folder=$SELECTED_VERSION
    [ "$pkg_ext" != apk ] || version_folder="$version_folder-apk"
    relative_folder="openwrt/$version_folder/$version_num"
    status "      DDNSTO $version_num ($SELECTED_VERSION; Lite below 900 MB)"
    status '[3/4] Downloading and verifying DDNSTO packages...'
    package_cache="$work_dir/cache/$version_folder/$version_num/$arch"
    mkdir -p "$package_cache"
    main_package="ddnsto_$package_arch.$pkg_ext"
    ui_package="luci-app-ddnsto.$pkg_ext"
    language_package="luci-i18n-ddnsto-zh-cn.$pkg_ext"
    for package in "$main_package" "$ui_package" "$language_package"; do
        case "$package" in
            ddnsto_*) product_path="$relative_folder/$package" ;;
            *) product_path="openwrt/$package" ;;
        esac
        digest=$(ddnsto_pinned_sha "$product_path")
        ddnsto_verified_download "$product_path" "$package_cache/$package" "$digest"
    done
    status '[4/4] Installing DDNSTO packages...'
    # All packages are verified before touching dependencies or installed packages.
    config_path=${DDNSTO_CONFIG_PATH:-/etc/config/ddnsto}
    deprecated_config=0
    if [ -f "$config_path" ] && grep -Eqi 'global' "$config_path"; then
        cp -p "$config_path" "$transaction_dir/deprecated-config"
        deprecated_config=1
        rm -f "$config_path"
    fi
    if [ "$package_manager" = opkg ]; then
        if [ -f /www/luci-static/resources/luci.js ] && [ ! -f /usr/lib/lua/luci/cbi.lua ]; then
            opkg update && opkg install luci-compat || status 'DDNSTO: luci-compat installation failed'
        fi
        if ! opkg list-installed | grep -q '^luci-lua-runtime '; then
            opkg update && opkg install luci-lua-runtime || status 'DDNSTO: luci-lua-runtime installation failed'
        fi
        opkg remove app-meta-ddnsto luci-i18n-ddnsto-zh-cn luci-app-ddnsto ddnsto || true
        for package in "$main_package" "$ui_package" "$language_package"; do opkg install "$package_cache/$package"; done
    else
        if [ -f /www/luci-static/resources/luci.js ] && [ ! -f /usr/lib/lua/luci/cbi.lua ]; then
            apk update && apk add luci-compat || status 'DDNSTO: luci-compat installation failed'
        fi
        if ! apk info -e luci-lua-runtime >/dev/null 2>&1; then
            apk update && apk add luci-lua-runtime || status 'DDNSTO: luci-lua-runtime installation failed'
        fi
        apk del app-meta-ddnsto luci-i18n-ddnsto-zh-cn luci-app-ddnsto ddnsto || true
        for package in "$main_package" "$ui_package" "$language_package"; do apk add --allow-untrusted "$package_cache/$package"; done
    fi
    ddnsto -v
    deprecated_config=0
    if [ -n "$TOKEN" ]; then
        uci set "ddnsto.@ddnsto[0].token=$TOKEN"
        uci set 'ddnsto.@ddnsto[0].enabled=1'
        uci commit ddnsto
        "${DDNSTO_SERVICE_PATH:-/etc/init.d/ddnsto}" restart
    else
        status 'DDNSTO: get a token at https://www.ddnsto.com and configure it in LuCI'
    fi
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
    [ -n "$TOKEN" ] || { ddnsto_error 'empty token'; return 2; }
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
    if ddnsto_privileged "$bin_path" -u "$TOKEN" -daemon; then
        ddnsto_linux_wait_healthy
        ddnsto_privileged chmod 0600 "$linux_config_file"
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
    case "$os:$package_manager" in
        openwrt:opkg|openwrt:apk) business_platform=openwrt ;;
        ubuntu:apt|debian:apt|centos:yum|centos:dnf|rhel:yum|rhel:dnf|linux:*) business_platform=linux ;;
        *) ddnsto_error "unsupported platform: $os/$package_manager"; return 2 ;;
    esac
    ddnsto_prepare_token
    work_dir=${ZSETUP_WORK_DIR:-${WORK_ROOT}/ddnsto}
    mkdir -p "$work_dir"
    chmod 0700 "$work_dir"
    transaction_dir=$(mktemp -d "$work_dir/.transaction.XXXXXX")
    install_candidate=
    backup=
    replacement_started=0
    SUDO=
    trap ddnsto_cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [ "$business_platform" = openwrt ]; then ddnsto_openwrt; else ddnsto_linux; fi
    ddnsto_cleanup
    transaction_dir=
    trap - EXIT HUP INT TERM
}

# Maintained product metadata; embedded in install.sh, never fetched at runtime.
# All 21 existing HTTPS artifacts re-downloaded and verified 2026-10-14.
# See docs/github-testing.md. Bump installer version when updating any pin.
ddnsto_pinned_version() {
    case "$1" in
        standard) printf '%s\n' 4.2.6 ;;
        lite) printf '%s\n' 4.2.2 ;;
        *) printf '%s\n' 'DDNSTO: unknown pinned variant' >&2; return 11 ;;
    esac
}

ddnsto_pinned_sha() {
    case "$1" in
        linux-binary/ddnsto-standard-4.2.3.tar.gz) printf '%s\n' b982ebd38e8c145d955049eb5b73960c01941bc05f084c3a2115dfca2b6eea6e ;;
        openwrt/lite-apk/4.2.2/ddnsto_aarch64.apk) printf '%s\n' fa8715e298357b1f194fd303b7bc53fe97fc2d62847099c8942fb1d833c44bba ;;
        openwrt/lite-apk/4.2.2/ddnsto_arm.apk) printf '%s\n' a0d748be8936b8515a4a83e624529ee9873728c434b44e330e03159e2f7fd4b4 ;;
        openwrt/lite-apk/4.2.2/ddnsto_mipsel.apk) printf '%s\n' 34cf69a86b7c22993e974d54b973ad65eda9a81b59b79a77eff68140bf3f421d ;;
        openwrt/lite-apk/4.2.2/ddnsto_x86_64.apk) printf '%s\n' 291a24cb1e8e821f127ad08249bcfbc1517501189b895fbad261c950e2aa0abf ;;
        openwrt/lite/4.2.2/ddnsto_aarch64.ipk) printf '%s\n' 4f1542dc9e8f14a2da69800190e2d2b5f20288c96c2067eb1ada62e9d9999d0c ;;
        openwrt/lite/4.2.2/ddnsto_arm.ipk) printf '%s\n' 3ccdc5100c4e43e7a75a6fd1cbfd5718e8ba7fce40ac4626da83487db2f3ea96 ;;
        openwrt/lite/4.2.2/ddnsto_mipsel.ipk) printf '%s\n' 22df2e1f8c9238e861954778d9b48f149660ee7b0fd8639b1e73731454209fbe ;;
        openwrt/lite/4.2.2/ddnsto_x86_64.ipk) printf '%s\n' 1434d56a8122d4fdb470a744a512373741307631fabde0a31e37733984461ca4 ;;
        openwrt/standard-apk/4.2.6/ddnsto_aarch64.apk) printf '%s\n' 55e0d89060bbd8d6df3ca473ca114f257dd1312587ea703963ce812877e7a509 ;;
        openwrt/standard-apk/4.2.6/ddnsto_arm.apk) printf '%s\n' a90951eb323a19f79964b597af9cdefbb728e675b8077c0fd115fa061011f62a ;;
        openwrt/standard-apk/4.2.6/ddnsto_mipsel.apk) printf '%s\n' ebd0f3eeed46ec8f45a585b0e49403725fbd18a48de42d9ed0380609ed0d76ed ;;
        openwrt/standard-apk/4.2.6/ddnsto_x86_64.apk) printf '%s\n' 470e4ea428f897cc8e38f7528b9387b0dd7373d5c727ef334e1d79c8dead7da2 ;;
        openwrt/standard/4.2.6/ddnsto_aarch64.ipk) printf '%s\n' 413aef536307542e08fde749af9c9b5db239280fb2cdee5f48ced5cb61ef545a ;;
        openwrt/standard/4.2.6/ddnsto_arm.ipk) printf '%s\n' 167ff8ba20965f72471bf8be9a1010eb776ca54b336033d807bb83c19e1f3917 ;;
        openwrt/standard/4.2.6/ddnsto_mipsel.ipk) printf '%s\n' 9a0c740708cb1ede7e680112bcec5c9dad9f00739ef8587b334f305898d2763c ;;
        openwrt/standard/4.2.6/ddnsto_x86_64.ipk) printf '%s\n' a7d868da03dea6e6e9b4cb02bc6f2ccfa31d2eeba62f0ac088338bc83e31e9eb ;;
        openwrt/luci-app-ddnsto.apk) printf '%s\n' 74c1905d95ec90077cd3f4b4d907782c093ad977f0c7c4c93137190106e1e566 ;;
        openwrt/luci-i18n-ddnsto-zh-cn.apk) printf '%s\n' 96fcf176a2d2be9d3ad85d0687d5f0adaa37282be4cb0c95cee609c6dde60fb4 ;;
        openwrt/luci-app-ddnsto.ipk) printf '%s\n' f3c87b000e7ec6ed640783232354b7462a274323d5edd5d2cc857c03192bda13 ;;
        openwrt/luci-i18n-ddnsto-zh-cn.ipk) printf '%s\n' 6c5f3e287b70704181769f23b1775c064bf1d4bf2c6ee1fb0a226377478c1a04 ;;
        *) printf '%s\n' "DDNSTO: no pinned artifact for $1; use a reviewed newer installer" >&2; return 11 ;;
    esac
}

# Included in install.sh. Do not trust older clients' service exit codes.
ddnsto_linux_preflight() {
    SUDO=
    if [ "$(id -u)" != 0 ]; then
        command -v sudo >/dev/null 2>&1 || { ddnsto_error 'Linux service installation requires root or sudo'; return 2; }
        SUDO=sudo
        sudo -v || return 2
    fi
    linux_service_name=com.linkease.ddnstoshell
    linux_config_dir=${DDNSTO_LINUX_CONFIG_DIR:-/etc/ddnsto}
    linux_config_file="$linux_config_dir/ddnsto-config.json"
    [ ! -L "$linux_config_dir" ] && [ ! -L "$linux_config_file" ] || {
        ddnsto_error 'service configuration must not be a symlink'; return 2;
    }
    if command -v systemctl >/dev/null 2>&1 && ddnsto_privileged systemctl show-environment >/dev/null 2>&1; then
        linux_service_manager=systemd
    elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1 &&
         command -v openrc-run >/dev/null 2>&1 && [ -f /run/openrc/softlevel ]; then
        linux_service_manager=openrc
    else
        ddnsto_error 'a running systemd or initialized OpenRC environment is required; no service changes made'
        return 2
    fi
    command -v readlink >/dev/null 2>&1 || return 2
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || {
        ddnsto_error 'curl or wget is required for the local health check'; return 2;
    }
}

ddnsto_linux_running() {
    case "$linux_service_manager" in
        systemd) ddnsto_privileged systemctl is-active --quiet "$linux_service_name" ;;
        openrc) ddnsto_privileged rc-service "$linux_service_name" status ;;
    esac
}

ddnsto_linux_stop() {
    case "$linux_service_manager" in
        systemd) ddnsto_privileged systemctl stop "$linux_service_name" ;;
        openrc) ddnsto_privileged rc-service "$linux_service_name" stop ;;
    esac
}

ddnsto_linux_health() (
    # Read only the client's own compact addrInfo schema; reject unfamiliar data
    # rather than eval JSON or probe an unrelated service at a hard-coded port.
    info=$(ddnsto_privileged cat "$linux_config_dir/.ddnsto_http_addr.json" 2>/dev/null) || exit 1
    case "$info" in '{"addr":"127.0.0.1:'*'","pid":'*',"startedAt":"'*'"}') ;; *) exit 1 ;; esac
    port=${info#*127.0.0.1:}; port=${port%%\"*}
    pid=${info#*\"pid\":}; pid=${pid%%,*}
    case "$port:$pid" in *[!0-9:]*|:*|*:) exit 1 ;; esac
    [ "${#port}" -le 5 ] && [ "$port" -gt 0 ] && [ "$port" -le 65535 ] || exit 1
    [ "${#pid}" -le 10 ] && [ "$pid" -gt 0 ] || exit 1
    executable=$(ddnsto_privileged readlink "/proc/$pid/exe") || exit 1
    [ "$executable" = "$(readlink -f "$bin_path")" ] || exit 1
    # Never send local checks through an environment-configured proxy.
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy
    if command -v curl >/dev/null 2>&1; then
        response=$(curl --noproxy '*' -fsS --connect-timeout 1 --max-time 2 "http://127.0.0.1:$port/healthz" 2>/dev/null) || exit 1
    else
        response=$(wget -q -T 2 -O - "http://127.0.0.1:$port/healthz" 2>/dev/null) || exit 1
    fi
    [ "$response" = ok ]
)

ddnsto_linux_wait_healthy() {
    health_attempt=0
    while [ "$health_attempt" -lt 10 ]; do
        if ddnsto_linux_running >/dev/null 2>&1 && ddnsto_linux_health; then return 0; fi
        health_attempt=$((health_attempt + 1))
        sleep 1
    done
    ddnsto_error 'local service health check failed (cloud connectivity is not required)'
    return 13
}

ddnsto_linux_restore() {
    # Every step is checked explicitly: this runs from a conditional EXIT trap,
    # where POSIX shells suppress errexit inside functions.
    ddnsto_linux_stop >/dev/null 2>&1 || return 1
    if [ "$had_old" = 1 ]; then
        ddnsto_privileged cp -p "$backup/binary" "$bin_path" || return 1
    else
        ddnsto_privileged "$bin_path" uninstall || return 1
        ddnsto_privileged rm -f "$bin_path" || return 1
    fi
    if [ "$had_config" = 1 ]; then
        ddnsto_privileged cp -p "$backup/config" "$linux_config_file" || return 1
    else
        ddnsto_privileged rm -f "$linux_config_file" || return 1
    fi
    if [ "$had_old" = 1 ]; then
        # Reuse restored service config, never overwrite it with the failed
        # candidate's Token while attempting recovery.
        ddnsto_privileged "$bin_path" -daemon || return 1
        ddnsto_linux_wait_healthy || return 1
    fi
    replacement_started=0
}


bootstrap_and_run() {
    status "[1/4] Checking zsetup..."
    bootstrap_zsetup
    status "      zsetup $RESCUE_VERSION is ready"
    ZSETUP_BIN=$ACTIVE_ZSETUP
    ZSETUP_SOURCE_BASES=${ZSETUP_SOURCE_BASES:-$DIRECT_PRIMARY_BASES}
    ZSETUP_SOURCE_FALLBACK=${ZSETUP_SOURCE_FALLBACK-$DIRECT_FALLBACK_BASE}
    export ZSETUP_BIN ZSETUP_ARCH ZSETUP_SOURCE_BASES ZSETUP_SOURCE_FALLBACK
    ddnsto_install "$@"
}

main() {
    # Preserve the original setup_ddnsto.sh TOKEN invocation without another installer.
    if [ "${0##*/}" = setup_ddnsto.sh ]; then
        [ "$#" -ge 1 ] && [ -n "$1" ] || { ddnsto_error 'Usage: setup_ddnsto.sh TOKEN'; return 2; }
        setup_token=$1
        shift
        set -- --token "$setup_token" --verify-status "$@"
    fi
    case "${1:-}" in --help|-h) ddnsto_usage; return 0 ;; esac
    status 'DDNSTO installer'
    if [ "${ZSETUP_INSTALLER_MODE:-0}" = 1 ]; then
        status '[1/4] zsetup is ready'
        ddnsto_install "$@"
    else
        bootstrap_and_run "$@"
    fi
}
main "$@"
