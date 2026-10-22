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
REQUESTED_PLATFORM=auto
REQUESTED_METHOD=auto
PLAN_ONLY=0
ACTION=install
fail() { printf 'DDNSTO: %s\n' "$1" >&2; exit "${2:-2}"; }
while [ "$#" -gt 0 ]; do
    case "$1" in
        --token|--token-file|--version|--platform|--method|--action)
            [ "$#" -ge 2 ] || fail 'argument requires a value'
            case "$1" in --token) TOKEN=$2 ;; --token-file) TOKEN_FILE=$2 ;;
                --platform) REQUESTED_PLATFORM=$2 ;; --method) REQUESTED_METHOD=$2 ;;
                --action) ACTION=$2 ;; *) VERSION=$2 ;; esac
            shift 2 ;;
        --token=*) TOKEN=${1#--token=}; shift ;;
        --plan) PLAN_ONLY=1; shift ;;
        --help|-h) printf '%s\n' 'Usage: install-macos.sh [--plan] [--action install|update|status|start|stop|restart|repair|uninstall|configure] [--platform auto|macos] [--method auto|native] [--token TOKEN | --token-file FILE] [--version 4.2.1]' 'Existing installations default to no changes. Update/repair preserve configuration. Uninstall retains configuration and identity; install reuses them without Token.' 'Configure requires a new Token, preserves identity and restarts the service; failure attempts rollback.'; exit 0 ;;
        *) fail 'unknown argument' ;;
    esac
done
[ "$(uname -s)" = Darwin ] || fail 'this installer requires macOS'
case "$REQUESTED_PLATFORM" in auto|macos) ;; *) fail 'platform mismatch: this device is macos' ;; esac
case "$REQUESTED_METHOD" in auto|native) ;; docker) fail 'Docker installer is not available for macOS' ;; *) fail 'unknown installation method' ;; esac
case "$ACTION" in install|update|status|start|stop|restart|repair|uninstall|configure) ;; *) fail 'unknown action' ;; esac
if [ "$ACTION" != install ]; then
    [ "$ACTION" = configure ] || [ -z "$TOKEN$TOKEN_FILE" ] || fail 'service actions do not accept credentials'
    [ "$PLAN_ONLY" = 0 ] || fail '--plan cannot be combined with service actions'
fi
case "$(uname -m)" in x86_64|amd64) member=ddnsto_cli.amd64 ;; arm64|aarch64) member=ddnsto_cli.arm64 ;; *) fail 'unsupported macOS architecture' ;; esac
[ "$VERSION" = 4.2.1 ] || fail 'no pinned artifact for requested version'
if [ "$PLAN_ONLY" = 1 ]; then
    [ -z "$TOKEN$TOKEN_FILE" ] || fail '--plan does not accept credentials'
    printf '%s\n' 'facts_source=local-preflight' 'platform=macos' "arch=${member#ddnsto_cli.}" \
        "client_version=$VERSION" 'zsetup_version=0.3.0' 'native_status=requires-launchd-preflight' \
        'docker_installable=false' 'installation_performed=false'
    exit 0
fi
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
xml() { printf '%s' "$1" | sed 's/\&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }
managed_plist() {
    cat <<EOF
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
}
check_state() {
    state=absent
    for file in "$config" "$binary" "$plist" "$marker"; do
        [ ! -L "$file" ] || fail 'managed files must not be symlinks'
        [ ! -e "$file" ] || [ -f "$file" ] || fail 'managed files must be regular'
    done
    if [ -e "$binary" ] || [ -e "$config" ] || [ -e "$plist" ] || [ -e "$marker" ]; then
        [ -f "$marker" ] && [ -f "$config" ] || fail 'existing unmanaged or incomplete installation'
        case "$(cat "$marker")" in
            ddnsto-macos-v1) state=installed ;;
            ddnsto-macos-v1-retained) state=retained ;;
            *) fail 'unrecognized ownership marker' ;;
        esac
        if [ "$state" = retained ]; then
            [ ! -e "$binary" ] && [ ! -e "$plist" ] || fail 'retained installation contains unexpected files'
        else
            [ -f "$binary" ] || fail 'managed binary missing'
            if [ ! -f "$plist" ]; then
                # Let the default menu offer repair without treating a missing
                # definition as authority to update or start it.
                case "$ACTION" in install|repair|uninstall|status) ;; *) fail 'managed plist missing; use --action repair' ;; esac
            else
                # Only our complete generated definition is owned. Matching a
                # few XML fragments lets Program override the executable and
                # misses duplicate keys, environment and working-directory edits.
                # Preserve the existing repair contract for a disabled KeepAlive.
                actual_plist=$(sed 's,<key>KeepAlive</key><false/>,<key>KeepAlive</key><true/>,' "$plist")
                [ "$actual_plist" = "$(managed_plist)" ] || fail 'existing unmanaged plist; migrate it before retrying'
            fi
        fi
    fi
}
check_job() {
    job=$(launchctl print "$domain/$LABEL" 2>/dev/null) || return 0
    [ "$state" = installed ] || fail 'existing unmanaged launchd job'
    # Fail closed if a same-label job does not describe our exact file paths.
    normalized=$(printf '%s\n' "$job" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    printf '%s\n' "$normalized" | grep -F -x -q "program = $binary" &&
    printf '%s\n' "$normalized" | grep -F -x -q "path = $plist" &&
    printf '%s\n' "$normalized" | grep -F -x -q "$config" || fail 'existing unmanaged launchd job'
}
domain="gui/$(id -u)"
check_state
if [ "$ACTION" = update ] && [ ! -f "$marker" ]; then fail 'no existing installation; install first'; fi
if [ "$state" = retained ]; then
    [ -z "$TOKEN$TOKEN_FILE" ] || fail 'retained configuration preserves Token; omit credentials'
    case "$ACTION" in install|uninstall|status) ;; *) fail 'installation removed; use --action install to reuse retained configuration' ;; esac
fi
if [ "$ACTION" = install ] && [ "$state" = installed ]; then
    [ -z "$TOKEN$TOKEN_FILE" ] || fail 'existing installation preserves Token; use --action update without credentials'
    choice=0
    if [ -t 0 ]; then
        printf '%s\n' 'Existing DDNSTO installation detected.' \
            '0) Exit without changes (default)' '1) Update using existing configuration' \
            '2) Status' '3) Start' '4) Stop' '5) Restart' '6) Repair' \
            '7) Change Token (restarts service; enter new Token visibly)' \
            '8) Uninstall (retain configuration and identity)' >&2
        printf 'Choose [0]: ' >&2
        IFS= read -r choice || choice=0
    fi
    case "$choice" in
        ''|0) printf '%s\n' 'operation=none installation=existing cloud_status=unverified' 'No changes made. Use --action update to update, or --action repair for a missing service definition.'; exit 0 ;;
        1) ACTION=update ;;
        2) ACTION=status ;;
        3) ACTION=start ;;
        4) ACTION=stop ;;
        5) ACTION=restart ;;
        6) ACTION=repair ;;
        7) ACTION=configure ;;
        8) ACTION=uninstall ;;
        *) fail 'invalid action; no changes made' ;;
    esac
    check_state
fi
uninstall_managed() (
    # The caller holds the shared lock. Keep recoverable copies until every
    # owned file and the retained-state marker have been updated successfully.
    work=$(mktemp -d "${TMPDIR:-/tmp}/ddnsto-uninstall.XXXXXX")
    removed=0
    unloaded=0
    override_changed=0
    was_disabled=0
    was_loaded=0
    had_plist=0
    uninstall_cleanup() {
        code=$?
        trap - EXIT HUP INT TERM
        recovery_failed=0
        if [ "$code" != 0 ]; then
            if [ "$removed" = 1 ]; then
                cp -p "$work/binary" "$binary" || recovery_failed=1
                cp -p "$work/marker" "$marker" || recovery_failed=1
                if [ "$had_plist" = 1 ]; then cp -p "$work/plist" "$plist" || recovery_failed=1; fi
            fi
            if [ "$unloaded" = 1 ]; then
                launchctl enable "$domain/$LABEL" >&2 || recovery_failed=1
                launchctl bootstrap "$domain" "$plist" >&2 || recovery_failed=1
            fi
            if [ "$override_changed" = 1 ]; then
                if [ "$was_disabled" = 1 ]; then
                    launchctl disable "$domain/$LABEL" >&2 || recovery_failed=1
                else
                    launchctl enable "$domain/$LABEL" >&2 || recovery_failed=1
                fi
            fi
        fi
        if [ "$recovery_failed" = 1 ]; then
            printf 'DDNSTO: uninstall recovery incomplete; backup retained at %s\n' "$work" >&2
            exit 1
        fi
        rm -rf "$work"
        exit "$code"
    }
    trap uninstall_cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    cp -p "$binary" "$work/binary"
    cp -p "$marker" "$work/marker"
    if [ -f "$plist" ]; then cp -p "$plist" "$work/plist"; had_plist=1; fi
    launchctl print-disabled "$domain" > "$work/disabled" || fail 'cannot inspect launchd disabled state'
    if grep -E -q '^[[:space:]]*"com\.ddnsto\.client"[[:space:]]*=>[[:space:]]*(disabled|true)[[:space:]]*[;,]?[[:space:]]*$' "$work/disabled"; then was_disabled=1; fi
    if launchctl print "$domain/$LABEL" >/dev/null 2>&1; then was_loaded=1; fi
    # A missing on-disk definition cannot be restored after unloading. Repair
    # it first so uninstall retains a complete rollback path.
    [ "$was_loaded" = 0 ] || [ "$had_plist" = 1 ] || fail 'loaded service has no plist; use --action repair before uninstall'
    override_changed=1
    launchctl disable "$domain/$LABEL" || fail 'could not disable service'
    if [ "$was_loaded" = 1 ]; then
        launchctl bootout "$domain/$LABEL" || fail 'could not stop service'
        unloaded=1
    fi
    if launchctl print "$domain/$LABEL" >/dev/null 2>&1; then fail 'service still loaded after stop'; fi
    removed=1
    rm -f "$binary" "$plist"
    printf '%s\n' 'ddnsto-macos-v1-retained' > "$marker"
    printf '%s\n' 'operation=uninstall local_service=not-installed configuration=retained cloud_status=unverified' 'Token, configuration, identity and logs retained. Use --action install without credentials to reinstall.'
)
manage_service() (
    domain="gui/$(id -u)"
    check_job
    if [ "$state" != installed ]; then
        if launchctl print "$domain/$LABEL" >/dev/null 2>&1; then fail 'existing unmanaged launchd job'; fi
        case "$ACTION" in status|uninstall) ;; *) fail 'no managed installation; install first' ;; esac
        printf 'local_service=not-installed configuration=%s cloud_status=unverified\n' "$state"
        exit 0
    fi
    launchctl print-disabled "$domain" >/dev/null || fail 'cannot access user launchd domain'
    if [ "$ACTION" = status ]; then
        if launchctl print "$domain/$LABEL" 2>/dev/null | grep -E -q 'pid = [1-9][0-9]*'; then
            printf '%s\n' 'local_service=running cloud_status=unverified'
        elif [ ! -f "$plist" ]; then
            printf '%s\n' 'local_service=needs-repair cloud_status=unverified'
        else
            printf '%s\n' 'local_service=stopped cloud_status=unverified'
        fi
        exit 0
    fi
    mkdir "$CONFIG_DIR/.install-lock" 2>/dev/null || fail 'another installation or service action is active'
    trap 'rmdir "$CONFIG_DIR/.install-lock"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    check_state
    check_job
    if [ "$ACTION" = uninstall ]; then uninstall_managed; exit "$?"; fi
    if [ "$ACTION" = stop ]; then
        launchctl disable "$domain/$LABEL" || fail 'could not disable service'
        if launchctl print "$domain/$LABEL" >/dev/null 2>&1; then
            launchctl bootout "$domain/$LABEL" || fail 'could not stop service'
        fi
        if launchctl print "$domain/$LABEL" >/dev/null 2>&1; then fail 'service still loaded after stop'; fi
        printf '%s\n' 'local_service=stopped cloud_status=unverified' 'Login autostart disabled. Use --action start to resume.'
        exit 0
    fi
    launchctl enable "$domain/$LABEL" || fail 'could not enable service'
    if [ "$ACTION" = restart ] && launchctl print "$domain/$LABEL" >/dev/null 2>&1; then
        launchctl bootout "$domain/$LABEL" || fail 'could not stop service for restart'
    fi
    if ! launchctl print "$domain/$LABEL" >/dev/null 2>&1; then
        launchctl bootstrap "$domain" "$plist" || fail 'could not load service'
    fi
    launchctl kickstart "$domain/$LABEL" || fail 'could not start service'
    sleep 1
    launchctl print "$domain/$LABEL" | grep -E -q 'pid = [1-9][0-9]*' || fail 'service has no running process'
    printf '%s\n' 'local_service=running cloud_status=unverified'
)
case "$ACTION" in install|update|repair|configure) ;; *) manage_service; exit "$?" ;; esac
case "$ACTION" in repair|configure) [ "$state" = installed ] || fail 'no managed installation';; esac
if [ "$state" != absent ]; then check_job; fi
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
if [ -z "$TOKEN" ] && [ -z "$TOKEN_FILE" ]; then
    if [ "$ACTION" = configure ] || [ ! -f "$config" ]; then
        TOKEN=$(read_token) || fail 'token required: use an interactive terminal or --token-file FILE'
    fi
fi
case "$TOKEN" in *"
"*|*"$(printf '\r')"*) fail 'token must be one line' ;; esac
yaml_token=$(printf '%s' "$TOKEN" | sed "s/'/''/g")
token_line="userToken: '$yaml_token'"
if [ "$ACTION" = configure ]; then
    [ -n "$TOKEN" ] || fail 'configure requires --token or --token-file'
elif [ -f "$config" ]; then
    [ -z "$TOKEN" ] || grep -F -x -q -- "$token_line" "$config" || fail 'existing token differs; edit configuration explicitly before reinstalling'
else
    [ -n "$TOKEN" ] || fail 'token is required on first installation'
fi
uid=$(id -u)
domain="gui/$uid"
work=$(mktemp -d "${TMPDIR:-/tmp}/ddnsto.XXXXXX")
changed=0
had_old=0
had_config=0
had_plist=0
had_marker=0
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
        if launchctl print "$domain/$LABEL" >/dev/null 2>&1; then
            launchctl bootout "$domain/$LABEL" >/dev/null 2>&1 || recovery_failed=1
            if launchctl print "$domain/$LABEL" >/dev/null 2>&1; then recovery_failed=1; fi
        fi
        # Never replace files underneath a candidate that could still be live.
        # A failed stop retains all recovery material and reports uncertainty.
        if [ "$recovery_failed" = 1 ]; then
            printf '%s\n' 'DDNSTO: could not stop candidate during recovery; live files were not restored' >&2
        elif [ "$had_old" = 1 ]; then
            cp -p "$work/old-binary" "$binary" || recovery_failed=1
            cp -p "$work/old-config" "$config" || recovery_failed=1
            if [ "$had_plist" = 1 ]; then
                cp -p "$work/old-plist" "$plist" || recovery_failed=1
            elif [ "$was_running" = 1 ]; then
                # Recreate the known managed definition just long enough to
                # reload the prior job; then restore the missing-file state.
                cp -p "$work/plist" "$plist" || recovery_failed=1
            else
                rm -f "$plist" || recovery_failed=1
            fi
            if [ "$was_running" = 1 ]; then launchctl bootstrap "$domain" "$plist" >&2 || recovery_failed=1; fi
            if [ "$had_plist" = 0 ]; then rm -f "$plist" || recovery_failed=1; fi
        else
            rm -f "$binary" "$plist" || recovery_failed=1
            if [ "$had_config" = 0 ]; then rm -f "$config" "$marker" || recovery_failed=1; fi
        fi
        if [ "$recovery_failed" = 0 ] && [ "$had_marker" = 1 ]; then
            cp -p "$work/old-marker" "$marker" || recovery_failed=1
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
mkdir -p "$CONFIG_DIR"
mkdir "$CONFIG_DIR/.install-lock" 2>/dev/null || fail 'another installation is active'
locked=1
if [ "$ACTION" != repair ] && [ "$ACTION" != configure ]; then
    ensure_zsetup
    "$ZSETUP_BIN" download -o "$work/client.tar.gz" --sha256 "$archive_sha" \
        "https://fw.koolcenter.com/binary/ddnsto/macOS/ddnsto_darwin_cli_${VERSION}.tar.gz"
    tar -xzf "$work/client.tar.gz" -C "$work" "$member"
    [ -f "$work/$member" ] && [ ! -L "$work/$member" ] || fail 'missing regular client binary' 11
fi
mkdir -p "$CONFIG_DIR" "$INSTALL_DIR" "$AGENTS_DIR"
chmod 700 "$CONFIG_DIR"
# Revalidate ownership after locking; another installer may have just finished.
initial_state=$state
check_state
[ "$initial_state" = "$state" ] || fail 'installation changed; retry'
check_job
if [ "$state" != absent ]; then
    [ "$ACTION" = configure ] || [ -z "$TOKEN" ] || grep -F -x -q -- "$token_line" "$config" || fail 'existing token differs'
elif launchctl print "$domain/$LABEL" >/dev/null 2>&1; then
    fail 'existing unmanaged launchd job; migrate it before retrying'
else
    [ -n "$TOKEN" ] || fail 'token is required on first installation'
fi
if [ -f "$binary" ]; then
    cp -p "$binary" "$work/old-binary"
    cp -p "$config" "$work/old-config"
    if [ -f "$plist" ]; then cp -p "$plist" "$work/old-plist"; had_plist=1; fi
    had_old=1
    if launchctl print "$domain/$LABEL" >/dev/null 2>&1; then was_running=1; fi
fi
if [ -f "$config" ]; then had_config=1; fi
if [ -f "$marker" ]; then
    cp -p "$marker" "$work/old-marker"
    had_marker=1
fi
# Disabled overrides survive bootout and removal of the plist. Read them before
# changing files/services; macOS reports either "disabled" or "true".
launchctl print-disabled "$domain" > "$work/disabled-status" || fail 'cannot inspect launchd disabled state; no client changes made'
if grep -E -q '^[[:space:]]*"com\.ddnsto\.client"[[:space:]]*=>[[:space:]]*(disabled|true)[[:space:]]*[;,]?[[:space:]]*$' "$work/disabled-status"; then
    was_disabled=1
fi
if [ "$had_config" = 0 ]; then
    printf '%s\n' "$token_line" > "$work/config"
    printf "logPath: '%s'\n" "$(printf '%s' "$CONFIG_DIR/logs" | sed "s/'/''/g")" >> "$work/config"
fi
if [ "$ACTION" = configure ]; then
    # Only rewrite the installer's one-line scalar. Ambiguous/custom YAML
    # needs manual migration rather than an unsafe partial credential edit.
    [ "$(grep -c '^userToken:' "$config")" = 1 ] &&
        grep -E -q "^userToken: '([^']|'')*'$" "$config" || fail 'configure requires one installer-format userToken scalar'
    sed '/^userToken:/d' "$config" > "$work/config"
    printf '%s\n' "$token_line" >> "$work/config"
fi
managed_plist > "$work/plist"
if [ "$ACTION" != repair ] && [ "$ACTION" != configure ]; then
    candidate=$(mktemp "$INSTALL_DIR/.ddnsto.XXXXXX")
    cp "$work/$member" "$candidate"
    chmod 755 "$candidate"
fi
if [ "$was_disabled" = 1 ]; then
    printf '%s\n' 'DDNSTO: re-enabling the disabled user service for installation.' >&2
    restore_disabled=1
    launchctl enable "$domain/$LABEL"
fi
if [ "$was_running" = 1 ]; then launchctl bootout "$domain/$LABEL"; fi
changed=1
if [ -n "$candidate" ]; then mv -f "$candidate" "$binary"; fi
candidate=
if [ "$had_config" = 0 ] || [ "$ACTION" = configure ]; then cp "$work/config" "$config"; fi
chmod 600 "$config"
cp "$work/plist" "$plist"
launchctl bootstrap "$domain" "$plist"
launchctl kickstart -k "$domain/$LABEL"
sleep 1
launchctl print "$domain/$LABEL" > "$work/service-status"
grep -E -q 'pid = [1-9][0-9]*' "$work/service-status" || fail 'launchd job has no running process' 1
printf '%s\n' 'ddnsto-macos-v1' > "$marker"
changed=0
printf '%s\n' "DDNSTO $VERSION: operation=$ACTION local_service=running cloud_status=unverified" \
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

#!/bin/sh
# DDNSTO Linux/OpenWrt only. Embed AFTER lib/bootstrap.sh, only in DDNSTO.
# Call ddnsto_bootstrap_zsetup instead of bootstrap_zsetup at the business
# bootstrap call site. The shared function remains intact; no alias is needed.
# Desktop entrypoints retain their separate 0.3.0 / 0.4.0 policies.

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

bootstrap_fetch_from_base() (
    # DDNSTO-only transport policy; retain the shared mirror/download lifecycle
    # and URL construction. A valid pin does not authorize HTTP transport.
    [ "$1" = https ] || return 1
    url=$(bootstrap_url "$1" "$2" "$3") || return 1
    if command -v curl >/dev/null 2>&1; then
        rm -f "$4" || return 1
        # -q must be first: a user curlrc must not inject extra transfer URLs.
        if curl -q -fsSL --proto '=https' --proto-redir '=https' \
            --connect-timeout 10 --max-time 30 -o "$4" "$url"; then
            return 0
        fi
    fi
    if command -v wget >/dev/null 2>&1; then
        # BusyBox/uclient-fetch variants have different redirect controls. Only
        # GNU Wget's explicit zero-redirect mode is accepted; no auto downgrade.
        wget_version=$(wget --version 2>/dev/null) || wget_version=
        case "$wget_version" in
            'GNU Wget '*)
                rm -f "$4" || return 1
                wget -q -T 10 --max-redirect=0 -O "$4" "$url"
                return $? ;;
        esac
    fi
    printf '%s\n' 'DDNSTO: HTTPS bootstrap needs curl with protocol restrictions or GNU Wget with redirects disabled' >&2
    return 1
)

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


# Business logic: maintained in ddnsto/business.sh
# Included at build time; only install.sh is a public installer.
ddnsto_error() { printf 'DDNSTO: %s\n' "$*" >&2; }

ddnsto_usage() {
    printf '%s\n' 'Usage: install.sh [--plan] [--action install|update|status|start|stop|restart|repair|configure|uninstall|download] [--platform auto|linux|openwrt|macos|windows|synology|qnap|unraid] [--method auto|native|docker] [--token TOKEN | --token-file FILE] [--force-version lite|standard] [--verify-status]' \
        '--plan: read-only local preflight; no downloads, token, or service changes.' \
        'Platform is a constraint, not an override. QNAP/Unraid are unavailable; Windows requires install.ps1.' \
        'Synology: verified SPK download, manual DSM installation required; optional --output-dir DIR.' \
        'Docker: experimental local Linux amd64/root only; first install requires --device-name NAME --network bridge|host and Token.' \
        'Docker replacement/recreation is blocked pending identity validation. No native/container migration.' \
        'Linux repair/configure/uninstall require owned systemd service; configure also requires jq.' \
        'OpenWrt: token optional; automatic Lite selection below 900 MB.' \
        'Linux x86_64/aarch64: --token required without an interactive terminal.'
}

ddnsto_parse_args() {
    TOKEN=
    TOKEN_FILE=
    FORCE_VERSION=
    VERIFY_STATUS=0
    REQUESTED_PLATFORM=auto
    REQUESTED_METHOD=auto
    PLAN_ONLY=0
    ACTION=install
    OUTPUT_DIR=
    DEVICE_NAME=
    NETWORK=
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --token|--token-file|--force-version|--platform|--method|--action|--output-dir|--device-name|--network)
                [ "$#" -ge 2 ] && [ -n "$2" ] || { ddnsto_error "$1 requires a value"; return 2; }
                case "$1" in
                    --token) TOKEN=$2 ;; --token-file) TOKEN_FILE=$2 ;;
                    --platform) REQUESTED_PLATFORM=$2 ;; --method) REQUESTED_METHOD=$2 ;;
                    --action) ACTION=$2 ;;
                    --output-dir) OUTPUT_DIR=$2 ;;
                    --device-name) DEVICE_NAME=$2 ;; --network) NETWORK=$2 ;;
                    *) FORCE_VERSION=$2 ;;
                esac
                shift 2 ;;
            --token=*) TOKEN=${1#--token=}; [ -n "$TOKEN" ] || return 2; shift ;;
            --force-version=*) FORCE_VERSION=${1#--force-version=}; shift ;;
            --verify-status) VERIFY_STATUS=1; shift ;;
            --plan) PLAN_ONLY=1; shift ;;
            *) ddnsto_error 'unknown argument (use --help)'; return 2 ;;
        esac
    done
    case "$REQUESTED_PLATFORM" in auto|linux|openwrt|macos|windows|synology|qnap|unraid) ;; *) ddnsto_error 'unknown platform'; return 2 ;; esac
    case "$REQUESTED_METHOD" in auto|native|docker) ;; *) ddnsto_error 'unknown installation method'; return 2 ;; esac
    [ "$REQUESTED_METHOD" = docker ] || [ -z "$DEVICE_NAME$NETWORK" ] || { ddnsto_error 'device-name/network require explicit Docker'; return 2; }
    case "$NETWORK" in ''|bridge|host) ;; *) ddnsto_error 'network must be bridge or host'; return 2 ;; esac
    if [ -n "$OUTPUT_DIR" ]; then
        case "$ACTION" in install|download) ;; *) ddnsto_error 'output-dir only applies to Synology downloads'; return 2 ;; esac
    fi
    case "$FORCE_VERSION" in ''|lite|standard) ;; *) ddnsto_error 'version must be lite or standard'; return 2 ;; esac
    case "$ACTION" in
        install|update) ;;
        download)
            [ -z "$TOKEN$TOKEN_FILE$FORCE_VERSION" ] && [ "$VERIFY_STATUS" = 0 ] || {
                ddnsto_error 'download does not accept credentials or installation options'; return 2;
            } ;;
        status|start|stop|restart|repair|uninstall)
            [ -z "$TOKEN$TOKEN_FILE$FORCE_VERSION" ] && [ "$PLAN_ONLY$VERIFY_STATUS" = 00 ] || {
                ddnsto_error 'service actions do not accept credentials, plan, or installation options'; return 2;
            } ;;
        configure)
            [ -z "$FORCE_VERSION" ] && [ "$PLAN_ONLY$VERIFY_STATUS" = 00 ] || {
                ddnsto_error 'configure does not accept plan or installation options'; return 2;
            } ;;
        *) ddnsto_error 'unknown action'; return 2 ;;
    esac
    if [ "$ACTION" = update ]; then
        [ -z "$TOKEN$TOKEN_FILE" ] || { ddnsto_error 'update preserves existing Token; do not supply credentials'; return 2; }
        [ "$PLAN_ONLY" = 0 ] || { ddnsto_error '--plan cannot be combined with update'; return 2; }
    fi
    if [ "$PLAN_ONLY" = 1 ]; then
        [ -z "$TOKEN$TOKEN_FILE" ] || { ddnsto_error '--plan does not accept credentials'; return 2; }
        return 0
    fi
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

# Inspect marker existence only. Never source vendor configuration as shell code.
ddnsto_appliance_platform() {
    appliance_root=${1:-}
    if [ -f "$appliance_root/etc/synoinfo.conf" ] || [ -d "$appliance_root/usr/syno" ]; then
        printf '%s\n' synology
    elif [ -f "$appliance_root/etc/config/uLinux.conf" ]; then
        printf '%s\n' qnap
    elif [ -f "$appliance_root/etc/unraid-version" ]; then
        printf '%s\n' unraid
    fi
}

ddnsto_detect_platform() {
    detected_platform=$(ddnsto_appliance_platform)
    if [ -z "$detected_platform" ]; then
        # Some released zsetup versions report appliances in os, others may
        # report device. Missing device is tolerated; it is not a new dependency.
        for platform_fact in "$os" "${device:-}"; do
            case "$platform_fact" in
                synology|dsm) detected_platform=synology; break ;;
                qnap|qts) detected_platform=qnap; break ;;
                unraid) detected_platform=unraid; break ;;
            esac
        done
    fi
    if [ -z "$detected_platform" ]; then
        case "$os:$package_manager" in
            openwrt:opkg|openwrt:apk) detected_platform=openwrt ;;
            ubuntu:apt|debian:apt|centos:yum|centos:dnf|rhel:yum|rhel:dnf|linux:*) detected_platform=linux ;;
            *) ddnsto_error "unsupported platform: $os/$package_manager"; return 2 ;;
        esac
    fi
    if [ "$REQUESTED_PLATFORM" != auto ] && [ "$REQUESTED_PLATFORM" != "$detected_platform" ]; then
        ddnsto_error "platform mismatch: requested $REQUESTED_PLATFORM, detected $detected_platform; use the matching device command"
        return 2
    fi
}

ddnsto_validate_action_options() {
    case "$ACTION" in
        install|update|download) return 0 ;;
        *) [ -z "$FORCE_VERSION${OUTPUT_DIR:-}" ] && [ "$VERIFY_STATUS" = 0 ] || {
            ddnsto_error 'selected service action does not accept installation options'; return 2;
        } ;;
    esac
}

ddnsto_validate_platform_options() {
    ddnsto_validate_action_options || return $?
    if [ "$detected_platform" != synology ]; then
        [ -z "${OUTPUT_DIR:-}" ] && [ "$ACTION" != download ] || { ddnsto_error 'download and output-dir require Synology'; return 2; }
    fi
    if [ "$detected_platform" = linux ]; then
        [ "$FORCE_VERSION" != lite ] && [ "$VERIFY_STATUS" = 0 ] || { ddnsto_error 'OpenWrt options are not supported on Linux'; return 2; }
    fi
}

ddnsto_native_conflict_guard() {
    [ "${business_platform:-${detected_platform:-}}" = linux ] || return 0
    native_docker_state=${DDNSTO_DOCKER_STATE_DIR:-/etc/ddnsto-docker}
    if ddnsto_privileged test -e "$native_docker_state" || ddnsto_privileged test -L "$native_docker_state"; then
        ddnsto_error 'Docker state conflicts with native installation; automatic migration is not supported'
        return 2
    fi
}

ddnsto_select_platform() {
    ddnsto_detect_platform || return $?
    [ -z "${OUTPUT_DIR:-}" ] && [ "$ACTION" != download ] || { ddnsto_error 'download and output-dir require Synology'; return 2; }
    if [ "$REQUESTED_METHOD" = docker ]; then
        ddnsto_error 'Docker installer is not available in this candidate; use the official Docker guide; native installation was not attempted'
        return 2
    fi
    case "$detected_platform" in
        linux|openwrt) business_platform=$detected_platform ;;
        *) ddnsto_error "$detected_platform installer is not available in this candidate; use the official device guide; generic Linux installation was not attempted"; return 2 ;;
    esac
}

ddnsto_local_platform() {
    [ "$(uname -s)" = Linux ] || { ddnsto_error 'unsupported platform'; return 2; }
    os=linux package_manager=unknown device=
    if [ -f /etc/openwrt_release ]; then
        os=openwrt
        if command -v opkg >/dev/null 2>&1; then package_manager=opkg
        elif command -v apk >/dev/null 2>&1; then package_manager=apk; fi
    fi
    ddnsto_detect_platform || return $?
}

ddnsto_plan() {
    # No bootstrap in preview mode. Actual installation uses zsetup context;
    # local preflight is deliberately labelled, not an installation guarantee.
    ddnsto_local_platform || return $?
    if [ "$detected_platform" = synology ]; then ddnsto_synology_download; return $?; fi
    [ -z "${OUTPUT_DIR:-}" ] && [ "$ACTION" != download ] || { ddnsto_error 'download and output-dir require Synology'; return 2; }
    case "$(uname -m)" in
        x86_64|amd64) arch=x86_64 ;;
        aarch64|arm64) arch=aarch64 ;;
        armv7l|armv7) arch=armv7 ;;
        mipsel|mipsle) arch=mipsel ;;
        *) ddnsto_error 'unsupported architecture'; return 2 ;;
    esac
    native_status=executor-unavailable client_version=unavailable
    case "$detected_platform:$arch" in
        linux:x86_64|linux:aarch64)
            [ "${DDNSTO_VERSION:-4.2.3}" = 4.2.3 ] || { ddnsto_error 'no pinned artifact for requested version'; return 2; }
            [ "$FORCE_VERSION" != lite ] && [ "$VERIFY_STATUS" = 0 ] || { ddnsto_error 'OpenWrt options are not supported on Linux'; return 2; }
            native_status=requires-service-preflight
            client_version=${DDNSTO_VERSION:-4.2.3} ;;
        openwrt:*)
            native_status=requires-package-preflight
            client_version=standard-4.2.6-or-lite-4.2.2 ;;
    esac
    printf '%s\n' 'facts_source=local-preflight' "platform=$detected_platform" "arch=$arch" \
        "requested_method=$REQUESTED_METHOD" "native_status=$native_status" "client_version=$client_version" \
        "docker_probe=$(ddnsto_probe_docker)" 'docker_installable=false' 'installation_performed=false'
    [ "$REQUESTED_METHOD" != docker ] && [ "$native_status" != executor-unavailable ] || return 2
}

ddnsto_prompt_token() (
    exec 3<>/dev/tty
    terminal_state=$(stty -g <&3)
    trap 'stty "$terminal_state" <&3; printf "\n" >&3' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    stty echo <&3
    printf 'DDNSTO token: ' >&3
    IFS= read -r entered_token <&3
    printf '%s' "$entered_token"
)

ddnsto_prepare_token() {
    [ "${RETAINED_CONFIG:-0}" != 1 ] || return 0
    if [ "${ACTION:-install}" = update ] && [ "$business_platform" = linux ]; then return 0; fi
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

ddnsto_choose_existing_action() (
    [ -t 0 ] || { printf exit; return; }
    exec 3<>/dev/tty
    printf '%s\n' 'Existing DDNSTO installation detected.' '0) Exit without changes (default)' '1) Update using existing configuration' \
        '2) Repair managed service' '3) Change Token explicitly' '4) Status' '5) Stop and disable startup' \
        '6) Start and enable startup' '7) Uninstall managed program (retain configuration)' >&3
    printf 'Choose [0]: ' >&3
    IFS= read -r choice <&3 || choice=
    case "$choice" in ''|0) printf exit ;; 1) printf update ;; 2) printf repair ;; 3) printf configure ;;
        4) printf status ;; 5) printf stop ;; 6) printf start ;; 7) printf uninstall ;; *) return 2 ;; esac
)

ddnsto_existing_policy() {
    INSTALL_SKIPPED=0
    RETAINED_CONFIG=0
    if [ "$business_platform" = openwrt ]; then
        existing_binary=${DDNSTO_OPENWRT_BIN_PATH:-/usr/sbin/ddnstod}
        existing_config=${DDNSTO_CONFIG_PATH:-/etc/config/ddnsto}
        existing_service=${DDNSTO_SERVICE_PATH:-/etc/init.d/ddnsto}
        existing_marker=${existing_config%/*}/.uninstalled-openwrt-v1
        for existing_path in "$existing_binary" "$existing_config" "$existing_service" "$existing_marker"; do
            ddnsto_ow_safe_path "$existing_path" || {
                ddnsto_error 'unsafe OpenWrt installation path'; return 2
            }
        done
        if [ -e "$existing_marker" ]; then
            ddnsto_openwrt_retained_state_valid || {
                ddnsto_error 'unrecognized retained OpenWrt marker; no migration attempted'; return 2
            }
            [ "$ACTION" = install ] && [ -z "$TOKEN$TOKEN_FILE" ] || {
                ddnsto_error 'retained OpenWrt installation: use install without credentials to reuse configuration'; return 2
            }
            RETAINED_CONFIG=1
            return 0
        fi
        if [ -e "$existing_binary" ] || [ -e "$existing_config" ] || [ -e "$existing_service" ]; then
            [ -f "$existing_binary" ] && [ -f "$existing_config" ] || {
                ddnsto_error 'incomplete or unrecognized OpenWrt installation; automatic package replacement is unavailable'; return 2
            }
            if [ "$ACTION" = install ]; then
                [ -z "$TOKEN$TOKEN_FILE" ] || { ddnsto_error 'existing installation preserves Token; use configure explicitly'; return 2; }
                selected_action=$(ddnsto_choose_existing_action) || { ddnsto_error 'invalid action; no changes made'; return 2; }
                if [ "$selected_action" = exit ]; then
                    printf '%s\n' 'operation=none installation=existing cloud_status=unverified' 'No changes made. Use --action update to update explicitly.'
                    INSTALL_SKIPPED=1
                    return 0
                fi
                ACTION=$selected_action
            fi
        elif [ "$ACTION" = update ]; then
            ddnsto_error 'no existing installation; use the install action first'; return 2
        fi
        return 0
    else
        existing_binary=${DDNSTO_BIN_PATH:-/usr/local/bin/ddnsto}
        existing_dir=${DDNSTO_LINUX_CONFIG_DIR:-/etc/ddnsto}
        existing_config=$existing_dir/ddnsto-config.json
        if [ -d "$existing_dir" ] && [ ! -x "$existing_dir" ] && [ "$(id -u)" != 0 ]; then
            command -v sudo >/dev/null 2>&1 || { ddnsto_error 'root or sudo required to inspect protected existing configuration'; return 2; }
            SUDO=sudo
            sudo -v || return 2
        fi
        if ! ddnsto_privileged test -e "$existing_binary" && ! ddnsto_privileged test -L "$existing_binary" &&
           ddnsto_linux_state_valid "${DDNSTO_LINUX_CONFIG_DIR:-/etc/ddnsto}/.uninstalled-linux-v1"; then
            [ "$ACTION" = install ] && [ -z "$TOKEN$TOKEN_FILE" ] || {
                ddnsto_error 'retained installation: use install without credentials to reuse configuration'; return 2;
            }
            ddnsto_privileged test ! -e "$existing_dir/.installer-linux-v1" || return 2
            ddnsto_privileged test -f "$existing_config" && ddnsto_privileged test ! -L "$existing_config" || return 2
            RETAINED_CONFIG=1
            return 0
        fi
    fi
    if ddnsto_privileged test -e "$existing_binary" || ddnsto_privileged test -L "$existing_binary" || ddnsto_privileged test -e "$existing_config" || ddnsto_privileged test -L "$existing_config"; then
        ddnsto_privileged test -f "$existing_binary" && ddnsto_privileged test ! -L "$existing_binary" && ddnsto_privileged test -f "$existing_config" && ddnsto_privileged test ! -L "$existing_config" || {
            ddnsto_error 'incomplete or unrecognized installation; check files and permissions before retrying'; return 2;
        }
        if [ "$ACTION" = install ]; then
            [ -z "$TOKEN$TOKEN_FILE" ] || { ddnsto_error 'existing installation preserves Token; use --action update without credentials'; return 2; }
            selected_action=$(ddnsto_choose_existing_action) || { ddnsto_error 'invalid action; no changes made'; return 2; }
            if [ "$selected_action" = exit ]; then
                printf '%s\n' 'operation=none installation=existing cloud_status=unverified' 'No changes made. Use --action update to update explicitly.'
                INSTALL_SKIPPED=1
                return 0
            fi
            ACTION=$selected_action
        fi
    elif [ "$ACTION" = update ]; then
        ddnsto_error 'no existing installation; use the install action first'; return 2
    fi
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
    # A size/marker match cannot authenticate cached bytes. Let zsetup verify
    # the digest on every use; its own verified download cache avoids transfers.
    ddnsto_download "$verified_relative" "$verified_output" "$verified_sha" || return $?
    [ -f "$verified_output" ] && [ ! -L "$verified_output" ] || return 11
    verified_size=$(wc -c < "$verified_output") || return $?
    verified_size=$(printf '%s' "$verified_size" | tr -d '[:space:]')
    printf '%s:%s\n' "$verified_sha" "$verified_size" > "$transaction_dir/verified" || return $?
    mv -f "$transaction_dir/verified" "$verified_marker" || return $?
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

ddnsto_linux_state_valid() {
    state_file=$1
    ddnsto_privileged test -f "$state_file" && ddnsto_privileged test ! -L "$state_file" || return 1
    state_expected=$(printf 'ddnsto-linux-v1\n%s\n%s\n' "${DDNSTO_BIN_PATH:-/usr/local/bin/ddnsto}" "${DDNSTO_LINUX_CONFIG_DIR:-/etc/ddnsto}/ddnsto-config.json")
    state_actual=$(ddnsto_privileged cat "$state_file") || return 1
    [ "$state_actual" = "$state_expected" ]
}

ddnsto_linux_write_state() (
    state_target=$1
    state_dir=${DDNSTO_LINUX_CONFIG_DIR:-/etc/ddnsto}
    ddnsto_privileged test ! -L "$state_dir" && ddnsto_privileged test ! -L "$state_target" || exit 2
    state_temp=$(ddnsto_privileged mktemp "$state_dir/.installer-state.XXXXXX") || exit $?
    trap 'ddnsto_privileged rm -f "$state_temp"' EXIT
    printf 'ddnsto-linux-v1\n%s\n%s\n' "${DDNSTO_BIN_PATH:-/usr/local/bin/ddnsto}" "$state_dir/ddnsto-config.json" |
        ddnsto_privileged tee "$state_temp" >/dev/null || exit $?
    ddnsto_privileged chmod 0644 "$state_temp" || exit $?
    ddnsto_privileged mv -f "$state_temp" "$state_target"
)

# One machine-wide lock, independent of bootstrap cache and client version.
# The callback gets its own shell so its transaction traps cannot replace the
# lock owner's EXIT trap. Do not call this function from a conditional: callbacks
# rely on errexit to stop at the first failed installation command.
ddnsto_with_operation_lock() {
    set -e
    SUDO=
    if [ "$(id -u)" != 0 ]; then
        [ "${business_platform:-${detected_platform:-linux}}" != openwrt ] || {
            ddnsto_error 'OpenWrt changes require root'; exit 2;
        }
        command -v sudo >/dev/null 2>&1 || { ddnsto_error 'service changes require root or sudo'; exit 2; }
        SUDO=sudo
        sudo -v || exit 2
    fi
    operation_lock=${DDNSTO_LOCK_DIR:-/var/lock/ddnsto-installer.lock}
    case "$operation_lock" in /*) ;; *) ddnsto_error 'operation lock path must be absolute'; exit 2 ;; esac
    # No mkdir -p, no following existing links, and no stale-lock auto-removal.
    if ! ddnsto_privileged mkdir -m 700 "$operation_lock" 2>/dev/null; then
        ddnsto_error 'operation lock unavailable: another action may be active; check permissions or stale lock only after confirming no installer is running'
        exit 16
    fi
    trap 'lock_code=$?; trap - EXIT HUP INT TERM; ddnsto_privileged rmdir "$operation_lock" || { ddnsto_error "could not release operation lock"; [ "$lock_code" != 0 ] || lock_code=16; }; exit "$lock_code"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    ( "$@" )
    lock_code=0
    ddnsto_privileged rmdir "$operation_lock" || { ddnsto_error 'could not release operation lock'; lock_code=16; }
    trap - EXIT HUP INT TERM
    return "$lock_code"
}

ddnsto_openwrt() {
    SUDO=
    [ "$(id -u)" = 0 ] || { ddnsto_error 'OpenWrt installation requires root'; return 2; }
    binary=${DDNSTO_OPENWRT_BIN_PATH:-/usr/sbin/ddnstod}
    config=${DDNSTO_CONFIG_PATH:-/etc/config/ddnsto}
    service_path=${DDNSTO_SERVICE_PATH:-/etc/init.d/ddnsto}
    ow_retained_marker=${config%/*}/.uninstalled-openwrt-v1
    for ow_path in "$binary" "$config" "$service_path" "$ow_retained_marker"; do
        ddnsto_ow_safe_path "$ow_path" || { ddnsto_error 'unsafe OpenWrt installation path'; return 2; }
    done
    ow_preserve_config=0
    if [ -e "$config" ]; then
        [ -f "$config" ] || { ddnsto_error 'regular UCI config required'; return 2; }
        if [ -e "$ow_retained_marker" ]; then
            ddnsto_openwrt_retained_state_valid || { ddnsto_error 'unrecognized retained OpenWrt marker'; return 2; }
        else
            ddnsto_ow_owned "$config" || { ddnsto_error 'OpenWrt configuration ownership unavailable; migration refused'; return 2; }
        fi
        ow_preserve_config=1
    elif [ "$ACTION" = update ] || [ -e "$binary" ] || [ -e "$service_path" ] || [ -e "$ow_retained_marker" ]; then
        ddnsto_error 'incomplete or unrecognized OpenWrt installation; configuration must be recovered first'; return 2
    fi
    case "$package_manager" in opkg) pkg_ext=ipk ;; apk) pkg_ext=apk ;; *) ddnsto_error 'OpenWrt requires opkg or apk'; return 2 ;; esac
    if [ "$ow_preserve_config" = 0 ]; then
        ow_packages=$(ddnsto_ow_packages) || { ddnsto_error 'package metadata unavailable'; return 2; }
        if ddnsto_ow_has_package ddnsto; then
            ddnsto_error 'registered DDNSTO package has no managed configuration; external migration refused'; return 2
        fi
    fi
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
    version_num=$(ddnsto_pinned_version "$SELECTED_VERSION") || return $?
    version_folder=$SELECTED_VERSION
    [ "$pkg_ext" != apk ] || version_folder="$version_folder-apk"
    relative_folder="openwrt/$version_folder/$version_num"
    status "      DDNSTO $version_num ($SELECTED_VERSION; Lite below 900 MB)"
    status '[3/4] Downloading and verifying DDNSTO packages...'
    package_cache="$work_dir/cache/$version_folder/$version_num/$arch"
    mkdir -p "$package_cache" || return $?
    main_package="ddnsto_$package_arch.$pkg_ext"
    ui_package="luci-app-ddnsto.$pkg_ext"
    language_package="luci-i18n-ddnsto-zh-cn.$pkg_ext"
    for package in "$main_package" "$ui_package" "$language_package"; do
        case "$package" in
            ddnsto_*) product_path="$relative_folder/$package" ;;
            *) product_path="openwrt/$package" ;;
        esac
        digest=$(ddnsto_pinned_sha "$product_path") || return $?
        ddnsto_verified_download "$product_path" "$package_cache/$package" "$digest" || return $?
    done
    status '[4/4] Installing DDNSTO packages...'
    # All packages are verified before touching dependencies or installed packages.
    # Package-only callback: the retention wrapper disables UCI and stops the
    # old service before hooks run. Explicit errors work even in conditionals.
    ddnsto_openwrt_install_packages() {
        if [ "$package_manager" = opkg ]; then
            if [ -f /www/luci-static/resources/luci.js ] && [ ! -f /usr/lib/lua/luci/cbi.lua ]; then
                opkg update && opkg install luci-compat || return $?
            fi
            if ! opkg list-installed | grep -q '^luci-lua-runtime '; then
                opkg update && opkg install luci-lua-runtime || return $?
            fi
        else
            if [ -f /www/luci-static/resources/luci.js ] && [ ! -f /usr/lib/lua/luci/cbi.lua ]; then
                apk update && apk add luci-compat || return $?
            fi
            if ! apk info -e luci-lua-runtime >/dev/null 2>&1; then
                apk update && apk add luci-lua-runtime || return $?
            fi
        fi
        ow_packages=$(ddnsto_ow_packages) || return 2
        set --
        for package in app-meta-ddnsto luci-i18n-ddnsto-zh-cn luci-app-ddnsto ddnsto; do
            if ddnsto_ow_has_package "$package"; then set -- "$@" "$package"; fi
        done
        if [ "$#" -gt 0 ]; then
            if [ "$package_manager" = opkg ]; then opkg remove "$@" || return $?
            else apk del "$@" || return $?; fi
        fi
        for package in "$main_package" "$ui_package" "$language_package"; do
            if [ "$package_manager" = opkg ]; then opkg install "$package_cache/$package" || return $?
            else apk add --allow-untrusted "$package_cache/$package" || return $?; fi
        done
    }
    if [ "$ow_preserve_config" = 1 ]; then
        ddnsto_openwrt_with_retained_config ddnsto_openwrt_install_packages || return $?
        ddnsto_openwrt_resume_config || return $?
        if [ -e "$ow_retained_marker" ]; then
            ddnsto_openwrt_retained_state_valid && rm -f "$ow_retained_marker" || {
                ddnsto_error 'reinstall completed but retained marker cleanup failed'; return 15
            }
        fi
    else
        ddnsto_openwrt_install_packages || return $?
        if [ -n "$TOKEN" ]; then
            ( ACTION=configure; ddnsto_openwrt_lifecycle ) || return $?
        else
            status 'DDNSTO: get a token at https://www.ddnsto.com and configure it in LuCI'
        fi
    fi
    "$binary" -v || return $?
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
    [ -n "$TOKEN" ] || [ "$ACTION" = update ] || [ "${RETAINED_CONFIG:-0}" = 1 ] || { ddnsto_error 'empty token'; return 2; }
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
    [ "$ACTION" != update ] || [ "$had_config" = 1 ] || { ddnsto_error 'existing configuration disappeared; refusing update'; return 2; }
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
    set -- "$bin_path" -daemon
    if [ "$ACTION" != update ] && [ "${RETAINED_CONFIG:-0}" != 1 ]; then set -- "$bin_path" -u "$TOKEN" -daemon; fi
    if ddnsto_privileged "$@"; then
        ddnsto_linux_wait_healthy
        ddnsto_privileged chmod 0600 "$linux_config_file"
        ddnsto_privileged chmod 0700 "$linux_config_dir"
        ddnsto_linux_write_state "$linux_config_dir/.installer-linux-v1"
        ddnsto_privileged rm -f "$linux_config_dir/.uninstalled-linux-v1"
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
    device=$("$ZSETUP_BIN" context get device 2>/dev/null) || device=
    ddnsto_detect_platform || return $?
    if [ "$detected_platform" = synology ]; then ddnsto_synology_download; return $?; fi
    ddnsto_select_platform
    ddnsto_validate_platform_options || return $?
    ddnsto_native_conflict_guard || return $?
    ddnsto_existing_policy || return $?
    [ "$INSTALL_SKIPPED" = 0 ] || return 0
    case "$ACTION" in install|update) ;; *) ddnsto_dispatch_local_action; return $? ;; esac
    ddnsto_prepare_token
    ddnsto_with_operation_lock ddnsto_install_locked
}

ddnsto_install_locked() {
    ddnsto_native_conflict_guard || return $?
    # Recheck after acquiring the lock; a competing install may have completed
    # while the user was choosing an action or entering credentials.
    ddnsto_existing_policy </dev/null || return $?
    [ "$INSTALL_SKIPPED" = 0 ] || return 0
    work_dir=${ZSETUP_WORK_DIR:-${WORK_ROOT}/ddnsto}
    mkdir -p "$work_dir"
    chmod 0700 "$work_dir"
    transaction_dir=$(mktemp -d "$work_dir/.transaction.XXXXXX")
    install_candidate=
    backup=
    replacement_started=0
    trap ddnsto_cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [ "$business_platform" = openwrt ]; then ddnsto_openwrt; else ddnsto_linux; fi
    ddnsto_cleanup
    transaction_dir=
    trap - EXIT HUP INT TERM
}

# Read-only, bounded Docker discovery; never changes context or starts an engine.
# A reachable engine is NOT proof of a supported DDNSTO container installation.
ddnsto_probe_docker() (
    command -v docker >/dev/null 2>&1 || { echo cli-unavailable; return; }
    command -v timeout >/dev/null 2>&1 || { echo probe-timeout-unavailable; return; }
    if [ -n "${DOCKER_CONTEXT:-}" ]; then
        endpoint=$(timeout 5 docker context inspect "$DOCKER_CONTEXT" --format '{{.Endpoints.docker.Host}}' 2>/dev/null) || { echo context-unavailable; return; }
    elif [ -n "${DOCKER_HOST:-}" ]; then
        endpoint=$DOCKER_HOST
    else
        endpoint=$(timeout 5 docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null) || { echo context-unavailable; return; }
    fi
    case "$endpoint" in
        unix:///*) socket_path=${endpoint#unix://} ;;
        '') echo context-unavailable; return ;;
        *) echo remote-endpoint; return ;;
    esac
    [ -S "$socket_path" ] || { echo socket-unavailable; return; }
    # Explicit endpoint prevents a context change from redirecting this probe.
    # Clear DOCKER_CONTEXT, which otherwise conflicts with an explicit host.
    unset DOCKER_CONTEXT
    engine=$(timeout 5 docker --host "$endpoint" info --format '{{.OSType}}|{{.Architecture}}|{{.OperatingSystem}}' 2>/dev/null) || { echo engine-unreachable; return; }
    case "$engine" in
        *'Docker Desktop'*) echo desktop-engine-unverified ;;
        linux\|*\|*) echo local-linux-engine ;;
        *) echo unsupported-engine ;;
    esac
)

# Restricted engineering candidate, not a native-device acceptance claim.
# main must embed this source, parse inputs, and hold the shared machine lock
# around ddnsto_docker_lifecycle for every mutating action. No bootstrap needed.
# Inputs: REQUESTED_METHOD=docker, detected_platform=linux, ACTION (default
# install), TOKEN (supplied or prompted only for conflict-free fresh install), DEVICE_NAME, NETWORK (or
# DDNSTO_DOCKER_NETWORK). main resolves TOKEN_FILE into TOKEN; this executor
# never reads TOKEN_FILE. Existing-container operations reject both inputs.
# DDNSTO_DOCKER_STATE_DIR is an engineering override, not a multi-instance API.
# Fresh install only. Same-pin update is a no-op; recreation/upgrade is blocked
# until the published binary's identity persistence has been verified.
# Uninstall retains ALL private state for future validated reinstallation.
# No claim that /ddnsto-config contains every identity input used by this image.

ddnsto_docker_error() { printf 'DDNSTO Docker: %s\n' "$*" >&2; }

ddnsto_docker_cli() (
    unset DOCKER_CONTEXT DOCKER_HOST DOCKER_TLS_VERIFY DOCKER_CERT_PATH
    timeout 120 docker --host "$ddocker_endpoint" "$@"
)

ddnsto_docker_discover() {
    [ "${REQUESTED_METHOD:-}" = docker ] && [ "${detected_platform:-}" = linux ] || {
        ddnsto_docker_error 'explicit Docker on generic Linux is required'; return 2;
    }
    [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || return 2
    for ddocker_nas in /etc/synoinfo.conf /usr/syno /etc/config/uLinux.conf /etc/unraid-version /etc/openwrt_release; do
        [ ! -e "$ddocker_nas" ] || { ddnsto_docker_error 'NAS/OpenWrt networking is not accepted'; return 2; }
    done
    command -v docker >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1 || return 2
    if [ -n "${DOCKER_CONTEXT:-}" ]; then
        ddocker_endpoint=$(timeout 5 docker context inspect "$DOCKER_CONTEXT" --format '{{.Endpoints.docker.Host}}' 2>/dev/null) || return 2
    elif [ -n "${DOCKER_HOST:-}" ]; then
        ddocker_endpoint=$DOCKER_HOST
    else
        ddocker_endpoint=$(timeout 5 docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null) || return 2
    fi
    case "$ddocker_endpoint" in unix:///*) ;; *) ddnsto_docker_error 'local Unix endpoint required'; return 2 ;; esac
    case "$ddocker_endpoint" in *[!a-zA-Z0-9_./:-]*) return 2 ;; esac
    [ -S "${ddocker_endpoint#unix://}" ] || return 2
    ddocker_engine=$(
        unset DOCKER_CONTEXT DOCKER_HOST DOCKER_TLS_VERIFY DOCKER_CERT_PATH
        timeout 5 docker --host "$ddocker_endpoint" info --format '{{.OSType}}|{{.Architecture}}|{{.OperatingSystem}}|{{json .SecurityOptions}}' 2>/dev/null
    ) || return 2
    case "$ddocker_engine" in *Desktop*|*rootless*) ddnsto_docker_error 'Desktop/rootless engine is not accepted'; return 2 ;; esac
    case "$ddocker_engine" in linux\|x86_64\|*\|*|linux\|amd64\|*\|*) ;; *) ddnsto_docker_error 'Linux amd64 engine required'; return 2 ;; esac
    case "${ddocker_engine##*|}" in \[*\]) ;; *) ddnsto_docker_error 'engine security information unavailable'; return 2 ;; esac
    ddocker_image=linkease/ddnsto@sha256:f70d2afbb0da6b21ff8865a4f3d9869775360bfbec1fff03474e5478a702ad30
    ddocker_dir=${DDNSTO_DOCKER_STATE_DIR:-/etc/ddnsto-docker}
    case "$ddocker_dir" in /*) ;; *) return 2 ;; esac
    case "$ddocker_dir" in /|*/|*//*|*/../*|*/./*|*/..|*/.|*[!a-zA-Z0-9_./-]*) return 2 ;; esac
    # Inspect every component without following symlinks, even for fresh state.
    ddocker_component=$ddocker_dir
    while [ "$ddocker_component" != / ]; do
        [ ! -L "$ddocker_component" ] || { ddnsto_docker_error 'symlink state path rejected'; return 2; }
        ddocker_component=${ddocker_component%/*}
        ddocker_component=${ddocker_component:-/}
    done
}

ddnsto_docker_plan() (
    ddnsto_docker_discover || exit $?
    printf '%s\n' 'method=docker candidate=engineering' 'docker_installable=false' \
        'candidate_executor=available production_acceptance=unverified' \
        'network_required=bridge-or-host device_name_required=true' \
        'identity_persistence=unverified installation_performed=false'
)

ddnsto_docker_safe_value() {
    case "$1" in ''|*[!a-zA-Z0-9_-]*|-*) return 2 ;; esac
    [ "${#1}" -le 128 ]
}

ddnsto_docker_prompt_field() (
    exec 3<>/dev/tty
    printf '%s' "$1" >&3
    IFS= read -r ddocker_answer <&3 || exit 2
    printf '%s' "$ddocker_answer"
)

ddnsto_docker_fresh_inputs() {
    if [ -n "${NETWORK:-}" ] && [ -n "${DDNSTO_DOCKER_NETWORK:-}" ] && [ "$NETWORK" != "$DDNSTO_DOCKER_NETWORK" ]; then return 2; fi
    ddocker_network=${NETWORK:-${DDNSTO_DOCKER_NETWORK:-}}
    ddocker_token=${TOKEN:-}; ddocker_name=${DEVICE_NAME:-}
    # Reject invalid supplied fields before collecting any missing input.
    case "$ddocker_network" in ''|bridge|host) ;; *) ddnsto_docker_error 'network must be bridge or host'; return 2 ;; esac
    for ddocker_value in "$ddocker_token" "$ddocker_name"; do
        [ -z "$ddocker_value" ] || ddnsto_docker_safe_value "$ddocker_value" || {
            ddnsto_docker_error 'unsafe Token or device name'; return 2;
        }
    done
    if [ -z "$ddocker_token" ] && [ -n "${TOKEN_FILE:-}" ]; then
        ddnsto_docker_error 'Token file must be resolved by the entrypoint'; return 2
    fi
    if [ -z "$ddocker_token" ] || [ -z "$ddocker_name" ] || [ -z "$ddocker_network" ]; then
        [ -t 0 ] || {
            ddnsto_docker_error 'noninteractive fresh install requires Token, device name and explicit bridge or host network'; return 2;
        }
    fi
    if [ -z "$ddocker_token" ]; then
        ddocker_token=$(ddnsto_prompt_token) || { ddnsto_docker_error 'could not read Token'; return 2; }
    fi
    ddnsto_docker_safe_value "$ddocker_token" || { ddnsto_docker_error 'empty or unsafe Token'; return 2; }
    if [ -z "$ddocker_name" ]; then
        ddocker_name=$(ddnsto_docker_prompt_field 'Docker device name: ') || return 2
    fi
    ddnsto_docker_safe_value "$ddocker_name" || { ddnsto_docker_error 'empty or unsafe device name'; return 2; }
    if [ -z "$ddocker_network" ]; then
        ddocker_network=$(ddnsto_docker_prompt_field 'Docker network [bridge/host]: ') || return 2
    fi
    case "$ddocker_network" in bridge|host) ;; *) ddnsto_docker_error 'network must be bridge or host'; return 2 ;; esac
}

ddnsto_docker_private_file() {
    [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -c '%u:%a:%h' "$1")" = "$(id -u):600:1" ]
}

ddnsto_docker_load() {
    [ -d "$ddocker_dir" ] && [ "$(stat -c '%u:%a' "$ddocker_dir")" = "$(id -u):700" ] || return 2
    for ddocker_file in container.env endpoint network image-id container-id; do
        ddnsto_docker_private_file "$ddocker_dir/$ddocker_file" || return 2
    done
    [ -d "$ddocker_dir/identity" ] && [ ! -L "$ddocker_dir/identity" ] || return 2
    [ "$(stat -c '%u:%a' "$ddocker_dir/identity")" = "$(id -u):700" ] || return 2
    [ "$(cat "$ddocker_dir/endpoint")" = "$ddocker_endpoint" ] || return 2
    ddocker_network=$(cat "$ddocker_dir/network")
    case "$ddocker_network" in bridge|host) ;; *) return 2 ;; esac
    ddocker_image_id=$(cat "$ddocker_dir/image-id")
    case "$ddocker_image_id" in sha256:*) ;; *) return 2 ;; esac
    [ "${#ddocker_image_id}" = 71 ] || return 2
    case "${ddocker_image_id#sha256:}" in *[!a-f0-9]*) return 2 ;; esac
    # Parse data, never source the env file. Reject extra keys and line changes.
    ddocker_token= ddocker_name=
    while IFS= read -r ddocker_line; do
        case "$ddocker_line" in
            TOKEN=*) [ -z "$ddocker_token" ] || return 2; ddocker_token=${ddocker_line#TOKEN=} ;;
            DEVICE_NAME=*) [ -z "$ddocker_name" ] || return 2; ddocker_name=${ddocker_line#DEVICE_NAME=} ;;
            *) return 2 ;;
        esac
    done < "$ddocker_dir/container.env"
    ddnsto_docker_safe_value "$ddocker_token" && ddnsto_docker_safe_value "$ddocker_name" || return 2
    printf 'TOKEN=%s\nDEVICE_NAME=%s\n' "$ddocker_token" "$ddocker_name" | cmp -s - "$ddocker_dir/container.env" || return 2
    ddocker_recorded_id=$(cat "$ddocker_dir/container-id")
    [ "$ddocker_recorded_id" = "$ddocker_id" ] || return 2
}

ddnsto_docker_expected() {
    printf '%s\n' "image=$ddocker_image" "imageid=$ddocker_image_id" \
        'name=/ddnsto-managed' "network=$ddocker_network" "attached_network=$ddocker_network" 'restart=unless-stopped' \
        'user=' 'privileged=false' 'cmd=["/usr/bin/ddnsto-monitor.sh"]' 'entrypoint=null' \
        'readonly=false' 'pid=' 'ipc=private' 'caps=0|0' 'security=0' 'devices=0' 'ports=0' \
        'groups=0' 'volumesfrom=0' 'device_requests=0' 'network_links=0' \
        "mount=bind|$ddocker_dir/identity|/ddnsto-config|true|rprivate" \
        'env=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
        'env=TZ=Asia/Shanghai' 'env=LOG_LEVEL=2' "env=TOKEN=$ddocker_token" \
        "env=DEVICE_NAME=$ddocker_name" 'label=io.ddnsto.installer=docker-candidate-v1' \
        "label=io.ddnsto.state=$ddocker_dir" 'label=maintainer=Janson <janson@linkease.com>'
}

ddnsto_docker_owned() {
    # Compare the complete allowlisted env/labels/mounts and execution settings.
    # Never echo inspect output: it contains credentials.
    ddocker_actual=$(ddnsto_docker_cli inspect --format 'image={{.Config.Image}}
imageid={{.Image}}
name={{.Name}}
network={{.HostConfig.NetworkMode}}
{{range $k,$v := .NetworkSettings.Networks}}attached_network={{$k}}
{{end}}restart={{.HostConfig.RestartPolicy.Name}}
user={{.Config.User}}
privileged={{.HostConfig.Privileged}}
cmd={{json .Config.Cmd}}
entrypoint={{json .Config.Entrypoint}}
readonly={{.HostConfig.ReadonlyRootfs}}
pid={{.HostConfig.PidMode}}
ipc={{.HostConfig.IpcMode}}
caps={{len .HostConfig.CapAdd}}|{{len .HostConfig.CapDrop}}
security={{len .HostConfig.SecurityOpt}}
devices={{len .HostConfig.Devices}}
ports={{len .HostConfig.PortBindings}}
groups={{len .HostConfig.GroupAdd}}
volumesfrom={{len .HostConfig.VolumesFrom}}
device_requests={{len .HostConfig.DeviceRequests}}
network_links={{len .HostConfig.Links}}
{{range .Mounts}}mount={{.Type}}|{{.Source}}|{{.Destination}}|{{.RW}}|{{.Propagation}}
{{end}}{{range .Config.Env}}env={{.}}
{{end}}{{range $k,$v := .Config.Labels}}label={{$k}}={{$v}}
{{end}}' "$ddocker_id" 2>/dev/null) || return 2
    ddocker_actual=$(printf '%s\n' "$ddocker_actual" | LC_ALL=C sort)
    ddocker_expected=$(ddnsto_docker_expected | LC_ALL=C sort)
    [ "$ddocker_actual" = "$ddocker_expected" ] || {
        ddnsto_docker_error 'container ownership/configuration mismatch; no changes made'; return 2;
    }
}

ddnsto_docker_report() {
    ddocker_running=$(ddnsto_docker_cli inspect --format '{{.State.Running}}' "$ddocker_id" 2>/dev/null) || return 2
    case "$ddocker_running" in true|false) ;; *) return 2 ;; esac
    printf 'operation=%s container_running=%s client_process=unverified cloud_status=unverified identity_persistence=unverified\n' "$1" "$ddocker_running"
}

ddnsto_docker_lifecycle() (
    # Disable tracing before reading private state or resolving Token arguments.
    set +x
    umask 077
    ACTION=${ACTION:-install}
    case "$ACTION" in install|update|status|start|stop|restart|uninstall|repair) ;; *) ddnsto_docker_error 'unsupported Docker action'; exit 2 ;; esac
    if [ "$ACTION" != status ] && [ "$(id -u)" != 0 ]; then
        ddnsto_docker_error 'Docker write actions require a root shell: run sudo -i, then rerun the installer in that shell. Elevating only the operation lock is insufficient.'
        exit 2
    fi
    ddnsto_docker_discover || exit $?
    [ -z "${DEVICE_IDX:-}${PUID:-}${PGID:-}${SUPPLIER_CODE:-}${FORCE_VERSION:-}" ] && [ "${VERIFY_STATUS:-0}" = 0 ] || {
        ddnsto_docker_error 'unsupported Docker fields'; exit 2;
    }
    for ddocker_native in "${DDNSTO_BIN_PATH:-/usr/local/bin/ddnsto}" "${DDNSTO_LINUX_CONFIG_DIR:-/etc/ddnsto}"; do
        [ ! -e "$ddocker_native" ] && [ ! -L "$ddocker_native" ] || { ddnsto_docker_error 'native installation conflict'; exit 2; }
    done
    # Query success is mandatory: an inaccessible engine is never an empty host.
    ddocker_id=$(ddnsto_docker_cli ps -a --no-trunc --filter 'name=^/ddnsto-managed$' --format '{{.ID}}' 2>/dev/null) || exit 2
    ddocker_labeled=$(ddnsto_docker_cli ps -a --no-trunc --filter 'label=io.ddnsto.installer=docker-candidate-v1' --format '{{.ID}}' 2>/dev/null) || exit 2
    [ "$ddocker_labeled" = "$ddocker_id" ] || { ddnsto_docker_error 'conflicting or renamed managed container'; exit 2; }
    if [ -n "$ddocker_id" ]; then
        case "$ddocker_id" in *[!a-f0-9]*) exit 2 ;; esac
        [ "${#ddocker_id}" = 64 ] || exit 2
        [ -z "${TOKEN:-}${TOKEN_FILE:-}${DEVICE_NAME:-}${NETWORK:-}${DDNSTO_DOCKER_NETWORK:-}" ] || {
            ddnsto_docker_error 'existing installation preserves credentials and networking'; exit 2;
        }
        ddnsto_docker_load && ddnsto_docker_owned || exit 2
        case "$ACTION" in
            install|update)
                printf '%s\n' 'operation=none installation=existing version=4.2.6 cloud_status=unverified' \
                    'identity_persistence=unverified replacement_update=blocked'
                exit 0 ;;
            status) ddnsto_docker_report status; exit $? ;;
            uninstall)
                ddnsto_docker_cli stop "$ddocker_id" >/dev/null 2>&1 || exit 13
                ddocker_running=$(ddnsto_docker_cli inspect --format '{{.State.Running}}' "$ddocker_id" 2>/dev/null) || exit 13
                [ "$ddocker_running" = false ] || exit 13
                ddnsto_docker_cli rm "$ddocker_id" >/dev/null 2>&1 || exit 13
                printf '%s\n' 'operation=uninstall state=retained cloud_status=unverified reinstall=blocked-identity-unverified'
                exit 0 ;;
            repair) ddocker_command=start ;;
            *) ddocker_command=$ACTION ;;
        esac
        ddnsto_docker_cli "$ddocker_command" "$ddocker_id" >/dev/null 2>&1 || { ddnsto_docker_error 'container operation failed; retained state'; exit 13; }
        ddnsto_docker_report "$ACTION" || exit $?
        if [ "$ACTION" = stop ]; then [ "$ddocker_running" = false ] || exit 13
        else [ "$ddocker_running" = true ] || exit 13; fi
        exit 0
    fi
    [ ! -e "$ddocker_dir" ] || { ddnsto_docker_error 'retained/incomplete state: recreation blocked until identity persistence is verified'; exit 2; }
    [ "$ACTION" = install ] || { ddnsto_docker_error 'no managed container'; exit 2; }
    # Only this proven-fresh branch may collect interactive inputs.
    ddnsto_docker_fresh_inputs || exit $?
    ddnsto_docker_cli pull --platform linux/amd64 "$ddocker_image" >/dev/null 2>&1 || { ddnsto_docker_error 'pinned image pull failed'; exit 11; }
    ddocker_image_id=$(ddnsto_docker_cli image inspect --format '{{.Id}}' "$ddocker_image" 2>/dev/null) || exit 11
    case "$ddocker_image_id" in sha256:*) ;; *) exit 11 ;; esac
    [ "${#ddocker_image_id}" = 71 ] || exit 11
    case "${ddocker_image_id#sha256:}" in *[!a-f0-9]*) exit 11 ;; esac
    # Atomic exclusive directory creation. A partial transaction is deliberately
    # retained and refused on rerun; never guess whether engine creation succeeded.
    mkdir -m 700 "$ddocker_dir" || exit 2
    mkdir -m 700 "$ddocker_dir/identity" || exit 2
    printf 'TOKEN=%s\nDEVICE_NAME=%s\n' "$ddocker_token" "$ddocker_name" > "$ddocker_dir/container.env" || exit 2
    printf '%s\n' "$ddocker_endpoint" > "$ddocker_dir/endpoint" || exit 2
    printf '%s\n' "$ddocker_network" > "$ddocker_dir/network" || exit 2
    printf '%s\n' "$ddocker_image_id" > "$ddocker_dir/image-id" || exit 2
    ddocker_id=$(ddnsto_docker_cli create --name ddnsto-managed --platform linux/amd64 \
        --network "$ddocker_network" --restart unless-stopped \
        --label io.ddnsto.installer=docker-candidate-v1 --label "io.ddnsto.state=$ddocker_dir" \
        --env-file "$ddocker_dir/container.env" \
        --mount "type=bind,src=$ddocker_dir/identity,dst=/ddnsto-config" "$ddocker_image" 2>/dev/null) || {
        ddnsto_docker_error 'container creation failed; private state retained'; exit 13;
    }
    case "$ddocker_id" in ''|*[!a-f0-9]*) exit 13 ;; esac
    [ "${#ddocker_id}" = 64 ] || exit 13
    printf '%s\n' "$ddocker_id" > "$ddocker_dir/container-id" || exit 13
    ddnsto_docker_owned || exit 2
    ddnsto_docker_cli start "$ddocker_id" >/dev/null 2>&1 || { ddnsto_docker_error 'start failed; container/state retained for explicit repair'; exit 13; }
    ddnsto_docker_report install || exit $?
    [ "$ddocker_running" = true ] || exit 13
)

# Only offer Docker for a fresh generic Linux host and a verified local engine.
ddnsto_method_interactive() { [ -t 0 ]; }

ddnsto_choose_method() (
    exec 3<>/dev/tty || exit 2
    printf '%s\n' 'A local Linux amd64 Docker engine is available.' \
        '0) Native installation (default)' \
        '1) Experimental Docker: identity persistence and replacement upgrades are NOT accepted yet.' >&3
    printf 'Installation method [0]: ' >&3
    IFS= read -r method_choice <&3 || method_choice=
    case "$method_choice" in ''|0) printf native ;; 1) printf docker ;; *) exit 2 ;; esac
)

ddnsto_offer_install_method() {
    [ "$detected_platform" = linux ] || return 0
    [ "$REQUESTED_METHOD" != docker ] || return 0
    docker_state=${DDNSTO_DOCKER_STATE_DIR:-/etc/ddnsto-docker}
    if [ -e "$docker_state" ] || [ -L "$docker_state" ]; then
        ddnsto_error 'Docker state exists; use --method docker explicitly. Native/container migration is not supported.'
        return 2
    fi
    [ "$REQUESTED_METHOD" = auto ] && [ "$ACTION" = install ] || return 0
    ddnsto_method_interactive || return 0
    for native_path in "${DDNSTO_BIN_PATH:-/usr/local/bin/ddnsto}" "${DDNSTO_LINUX_CONFIG_DIR:-/etc/ddnsto}"; do
        [ ! -e "$native_path" ] && [ ! -L "$native_path" ] || return 0
    done
    (REQUESTED_METHOD=docker; ddnsto_docker_discover >/dev/null 2>&1) || return 0
    method_choice=$(ddnsto_choose_method) || { ddnsto_error 'invalid method selection'; return 2; }
    case "$method_choice" in native) ;; docker) REQUESTED_METHOD=docker ;; *) return 2 ;; esac
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
    [ "${1:-}" != management ] || return 0
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

# Only the installer owns these actions. Never infer ownership from a filename.
ddnsto_linux_unit_exists() {
    case "$linux_service_manager" in
        systemd)
            unit_load=$(ddnsto_privileged systemctl show --property=LoadState --value "$linux_service_name") || return 2
            case "$unit_load" in loaded) return 0 ;; not-found) return 1 ;; *) return 2 ;; esac ;;
        openrc) ddnsto_privileged rc-service --exists "$linux_service_name" ;;
    esac
}

ddnsto_linux_unit_path() {
    printf '/etc/systemd/system/%s.service\n' "$linux_service_name"
}

ddnsto_linux_unit_environment_path() {
    printf '/etc/sysconfig/%s\n' "$linux_service_name"
}

ddnsto_linux_lifecycle_stopped() (
    active_state=$(ddnsto_privileged systemctl show --property=ActiveState --value "$linux_service_name") || exit 2
    case "$active_state" in inactive|failed) exit 0 ;; active) exit 1 ;; *) exit 2 ;; esac
)

ddnsto_linux_lifecycle_safe_path() (
    # Do not follow a symlink in any component, including a dangling leaf.
    case "$1" in /*) ;; *) exit 2 ;; esac
    checked_path=$1
    while [ "$checked_path" != / ]; do
        ddnsto_privileged test ! -L "$checked_path" || exit 2
        checked_path=$(dirname "$checked_path")
    done
)

ddnsto_linux_lifecycle_file_target() {
    ddnsto_linux_lifecycle_safe_path "$1" || return 2
    # cp treats a directory destination as a container; that is never recovery.
    if ddnsto_privileged test -e "$1"; then ddnsto_privileged test -f "$1" || return 2; fi
}

ddnsto_linux_unit_owned() (
    # The old marker records binary/config paths, NOT ownership of a unit.
    # Validate the effective systemd command, its backing file, and overrides.
    ddnsto_linux_lifecycle_safe_path "$unit_path" || exit 2
    ddnsto_privileged test -f "$unit_path" || exit 2
    fragment=$(ddnsto_privileged systemctl show --property=FragmentPath --value "$linux_service_name") || exit 2
    [ "$fragment" = "$unit_path" ] || exit 2
    definition=$(ddnsto_privileged cat "$unit_path") || exit 2
    starts=0 section=
    while IFS= read -r line; do
        case "$line" in
            '['*']') section=$line ;;
            ExecStart=*)
                [ "$section" = '[Service]' ] || exit 2
                case "$line" in
                    "ExecStart=$bin_path run"|"ExecStart=$bin_path \"run\""|"ExecStart=\"$bin_path\" \"run\""|"ExecStart=\"$bin_path\" run") ;;
                    *) exit 2 ;;
                esac
                starts=$((starts + 1)) ;;
        esac
    done <<EOF
$definition
EOF
    [ "$starts" = 1 ] || exit 2
    reload=$(ddnsto_privileged systemctl show --property=NeedDaemonReload --value "$linux_service_name") || exit 2
    [ "$reload" = no ] || exit 2
    for property in DropInPaths ExecCondition ExecStartPre ExecStartPost ExecStop ExecStopPost ExecReload RootDirectory RootImage Environment User Group WorkingDirectory; do
        value=$(ddnsto_privileged systemctl show "--property=$property" --value "$linux_service_name") || exit 2
        [ -z "$value" ] || exit 2
    done
    environment_files=$(ddnsto_privileged systemctl show --property=EnvironmentFiles --value "$linux_service_name") || exit 2
    if [ -n "$environment_files" ]; then
        optional_environment=$(ddnsto_linux_unit_environment_path) || exit 2
        [ "$environment_files" = "$optional_environment (ignore_errors=yes)" ] || exit 2
        # kardianos/service v1.2.2 always declares this optional file. Only its
        # absence is safe without authenticating arbitrary environment settings.
        ddnsto_linux_lifecycle_safe_path "$optional_environment" || exit 2
        ddnsto_privileged test ! -e "$optional_environment" || exit 2
    fi
    execution=$(ddnsto_privileged systemctl show --property=ExecStart --value "$linux_service_name") || exit 2
    case "$execution" in
        "{ path=$bin_path ; argv[]=$bin_path run ; ignore_errors=no ; "*' }') ;;
        *) exit 2 ;;
    esac
    # Multiple ExecStart entries must not be mistaken for a single owned command.
    [ -z "${execution#*\}}" ] || exit 2
)

ddnsto_linux_lifecycle_restore() {
    # Called from a conditional trap: check every operation explicitly.
    ddnsto_linux_lifecycle_file_target "$unit_path" || return 1
    if ! ddnsto_privileged test -e "$unit_path"; then
        # A legacy uninstaller may have removed the file without daemon-reload.
        ddnsto_privileged systemctl daemon-reload || return 1
    fi
    restore_unit_rc=0
    ddnsto_linux_unit_exists || restore_unit_rc=$?
    case "$restore_unit_rc" in
        0)
            ddnsto_linux_unit_owned || return 1
            ddnsto_linux_stop >/dev/null 2>&1 || return 1
            ddnsto_linux_lifecycle_stopped || return 1 ;;
        1) ddnsto_linux_lifecycle_stopped || return 1 ;;
        *) return 1 ;;
    esac
    ddnsto_linux_lifecycle_file_target "$linux_config_file" || return 1
    ddnsto_linux_lifecycle_file_target "$bin_path" || return 1
    ddnsto_privileged cp -p "$lifecycle_backup/config" "$linux_config_file" || return 1
    ddnsto_privileged cp -p "$lifecycle_backup/binary" "$bin_path" || return 1
    if [ "$unit_present" = 1 ]; then
        ddnsto_privileged cp -p "$lifecycle_backup/unit" "$unit_path" || return 1
        ddnsto_privileged systemctl daemon-reload || return 1
        case "$unit_enabled" in
            enabled) ddnsto_privileged systemctl enable "$linux_service_name" >/dev/null 2>&1 || return 1 ;;
            disabled) ddnsto_privileged systemctl disable "$linux_service_name" >/dev/null 2>&1 || return 1 ;;
        esac
        if [ "$was_running" = 1 ]; then
            ddnsto_privileged systemctl start "$linux_service_name" || return 1
            ddnsto_linux_wait_healthy || return 1
        fi
    elif [ "$restore_unit_rc" = 0 ]; then
        ddnsto_privileged systemctl disable "$linux_service_name" >/dev/null 2>&1 || return 1
        ddnsto_privileged rm -f "$unit_path" || return 1
        ddnsto_privileged systemctl daemon-reload || return 1
    fi
    ddnsto_linux_lifecycle_file_target "$managed" || return 1
    ddnsto_linux_lifecycle_file_target "$retained" || return 1
    ddnsto_privileged cp -p "$lifecycle_backup/managed" "$managed" || return 1
    ddnsto_privileged rm -f "$retained" || return 1
}

ddnsto_linux_lifecycle() (
    set -e
    ddnsto_linux_preflight
    case "$ACTION" in repair|configure|uninstall) ;; *) exit 2 ;; esac
    # OpenRC definitions are executable shell scripts. The legacy marker cannot
    # authenticate them; refuse rather than execute/delete a same-named script.
    [ "$linux_service_manager" = systemd ] || {
        ddnsto_error 'Linux lifecycle requires verifiable systemd ownership; OpenRC lifecycle is not supported'; exit 2;
    }
    bin_path=${DDNSTO_BIN_PATH:-/usr/local/bin/ddnsto}
    managed="$linux_config_dir/.installer-linux-v1"
    retained="$linux_config_dir/.uninstalled-linux-v1"
    unit_path=$(ddnsto_linux_unit_path)
    for path in "$bin_path" "$linux_config_file" "$managed" "$retained" "$unit_path"; do
        ddnsto_linux_lifecycle_safe_path "$path" || exit 2
    done
    if [ "$ACTION" = uninstall ] && ddnsto_linux_state_valid "$retained" &&
       ! ddnsto_privileged test -e "$bin_path" && ! ddnsto_privileged test -L "$bin_path"; then
        ddnsto_privileged test -f "$linux_config_file" && ddnsto_privileged test ! -L "$linux_config_file" || exit 2
        ddnsto_privileged test ! -e "$managed" || exit 2
        unit_rc=0
        ddnsto_linux_unit_exists || unit_rc=$?
        [ "$unit_rc" = 1 ] && ddnsto_privileged test ! -e "$unit_path" || {
            ddnsto_error 'retained installation has an unexpected service or unknown service state'; exit 2;
        }
        ddnsto_linux_lifecycle_stopped || { ddnsto_error 'retained service is not confirmed stopped'; exit 2; }
        printf '%s\n' 'operation=none installation=uninstalled config=retained cloud_status=unverified'
        exit 0
    fi
    ddnsto_linux_state_valid "$managed" || {
        ddnsto_error 'managed Linux installation required; use an explicit reviewed update to register an older installation first'; exit 2;
    }
    for path in "$bin_path" "$linux_config_file"; do
        ddnsto_privileged test -f "$path" && ddnsto_privileged test ! -L "$path" || exit 2
    done
    ddnsto_privileged test ! -e "$retained" || { ddnsto_error 'conflicting lifecycle markers; manual recovery required'; exit 2; }
    if [ "$ACTION" = configure ]; then
        [ -n "$TOKEN" ] || { TOKEN=$(ddnsto_prompt_token) || exit 2; }
        [ -n "$TOKEN" ] || { ddnsto_error 'configure requires a nonempty Token'; exit 2; }
        command -v jq >/dev/null 2>&1 || { ddnsto_error 'Linux configure requires jq to preserve all JSON configuration fields'; exit 2; }
    fi
    unit_present=1
    unit_rc=0
    ddnsto_linux_unit_exists || unit_rc=$?
    case "$unit_rc" in 0) ;; 1) unit_present=0 ;; *) ddnsto_error 'cannot determine service ownership/state'; exit 2 ;; esac
    unit_enabled=disabled
    if [ "$unit_present" = 1 ]; then
        ddnsto_linux_unit_owned || { ddnsto_error 'service does not belong to this managed installation'; exit 2; }
        unit_enabled=$(ddnsto_privileged systemctl is-enabled "$linux_service_name") || [ "$unit_enabled" = disabled ] || exit 2
        case "$unit_enabled" in enabled|disabled) ;; *) ddnsto_error 'unsupported service enablement state'; exit 2 ;; esac
    else
        ddnsto_privileged test ! -e "$unit_path" || exit 2
    fi
    was_running=0
    active_state=$(ddnsto_privileged systemctl show --property=ActiveState --value "$linux_service_name") || exit 2
    case "$active_state" in
        active) [ "$unit_present" = 1 ] || exit 2; was_running=1 ;;
        inactive|failed) ;;
        *) ddnsto_error 'unknown or transitioning service state'; exit 2 ;;
    esac
    lifecycle_backup=$(ddnsto_privileged mktemp -d "$linux_config_dir/.lifecycle.XXXXXX")
    changed=0 keep_backup=0 lifecycle_success=
    lifecycle_cleanup() {
        lifecycle_code=$?
        trap - EXIT HUP INT TERM
        if [ "$changed" = 1 ]; then
            ddnsto_linux_lifecycle_restore || keep_backup=1
            [ "$lifecycle_code" != 0 ] || lifecycle_code=1
        fi
        if [ "$keep_backup" = 1 ]; then
            ddnsto_error "recovery incomplete; inspect service and retained backup: $lifecycle_backup"
        else
            ddnsto_privileged rm -rf "$lifecycle_backup" || {
                lifecycle_code=1
                ddnsto_error "backup cleanup failed: $lifecycle_backup"
            }
        fi
        if [ "$lifecycle_code" = 0 ] && [ -n "$lifecycle_success" ]; then printf '%s\n' "$lifecycle_success"; fi
        exit "$lifecycle_code"
    }
    trap lifecycle_cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    ddnsto_privileged cp -p "$linux_config_file" "$lifecycle_backup/config"
    ddnsto_privileged cp -p "$bin_path" "$lifecycle_backup/binary"
    ddnsto_privileged cp -p "$managed" "$lifecycle_backup/managed"
    if [ "$unit_present" = 1 ]; then ddnsto_privileged cp -p "$unit_path" "$lifecycle_backup/unit"; fi
    if [ "$ACTION" = configure ]; then
        # Do not log jq's input or the Token; only change the documented field.
        # Capture jq's status directly: a valid prefix followed by invalid JSON
        # must not be accepted just because tee succeeded. Require one object.
        staged_config=$(ddnsto_privileged jq -e -s --arg token "$TOKEN" 'if length == 1 and (.[0] | type == "object" and (.token | type == "string")) then .[0] | .token = $token else error("unsupported configuration") end' "$linux_config_file" 2>/dev/null) || {
            ddnsto_error 'configuration must contain exactly one valid JSON object with a token field'; exit 2;
        }
        printf '%s\n' "$staged_config" | ddnsto_privileged tee "$lifecycle_backup/config-new" >/dev/null
        ddnsto_privileged jq -e 'type == "object" and (.token | type == "string")' "$lifecycle_backup/config-new" >/dev/null || exit 2
    fi
    # Recheck after staging and before the first service mutation.
    if [ "$unit_present" = 1 ]; then
        ddnsto_linux_unit_owned || exit 2
        ddnsto_privileged cmp -s "$unit_path" "$lifecycle_backup/unit" || exit 2
    else
        unit_rc=0
        ddnsto_linux_unit_exists || unit_rc=$?
        [ "$unit_rc" = 1 ] && ddnsto_privileged test ! -e "$unit_path" || exit 2
    fi
    changed=1
    if [ "$unit_present" = 1 ]; then ddnsto_linux_stop; fi
    ddnsto_linux_lifecycle_stopped || { ddnsto_error 'service is not confirmed stopped'; exit 13; }
    if [ "$unit_present" = 1 ]; then
        ddnsto_linux_unit_owned || exit 2
        ddnsto_privileged cmp -s "$unit_path" "$lifecycle_backup/unit" || exit 2
    fi
    for path in "$bin_path" "$linux_config_file" "$managed"; do
        ddnsto_linux_lifecycle_file_target "$path" && ddnsto_privileged test -f "$path" || exit 2
    done
    if [ "$ACTION" = uninstall ]; then
        if [ "$unit_present" = 1 ]; then ddnsto_privileged "$bin_path" uninstall; fi
        ddnsto_linux_lifecycle_safe_path "$unit_path" || exit 2
        ddnsto_privileged test ! -e "$unit_path" || { ddnsto_error 'service definition still exists'; exit 13; }
        ddnsto_privileged systemctl daemon-reload
        unit_rc=0
        ddnsto_linux_unit_exists || unit_rc=$?
        [ "$unit_rc" = 1 ] || { ddnsto_error 'service registration still exists or cannot be verified'; exit 13; }
        # Preserve original bytes even if a legacy client touches config on exit.
        ddnsto_linux_lifecycle_file_target "$linux_config_file" || exit 2
        ddnsto_privileged cp -p "$lifecycle_backup/config" "$linux_config_file"
        ddnsto_privileged rm -f "$bin_path"
        ddnsto_linux_write_state "$retained"
        ddnsto_privileged rm -f "$managed"
        changed=0
        lifecycle_success='operation=uninstall local_service=not-installed config=retained cloud_status=unverified'
    else
        if [ "$ACTION" = configure ]; then
            ddnsto_privileged chmod 0600 "$lifecycle_backup/config-new"
            ddnsto_privileged mv -f "$lifecycle_backup/config-new" "$linux_config_file"
        fi
        if [ "$unit_present" = 1 ]; then
            ddnsto_privileged systemctl enable "$linux_service_name" >/dev/null 2>&1
            ddnsto_privileged systemctl start "$linux_service_name"
        else
            ddnsto_privileged "$bin_path" -daemon >/dev/null 2>&1
            ddnsto_linux_unit_owned || exit 2
        fi
        ddnsto_linux_wait_healthy
        changed=0
        lifecycle_success="operation=$ACTION local_service=healthy cloud_status=unverified"
    fi
)

# Sourced/embedded by main. Caller validates platform/arguments, checks root and
# holds the shared machine lock. This function returns, never exits its caller.
# Inputs: ACTION, TOKEN, package_manager, binary, config, service_path.
# No downloader, package file synthesis, or implicit install/migration here.
# Returns 2 on preflight/config errors, 13 on service failure, 14 when recovery
# needs the retained backup, 15 on incomplete/unverifiable removal; package
# removal failures retain their exit code. Signal exits: 129/130/143.
# Public entries: ddnsto_openwrt_lifecycle and the retained-config wrapper below.
# No marker schema is assumed: lifecycle requires package metadata. Main must
# not treat retained config as an installed native client.
ddnsto_ow_error() { printf 'DDNSTO OpenWrt: %s\n' "$*" >&2; }

ddnsto_ow_safe_path() (
    case "$1" in /*) ;; *) return 1 ;; esac
    case "$1" in /|*/|*//*|*/../*|*/./*|*/..|*/.|*[!a-zA-Z0-9_./-]*) return 1 ;; esac
    ow_path=$1
    while [ "$ow_path" != / ] && [ -n "$ow_path" ]; do
        [ ! -L "$ow_path" ] || return 1
        ow_path=${ow_path%/*}
    done
)

# Read-only state check used by the OpenWrt existing-install policy. Marker
# binds platform/package manager AND all managed paths; it contains no token.
# Root-owned production config directory is the trust boundary, not a basename.
ddnsto_openwrt_retained_state_valid() (
    binary=${DDNSTO_OPENWRT_BIN_PATH:-/usr/sbin/ddnstod}
    config=${DDNSTO_CONFIG_PATH:-/etc/config/ddnsto}
    service_path=${DDNSTO_SERVICE_PATH:-/etc/init.d/ddnsto}
    ow_marker=${config%/*}/.uninstalled-openwrt-v1
    case "${package_manager:-}" in opkg|apk) ;; *) return 1 ;; esac
    for ow_file in "$binary" "$config" "$service_path" "$ow_marker"; do
        ddnsto_ow_safe_path "$ow_file" || return 1
    done
    [ -f "$config" ] && [ -f "$ow_marker" ] || return 1
    ow_expected=$(printf 'ddnsto-openwrt-retained-v1\n%s\n%s\n%s\n%s\n' "$package_manager" "$binary" "$config" "$service_path")
    ow_actual=$(cat "$ow_marker") || return 1
    [ "$ow_expected" = "$ow_actual" ]
)

# Metadata contracts, not basename guesses. opkg search uses fnmatch, hence
# safe_path excludes glob characters. print_pkg emits NAME - VERSION [- DESC].
# https://github.com/openwrt/opkg-lede/blob/master/libopkg/opkg_cmd.c
# APK quiet --who-owns emits exact dependency names (not name-version strings).
# https://github.com/alpinelinux/apk-tools/blob/v2.14.4/src/app_info.c
# https://github.com/alpinelinux/apk-tools/blob/v3.0.0/src/app_info.c
# Unknown CLI output/firmware variants fail closed; these are not integrity
# checks of installed bytes and do not certify third-party package hooks.
ddnsto_ow_owned() (
    if [ "$package_manager" = opkg ]; then
        ow_owner=$(opkg search "$1" 2>/dev/null) || return 1
        case "$ow_owner" in *'
'*) return 1 ;; esac
        case "$ow_owner" in 'ddnsto - '?*) return 0 ;; *) return 1 ;; esac
    else
        ow_owner=$(apk -q info --who-owns "$1" 2>/dev/null) || return 1
        [ "$ow_owner" = ddnsto ]
    fi
)

ddnsto_ow_packages() (
    if [ "$package_manager" = opkg ]; then
        ow_listing=$(opkg list-installed 2>/dev/null) || return 1
        printf '%s\n' "$ow_listing" | while read -r ow_name ow_dash ow_version ow_rest; do
            [ -n "$ow_name" ] || continue
            [ "$ow_dash" = - ] && [ -n "$ow_version" ] || exit 1
            case "$ow_name" in *[!a-zA-Z0-9+_.-]*) exit 1 ;; esac
            printf '%s\n' "$ow_name"
        done
    else
        ow_listing=$(apk info 2>/dev/null) || return 1
        printf '%s\n' "$ow_listing" | while IFS= read -r ow_name; do
            [ -n "$ow_name" ] || continue
            case "$ow_name" in *[!a-zA-Z0-9+_.-]*) exit 1 ;; esac
            printf '%s\n' "$ow_name"
        done
    fi
)

ddnsto_ow_has_package() {
    printf '%s\n' "$ow_packages" | grep -Fqx "$1"
}

ddnsto_ow_restore() {
    ddnsto_ow_safe_path "$config" &&
        { [ ! -e "$config" ] || [ -f "$config" ]; } || return 1
    cp -p "$ow_work/original" "$ow_work/restore" &&
        mv -f "$ow_work/restore" "$config"
}

ddnsto_ow_finish() {
    ow_rc=$?
    trap - 0 HUP INT TERM
    if [ "$ow_dirty" = 1 ]; then
        if ! ddnsto_ow_restore; then
            ddnsto_ow_error "configuration restore failed; backup retained at $ow_work/original"
            exit 14
        fi
        ddnsto_ow_error 'operation failed; configuration restored; service state requires inspection'
    elif [ "$ow_rc" != 0 ]; then
        ddnsto_ow_error 'operation failed; original configuration preserved'
    fi
    rm -f "$ow_work/original" "$ow_work/restore" "$ow_work/marker" "$ow_work/config/ddnsto" "$ow_work/delta/ddnsto"
    rmdir "$ow_work/config" "$ow_work/delta" "$ow_work" 2>/dev/null
    exit "$ow_rc"
}

# Main-only integration seam for reinstall of previously retained configuration.
# Caller holds the machine lock, has validated retained ownership/platform/root,
# and supplies its existing pinned-package install callback. Callback MUST NOT
# explicitly start services or overwrite this wrapper's private backup. Pinned
# package hooks may call start: all checked Standard/Lite IPK/APK init scripts
# gate procd startup on enabled=1, and shipped defaults have enabled=0. Disable
# UCI before hooks, stop the old service, restore only after all hooks complete.
# New product pins must revalidate this init/default-config contract. Runs in a
# subshell, so exports/variables/traps do not propagate back. Output is suppressed
# because package hooks can print credentials. No implicit downloads here.
# Restore completes before return, including callback failure. On return 0 main
# may invoke ACTION=repair with TOKEN empty to enable/start the restored config.
# Wrapper emits no operation-success record. Main owns the full reinstall result.
ddnsto_openwrt_with_retained_config() (
    set +x
    set +e
    umask 077
    [ "$#" -gt 0 ] || { ddnsto_ow_error 'package-only reinstall callback required'; return 2; }
    ddnsto_ow_safe_path "$config" && [ -f "$config" ] && [ "${config##*/}" = ddnsto ] || {
        ddnsto_ow_error 'safe retained UCI configuration required'; return 2
    }
    ow_pending=$(uci -c "${config%/*}" -q changes ddnsto 2>/dev/null) && [ -z "$ow_pending" ] || {
        ddnsto_ow_error 'pending UCI changes or unreadable configuration'; return 2
    }
    for ow_file in "$binary" "$service_path"; do
        ddnsto_ow_safe_path "$ow_file" || return 2
        if [ -e "$ow_file" ]; then
            [ -f "$ow_file" ] && [ -x "$ow_file" ] && ddnsto_ow_owned "$ow_file" || {
                ddnsto_ow_error 'existing program/service is not package owned'; return 2
            }
        fi
    done
    ow_work=$(mktemp -d "${config%/*}/.ddnsto-lifecycle.XXXXXX") || return 2
    ow_dirty=0
    trap ddnsto_ow_finish 0
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    mkdir "$ow_work/config" "$ow_work/delta" || return 2
    cp -p "$config" "$ow_work/original" || return 2
    cp -p "$config" "$ow_work/config/ddnsto" || return 2
    ow_section=$(uci -c "$ow_work/config" -t "$ow_work/delta" -q get 'ddnsto.@ddnsto[0]' 2>/dev/null)
    [ "$ow_section" = ddnsto ] && ! uci -c "$ow_work/config" -t "$ow_work/delta" -q get 'ddnsto.@ddnsto[1]' >/dev/null 2>&1 || {
        ddnsto_ow_error 'exactly one ddnsto UCI section required before package hooks'; return 2
    }
    uci -c "$ow_work/config" -t "$ow_work/delta" -q set 'ddnsto.@ddnsto[0].enabled=0' >/dev/null 2>&1 &&
        uci -c "$ow_work/config" -t "$ow_work/delta" -q commit ddnsto >/dev/null 2>&1 || return 2
    ow_dirty=1
    mv -f "$ow_work/config/ddnsto" "$config" || return 2
    if [ -f "$service_path" ]; then
        "$service_path" stop >/dev/null 2>&1 && ddnsto_ow_wait_service stopped || {
            ddnsto_ow_error 'could not stop existing client; package changes not attempted'; return 13
        }
    fi
    ow_callback_rc=0
    ( "$@" ) >/dev/null 2>&1 || ow_callback_rc=$?
    if ! ddnsto_ow_restore; then
        ddnsto_ow_error 'reinstall may be partial; configuration restore failed'; return 14
    fi
    ow_dirty=0
    if [ "$ow_callback_rc" != 0 ]; then
        ddnsto_ow_error 'reinstall callback failed; packages may be partial; configuration retained'
    fi
    return "$ow_callback_rc"
)

ddnsto_ow_wait_service() {
    ow_attempt=0
    while :; do
        ow_status=0
        "$service_path" status >/dev/null 2>&1 || ow_status=$?
        case "$1:$ow_status" in running:0|stopped:1|stopped:3) return 0 ;; esac
        case "$ow_status" in 0|1|3) ;; *) return 13 ;; esac
        ow_attempt=$((ow_attempt + 1))
        [ "$ow_attempt" -lt 10 ] || return 13
        sleep 1
    done
}

# Resume only after the original UCI bytes have been restored. Disabled installs
# stay disabled; this does not rewrite Token, enabled, index or identity fields.
ddnsto_openwrt_resume_config() (
    set +x
    set +e
    for ow_file in "$binary" "$config" "$service_path"; do
        ddnsto_ow_safe_path "$ow_file" && [ -f "$ow_file" ] && ddnsto_ow_owned "$ow_file" || {
            ddnsto_ow_error 'package installation incomplete; configuration retained'; return 15
        }
    done
    ow_enabled=$(uci -c "${config%/*}" -q get 'ddnsto.@ddnsto[0].enabled' 2>/dev/null) || ow_enabled=0
    case "$ow_enabled" in
        1|on|true|yes|enabled)
            "$service_path" enable >/dev/null 2>&1 && "$service_path" restart >/dev/null 2>&1 &&
                ddnsto_ow_wait_service running || { ddnsto_ow_error 'packages installed; service restart failed; configuration retained'; return 13; }
            ;;
        *)
            "$service_path" disable >/dev/null 2>&1 && "$service_path" stop >/dev/null 2>&1 &&
                ddnsto_ow_wait_service stopped || { ddnsto_ow_error 'packages installed; service stop failed; configuration retained'; return 13; }
            ;;
    esac
)

ddnsto_ow_uninstall() {
    # Client internal/identity/openwrt_uci.go stores index/router_id/mode/UUID
    # in /etc/config/ddnsto. Native /etc/ddnsto state is never deleted here.
    # Package Makefile declares this conffile. Its postinst runs uci-defaults;
    # OpenWrt lib/functions.sh default_prerm disables/stops package init files.
    # Read-only archive inspection (2026-10-21) matched product-pins.sh:
    # standard/4.2.6 x86_64 IPK a7d868da... and APK 470e4ea4... both invoke
    # default_prerm; Lite 4.2.2 and LuCI/language IPKs do likewise. APK's ADB
    # metadata also declares /etc/config/ddnsto. These hooks do not remove
    # additional identity files. This is not validation of every vendor build.
    # Snapshot BEFORE any service/package hooks, restore AFTER all hooks even
    # if removal fails. No --force, autoremove, purge or recursive file deletion.
    set --
    for ow_package in app-meta-ddnsto luci-i18n-ddnsto-zh-cn luci-app-ddnsto ddnsto; do
        if ddnsto_ow_has_package "$ow_package"; then set -- "$@" "$ow_package"; fi
    done
    ow_dirty=1
    if [ -f "$service_path" ]; then
        "$service_path" disable >/dev/null 2>&1 && "$service_path" stop >/dev/null 2>&1 || {
            ddnsto_ow_error 'service stop/disable failed; packages were not removed'; return 13
        }
    fi
    ow_remove_rc=0
    if [ "$package_manager" = opkg ]; then
        opkg remove "$@" >/dev/null 2>&1 || ow_remove_rc=$?
    else
        apk del "$@" >/dev/null 2>&1 || ow_remove_rc=$?
    fi
    if ! ddnsto_ow_restore; then
        ddnsto_ow_error 'uninstall may be partial; configuration restore failed'; return 14
    fi
    ow_dirty=0
    if [ "$ow_remove_rc" != 0 ]; then
        ddnsto_ow_error 'uninstall failed or partial; configuration retained; inspect package state before retry'
        return "$ow_remove_rc"
    fi
    ow_packages=$(ddnsto_ow_packages) || {
        ddnsto_ow_error 'uninstall may be partial; cannot verify remaining packages'; return 15
    }
    for ow_package do
        if ddnsto_ow_has_package "$ow_package"; then
            ddnsto_ow_error 'uninstall partial; requested package remains installed; configuration retained'; return 15
        fi
    done
    # Publish retained ownership only after verified removal and config restore.
    ddnsto_ow_safe_path "$ow_marker" && { [ ! -e "$ow_marker" ] || [ -f "$ow_marker" ]; } || {
        ddnsto_ow_error 'packages removed; configuration retained; marker destination became unsafe'; return 15
    }
    printf 'ddnsto-openwrt-retained-v1\n%s\n%s\n%s\n%s\n' "$package_manager" "$binary" "$config" "$service_path" > "$ow_work/marker" &&
        mv -f "$ow_work/marker" "$ow_marker" || {
        ddnsto_ow_error 'packages removed and configuration retained, but retained marker write failed'; return 15
    }
    printf 'operation=uninstall config=retained identity=retained cloud_status=unverified\n'
}

ddnsto_openwrt_lifecycle() (
    set +x
    set +e
    umask 077
    export LC_ALL=C
    case "${ACTION:-}" in configure|repair|uninstall) ;; *) ddnsto_ow_error 'unsupported lifecycle action'; return 2 ;; esac
    case "${package_manager:-}" in opkg|apk) ;; *) ddnsto_ow_error 'opkg or apk required'; return 2 ;; esac
    [ "${REQUESTED_METHOD:-auto}" != docker ] || { ddnsto_ow_error 'container migration is not supported'; return 2; }
    if [ "$ACTION" = configure ]; then
        case "${TOKEN:-}" in ''|*[!a-zA-Z0-9_-]*) ddnsto_ow_error 'invalid or missing token'; return 2 ;; esac
    elif [ -n "${TOKEN:-}" ]; then
        ddnsto_ow_error 'credentials are only accepted for configure'; return 2
    fi
    ow_marker=${config%/*}/.uninstalled-openwrt-v1
    if [ -e "$ow_marker" ] || [ -L "$ow_marker" ]; then
        ddnsto_openwrt_retained_state_valid || {
            ddnsto_ow_error 'unrecognized or unsafe retained marker'; return 2
        }
    fi
    for ow_file in "$binary" "$config" "$service_path"; do
        ddnsto_ow_safe_path "$ow_file" || {
            ddnsto_ow_error 'unsafe or symlink installation path'; return 2
        }
        if [ "$ACTION" = uninstall ] && [ "$ow_file" != "$config" ] && [ ! -e "$ow_file" ]; then
            continue
        fi
        [ -f "$ow_file" ] || {
            ddnsto_ow_error 'regular files and non-symlink paths required; use explicit update for missing package files'
            return 2
        }
    done
    [ "${config##*/}" = ddnsto ] || { ddnsto_ow_error 'UCI config filename must be ddnsto'; return 2; }
    if [ "$ACTION" != uninstall ]; then
        [ -x "$binary" ] && [ -x "$service_path" ] || {
            ddnsto_ow_error 'valid OpenWrt config and executable package files required'; return 2
        }
    elif [ -e "$service_path" ] && [ ! -x "$service_path" ]; then
        ddnsto_ow_error 'package init script is not executable'; return 2
    fi
    ow_packages=$(ddnsto_ow_packages) && ddnsto_ow_has_package ddnsto || {
        ddnsto_ow_error 'installed ddnsto package metadata unavailable'; return 2
    }
    for ow_file in "$binary" "$config" "$service_path"; do
        ddnsto_ow_owned "$ow_file" || {
            ddnsto_ow_error 'package ownership not verified; external/native/container migration refused'; return 2
        }
    done
    ow_pending=$(uci -c "${config%/*}" -q changes ddnsto 2>/dev/null) && [ -z "$ow_pending" ] || {
        ddnsto_ow_error 'pending UCI changes or unreadable UCI state; commit or revert them first'; return 2
    }
    ow_work=$(mktemp -d "${config%/*}/.ddnsto-lifecycle.XXXXXX") || return 2
    ow_dirty=0
    trap ddnsto_ow_finish 0
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    mkdir "$ow_work/config" "$ow_work/delta" || return 2
    cp -p "$config" "$ow_work/original" || return 2
    if [ "$ACTION" = uninstall ]; then
        ddnsto_ow_uninstall
        return $?
    fi
    cp -p "$config" "$ow_work/config/ddnsto" || return 2
    ow_section=$(uci -c "$ow_work/config" -t "$ow_work/delta" -q get 'ddnsto.@ddnsto[0]' 2>/dev/null)
    [ "$ow_section" = ddnsto ] && ! uci -c "$ow_work/config" -t "$ow_work/delta" -q get 'ddnsto.@ddnsto[1]' >/dev/null 2>&1 || {
        ddnsto_ow_error 'exactly one ddnsto UCI section required'; return 2
    }
    if [ "$ACTION" = configure ]; then
        uci -c "$ow_work/config" -t "$ow_work/delta" -q set "ddnsto.@ddnsto[0].token=$TOKEN" >/dev/null 2>&1 || return 2
    else
        ow_token=$(uci -c "$ow_work/config" -t "$ow_work/delta" -q get 'ddnsto.@ddnsto[0].token' 2>/dev/null)
        [ -n "$ow_token" ] || { ddnsto_ow_error 'existing token required; use configure first'; return 2; }
        unset ow_token
    fi
    uci -c "$ow_work/config" -t "$ow_work/delta" -q set 'ddnsto.@ddnsto[0].enabled=1' >/dev/null 2>&1 || return 2
    uci -c "$ow_work/config" -t "$ow_work/delta" -q commit ddnsto >/dev/null 2>&1 || return 2
    ow_dirty=1
    mv -f "$ow_work/config/ddnsto" "$config" || return 2
    "$service_path" enable >/dev/null 2>&1 || return 13
    "$service_path" restart >/dev/null 2>&1 || return 13
    ow_attempt=0
    while ! "$service_path" status >/dev/null 2>&1; do
        ow_attempt=$((ow_attempt + 1))
        [ "$ow_attempt" -lt 10 ] || {
            ddnsto_ow_error 'service failed to reach running state'; return 13
        }
        sleep 1
    done
    ow_dirty=0
    printf 'operation=%s local_service=running cloud_status=unverified\n' "$ACTION"
)

#!/bin/sh
# Source-only Synology SPK download/manual-handoff helper.
# Downloads and digest verification belong to the caller's ddnsto_download.
ddnsto_synology_download() (
    umask 077
    synology_error() { printf 'DDNSTO: %s\n' "$1" >&2; }
    case "${ACTION:-install}" in
        install|download) ;;
        *) synology_error 'Synology supports only download or manual install handoff'; exit 2 ;;
    esac
    if [ -n "${TOKEN:-}${TOKEN_FILE:-}${FORCE_VERSION:-}" ] ||
        [ "${VERIFY_STATUS:-0}" != 0 ]; then
        synology_error 'Synology download does not accept credentials or installation flags; configure the package in DSM'
        exit 2
    fi
    case "${REQUESTED_METHOD:-auto}" in
        auto|native) ;;
        *) synology_error 'Synology download supports only auto or native method'; exit 2 ;;
    esac
    case "${PLAN_ONLY:-0}" in 0|1) ;; *) synology_error 'invalid plan flag'; exit 2 ;; esac

    version_file=${DDNSTO_DSM_VERSION_FILE:-/etc.defaults/VERSION}
    [ -f "$version_file" ] && [ -r "$version_file" ] || {
        synology_error 'cannot read DSM VERSION'; exit 2;
    }
    # Read data only. Do not source vendor VERSION or evaluate its contents.
    # Extract every occurrence so duplicate/ambiguous keys fail validation.
    # Count first: command substitution strips trailing empty lines.
    [ "$(grep -c '^[[:space:]]*majorversion[[:space:]]*=' "$version_file")" = 1 ] &&
        [ "$(grep -c '^[[:space:]]*buildnumber[[:space:]]*=' "$version_file")" = 1 ] || {
        synology_error 'DSM VERSION requires exactly one majorversion and buildnumber'; exit 2;
    }
    major=$(sed -n '/^[[:space:]]*majorversion[[:space:]]*=/ {
        s/^[[:space:]]*majorversion[[:space:]]*=[[:space:]]*//
        s/[[:space:]]*$//
        s/^"\(.*\)"$/\1/
        p
    }' "$version_file") || exit 2
    build=$(sed -n '/^[[:space:]]*buildnumber[[:space:]]*=/ {
        s/^[[:space:]]*buildnumber[[:space:]]*=[[:space:]]*//
        s/[[:space:]]*$//
        s/^"\(.*\)"$/\1/
        p
    }' "$version_file") || exit 2
    case "$major" in 6|7) ;; *) synology_error 'unsupported or ambiguous DSM major version'; exit 2 ;; esac
    case "$build" in ''|*[!0-9]*) synology_error 'invalid or ambiguous DSM build number'; exit 2 ;; esac
    [ "${#build}" -le 9 ] || { synology_error 'invalid DSM build number'; exit 2; }
    case "$major" in 6) minimum=5940 ;; 7) minimum=41890 ;; esac
    [ "$build" -ge "$minimum" ] || { synology_error 'DSM build is below the supported minimum'; exit 2; }
    arch=$(uname -m) || exit 2
    case "$arch" in
        x86_64) family=x86 ;;
        armv7|armv7l) family=arm ;;
        *) synology_error 'Synology SPK supports only x86_64 and armv7'; exit 2 ;;
    esac
    case "$family:$major" in
        arm:6) digest=0595dd1ae1681213acb35dfc61e15d877bfee19e59d5f4242a366540922b7f89 ;;
        arm:7) digest=bde9af2d3ff17f4bc5c609b79af39da7efd7209c59d03935492d1748bb84eba5 ;;
        x86:6) digest=89d5871b7162edba9e4467a619d5d2eae19744d9cf637692e0695a1a4a701a83 ;;
        x86:7) digest=cccf82a0240c235d5eea6465ca9a339a9d92977345418ab72deb79ce2a3c8b59 ;;
    esac
    filename="ddnsto_${family}-dsm${major}.spk"
    relative="synology/$filename"
    handoff() {
        printf '%s\n' 'platform=synology' 'package_version=4.2.7-4' \
            "dsm_major=$major" "dsm_build=$build" "arch=$arch" \
            'installation_performed=false' 'installation_status=manual-required' \
            'Open DSM Package Center > Manual Install and import the downloaded SPK.' \
            'Identity migration: back up existing Token/configuration and device identity before upgrading or migrating; follow the package migration instructions and verify the device identity afterward. No identity migration is performed by this helper.'
    }
    if [ "${PLAN_ONLY:-0}" = 1 ]; then
        printf '%s\n' 'operation=plan' 'download_performed=false' "package_relative=$relative" "package_sha256=$digest"
        handoff
        exit 0
    fi
    OUTPUT_DIR=${OUTPUT_DIR:-$PWD/ddnsto-downloads}
    # Prefix relative paths to avoid interpreting a leading '-' as an option.
    case "$OUTPUT_DIR" in /*) output=$OUTPUT_DIR ;; *) output="./$OUTPUT_DIR" ;; esac
    [ ! -L "$output" ] || { synology_error 'output directory must not be a symlink'; exit 2; }
    mkdir -p "$output" || exit 2
    output=$(cd "$output" && pwd -P) || exit 2
    work=$(mktemp -d "$output/ddnsto-synology.XXXXXX") || exit 2
    keep=0
    cleanup_synology() {
        code=$?
        trap - EXIT HUP INT TERM
        if [ "$keep" = 0 ]; then
            # Only our private staging file; never remove an existing package
            # or recursively delete the caller's output directory.
            rm -f "$work/$filename.part"
            rmdir "$work" 2>/dev/null || true
        fi
        exit "$code"
    }
    trap cleanup_synology EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    ddnsto_download "$relative" "$work/$filename.part" "$digest" || exit "$?"
    [ -f "$work/$filename.part" ] && [ -s "$work/$filename.part" ] && [ ! -L "$work/$filename.part" ] || {
        synology_error 'verified download did not produce a regular nonempty SPK'; exit 11;
    }
    mv "$work/$filename.part" "$work/$filename" || exit 2
    keep=1
    printf '%s\n' 'operation=download' 'download_performed=true' "package_path=$work/$filename" "package_sha256=$digest"
    handoff
    [ "${ACTION:-install}" = download ] || exit 20
)

# Local-only management. Never bootstrap or read client credentials.
ddnsto_service_state() {
    if [ "$manager" = systemd ]; then
        service_state=$(ddnsto_privileged systemctl show --property=ActiveState --value "$linux_service_name") || return $?
        case "$service_state" in
            active) service_state=running ;;
            inactive) service_state=stopped ;;
            failed|activating|deactivating|reloading) ;;
            *) ddnsto_error 'unknown service state'; return 2 ;;
        esac
    else
        state_rc=0
        ddnsto_service_command status >/dev/null 2>&1 || state_rc=$?
        case "$state_rc" in
            0) service_state=running ;;
            1|3) service_state=stopped ;;
            *) ddnsto_error 'could not query service state'; return "$state_rc" ;;
        esac
    fi
}

ddnsto_service_assert_owned() (
    # A matching name/LoadState is not ownership. Reuse the lifecycle contracts
    # before EVERY write (including enable/disable), under the shared lock.
    case "$manager" in
        systemd)
            for owned_path in "$bin_path" "$linux_config_file" "$config_dir/.installer-linux-v1" "$config_dir/.uninstalled-linux-v1"; do
                ddnsto_linux_lifecycle_safe_path "$owned_path" || return 2
            done
            ddnsto_privileged test -f "$bin_path" && ddnsto_privileged test -f "$linux_config_file" || return 2
            ddnsto_linux_state_valid "$config_dir/.installer-linux-v1" || {
                ddnsto_error 'managed Linux marker required for service changes; legacy status remains available'; return 2;
            }
            ddnsto_privileged test ! -e "$config_dir/.uninstalled-linux-v1" || return 2
            ddnsto_linux_unit_exists && ddnsto_linux_unit_owned || {
                ddnsto_error 'systemd service ownership not verified; refusing service operation'; return 2;
            } ;;
        openwrt)
            case "${package_manager:-}" in opkg|apk) ;; *) ddnsto_error 'package manager required for service ownership'; return 2 ;; esac
            for owned_path in "$binary" "$config" "$service_path"; do
                ddnsto_ow_safe_path "$owned_path" && [ -f "$owned_path" ] && ddnsto_ow_owned "$owned_path" || {
                    ddnsto_error 'OpenWrt package ownership not verified; refusing service operation'; return 2;
                }
            done
            [ -x "$binary" ] && [ -x "$service_path" ] || return 2
            ow_packages=$(ddnsto_ow_packages) && ddnsto_ow_has_package ddnsto || {
                ddnsto_error 'installed ddnsto package metadata unavailable'; return 2;
            } ;;
        *) ddnsto_error 'OpenRC write actions require verifiable ownership and are not supported'; return 2 ;;
    esac
)

ddnsto_service_command() {
    if [ "$1" != status ]; then ddnsto_service_assert_owned || return 2; fi
    case "$manager:$1" in
        systemd:*) ddnsto_privileged systemctl "$1" "$linux_service_name" ;;
        openrc:enable) ddnsto_privileged rc-update add "$linux_service_name" default ;;
        openrc:disable) ddnsto_privileged rc-update del "$linux_service_name" default ;;
        openrc:*) ddnsto_privileged rc-service "$linux_service_name" "$1" ;;
        openwrt:*) ddnsto_privileged "$service_path" "$1" ;;
    esac
}

ddnsto_manage_service() {
    ddnsto_local_platform || exit $?
    [ "$REQUESTED_METHOD" != docker ] || { ddnsto_error 'Docker management is not available'; exit 2; }
    case "$detected_platform" in linux|openwrt) ;; *) ddnsto_error 'native service management is unavailable for this device'; exit 2 ;; esac
    if [ "$ACTION" = status ]; then
        ddnsto_manage_service_locked
    else
        ddnsto_with_operation_lock ddnsto_manage_service_locked
    fi
}

ddnsto_manage_service_locked() (
    case "$detected_platform" in
        linux)
            ddnsto_linux_preflight management || exit $?
            binary=${DDNSTO_BIN_PATH:-/usr/local/bin/ddnsto}
            config_dir=${DDNSTO_LINUX_CONFIG_DIR:-/etc/ddnsto}
            config=$config_dir/ddnsto-config.json
            if [ "$ACTION" = status ] && ddnsto_linux_state_valid "$config_dir/.uninstalled-linux-v1" &&
               ! ddnsto_privileged test -e "$binary" && ! ddnsto_privileged test -L "$binary"; then
                printf '%s\n' 'local_service=not-installed config=retained cloud_status=unverified'
                exit 0
            fi ;;
        openwrt)
            SUDO=
            [ "$(id -u)" = 0 ] || { ddnsto_error 'OpenWrt management requires root'; exit 2; }
            binary=${DDNSTO_OPENWRT_BIN_PATH:-/usr/sbin/ddnstod}
            config=${DDNSTO_CONFIG_PATH:-/etc/config/ddnsto}
            config_dir=${config%/*} ;;
        *) ddnsto_error 'native service management is unavailable for this device'; exit 2 ;;
    esac
    for file in "$binary" "$config"; do
        ddnsto_privileged test -f "$file" && ddnsto_privileged test ! -L "$file" || { ddnsto_error 'complete native installation required; no service changes made'; exit 2; }
    done
    ddnsto_privileged test ! -L "$config_dir" || { ddnsto_error 'configuration directory must not be a symlink'; exit 2; }
    if [ "$detected_platform" = linux ]; then
        manager=$linux_service_manager
        if [ "$manager" = systemd ]; then
            bin_path=$binary
            linux_config_file=$config
            unit_path=$(ddnsto_linux_unit_path) || exit 2
            load_state=$(ddnsto_privileged systemctl show --property=LoadState --value "$linux_service_name") || exit $?
            [ "$load_state" = loaded ] || { ddnsto_error 'installed service unit is unavailable'; exit 2; }
        else
            [ "$ACTION" = status ] || { ddnsto_error 'OpenRC write actions require verifiable ownership and are not supported'; exit 2; }
            ddnsto_privileged rc-service --exists "$linux_service_name" || exit $?
        fi
    else
        manager=openwrt
        service_path=${DDNSTO_SERVICE_PATH:-/etc/init.d/ddnsto}
        [ -f "$service_path" ] && [ -x "$service_path" ] && [ ! -L "$service_path" ] || exit 2
    fi
    if [ "$ACTION" != status ]; then
        # stop disables boot startup as well as stopping the supervised process.
        # No config rewrite, service re-registration or implicit install occurs.
        if [ "$ACTION" = stop ]; then
            ddnsto_service_command disable || exit $?
            ddnsto_service_command stop || exit $?
            expected=stopped
        else
            ddnsto_service_command enable || exit $?
            if [ "$ACTION" = restart ]; then ddnsto_service_command stop || exit $?; fi
            ddnsto_service_command start || exit $?
            expected=running
        fi
        attempt=0
        while :; do
            ddnsto_service_state || exit $?
            [ "$service_state" != "$expected" ] || break
            attempt=$((attempt + 1))
            [ "$attempt" -lt 10 ] || { ddnsto_error 'service did not reach requested state'; exit 13; }
            sleep 1
        done
    else
        ddnsto_service_state || exit $?
    fi
    printf 'local_service=%s cloud_status=unverified\n' "$service_state"
)


bootstrap_and_run() {
    status "[1/4] Checking zsetup..."
    ddnsto_bootstrap_zsetup || return $?
    status "      zsetup $RESCUE_VERSION is ready"
    ZSETUP_BIN=$ACTIVE_ZSETUP
    ZSETUP_SOURCE_BASES=${ZSETUP_SOURCE_BASES:-$DIRECT_PRIMARY_BASES}
    ZSETUP_SOURCE_FALLBACK=${ZSETUP_SOURCE_FALLBACK-$DIRECT_FALLBACK_BASE}
    export ZSETUP_BIN ZSETUP_ARCH ZSETUP_SOURCE_BASES ZSETUP_SOURCE_FALLBACK
    ddnsto_install "$@"
}

ddnsto_dispatch_local_action() {
    ddnsto_validate_action_options || return $?
    case "$ACTION" in
        status|start|stop|restart) ddnsto_manage_service ;;
        repair|configure|uninstall)
            ddnsto_local_platform || return $?
            [ "$REQUESTED_METHOD" != docker ] || { ddnsto_error 'Docker lifecycle unavailable'; return 2; }
            case "$detected_platform" in
                linux) ddnsto_with_operation_lock ddnsto_linux_lifecycle ;;
                openwrt)
                    SUDO=
                    [ "$(id -u)" = 0 ] || { ddnsto_error 'OpenWrt lifecycle requires root'; return 2; }
                    business_platform=openwrt
                    binary=${DDNSTO_OPENWRT_BIN_PATH:-/usr/sbin/ddnstod}
                    config=${DDNSTO_CONFIG_PATH:-/etc/config/ddnsto}
                    service_path=${DDNSTO_SERVICE_PATH:-/etc/init.d/ddnsto}
                    if [ "$ACTION" = configure ] && [ -z "$TOKEN" ]; then
                        [ -t 0 ] || { ddnsto_error 'configure needs --token or --token-file without an interactive terminal'; return 2; }
                        TOKEN=$(ddnsto_prompt_token) || { ddnsto_error 'could not read token'; return 2; }
                        [ -n "$TOKEN" ] || { ddnsto_error 'empty token'; return 2; }
                    fi
                    ddnsto_with_operation_lock ddnsto_openwrt_lifecycle ;;
                *) ddnsto_error 'this platform lifecycle is not available'; return 2 ;;
            esac ;;
        *) return 2 ;;
    esac
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
    ddnsto_parse_args "$@" || return $?
    if [ "$PLAN_ONLY" = 0 ] && [ "${ZSETUP_INSTALLER_MODE:-0}" != 1 ] &&
       { [ "$ACTION" = install ] || [ "$ACTION" = update ] || [ "$ACTION" = download ]; }; then
        ddnsto_local_platform || return $?
        ddnsto_validate_platform_options || return $?
        ddnsto_offer_install_method || return $?
    fi
    if [ "$REQUESTED_METHOD" = docker ]; then
        ddnsto_local_platform || return $?
        [ -z "$OUTPUT_DIR" ] || { ddnsto_error 'output-dir is not a Docker option'; return 2; }
        if [ "$PLAN_ONLY" = 1 ]; then ddnsto_docker_plan
        elif [ "$ACTION" = status ]; then ddnsto_docker_lifecycle
        else ddnsto_with_operation_lock ddnsto_docker_lifecycle; fi
        return $?
    fi
    if [ "$PLAN_ONLY" = 1 ]; then ddnsto_plan; return $?; fi
    case "$ACTION" in
        repair|configure|uninstall|status|start|stop|restart) ddnsto_dispatch_local_action; return $? ;;
    esac
    if [ "${ZSETUP_INSTALLER_MODE:-0}" != 1 ]; then
        # Exiting an existing installation must also work offline, without
        # bootstrapping zsetup or creating cache files. Revalidate after context.
        ddnsto_local_platform || return $?
        if [ "$REQUESTED_METHOD" = docker ]; then
            ddnsto_error 'Docker installer is not available; native installation was not attempted'
            return 2
        fi
        case "$detected_platform" in
            linux|openwrt)
                business_platform=$detected_platform
                ddnsto_existing_policy || return $?
                [ "$INSTALL_SKIPPED" = 0 ] || return 0
                case "$ACTION" in install|update) ;; *) ddnsto_dispatch_local_action; return $? ;; esac
                # Carry an interactive choice across the installer's reparse.
                if [ "$ACTION" = update ]; then set -- "$@" --action update; fi ;;
        esac
    fi
    status 'DDNSTO installer'
    if [ "${ZSETUP_INSTALLER_MODE:-0}" = 1 ]; then
        status '[1/4] zsetup is ready'
        ddnsto_install "$@"
    else
        bootstrap_and_run "$@"
    fi
}
main "$@"
