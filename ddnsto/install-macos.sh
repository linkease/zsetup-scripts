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
