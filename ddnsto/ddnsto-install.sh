#!/bin/sh
if [ "$(uname -s)" = Darwin ]; then
(
#!/bin/sh
# Engineering candidate: bootstraps zsetup automatically; native canary pending.
set -eu
set +x
umask 077
VERSION=${DDNSTO_VERSION:-4.2.8}
INSTALL_DIR=${DDNSTO_INSTALL_DIR:-$HOME/.local/bin}
CONFIG_DIR=${DDNSTO_CONFIG_DIR:-$HOME/Library/Application Support/DDNSTO}
AGENTS_DIR=${DDNSTO_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}
LABEL=com.ddnsto.client
TOKEN=
TOKEN_FILE=
REQUESTED_PLATFORM=auto
REQUESTED_METHOD=auto
PLAN_ONLY=0
ACTION=ensure
diagnostic_path=
diagnostic_write_failed=0
diagnostic_event() {
    [ -n "$diagnostic_path" ] || return 0
    # Only literals from this allowlist enter the diagnostic stream. Never
    # accept a reason, command output, config value, argv or user path here.
    case "$1" in checking|account|version|installing|starting|stable|rollback|recovery_failed) ;; *) return 0 ;; esac
    printf 'stage=%s\n' "$1" >&9 || diagnostic_write_failed=1
    return 0
}
diagnostic_finish() {
    [ -n "$diagnostic_path" ] || return 0
    case "$1" in ''|*[!0-9]*) diagnostic_code=1 ;; *) diagnostic_code=$1 ;; esac
    if [ "$diagnostic_code" != 0 ]; then
        printf '%s\n' 'error=E_EXECUTOR' >&9 || diagnostic_write_failed=1
    fi
    printf 'exit_code=%s\n' "$diagnostic_code" >&9 || diagnostic_write_failed=1
    exec 9>&-
    [ "$diagnostic_write_failed" = 0 ] || printf '%s\n' 'DDNSTO：诊断记录写入不完整。' >&2
    printf '脱敏诊断记录：%s\n' "$diagnostic_path" >&2
    diagnostic_path=
    return 0
}
fail() {
    # Historical advanced actions share the same concise localized result.
    case "$1" in
        [!a-zA-Z]*) reason=$1 ;;
        token*|existing\ token*|configure\ requires*|choose\ either*|*credentials*) reason='Token 缺失、不一致或格式无效，请通过 --token 或 --token-file 传入' ;;
        *unmanaged*|*ownership*|*symlink*|*regular*|*unexpected\ files*) reason='已有安装归属不明或文件不安全，未覆盖' ;;
        *lock*|*active*) reason='另一个安装或管理操作正在进行，请稍后重试' ;;
        *checksum*|*download*|*binary*|*zsetup*) reason='下载或程序校验失败，请检查网络和安装凭据' ;;
        *launchd*|*service*|*plist*|*process*) reason='本地服务检查失败，请检查 launchd 状态与本地日志' ;;
        *argument*|*action*|*method*|*platform*|*macOS*|*architecture*|*version*|*paths*|*--plan*) reason='参数或运行环境不支持，请检查 --help 并使用 macOS 登录用户' ;;
        installation\ changed*) reason='安装状态已变化，请重新运行' ;;
        no\ existing\ installation*|no\ managed\ installation*) reason='没有可管理的安装，请先安装' ;;
        installation\ removed*) reason='程序已卸载，请传入原账号 Token 重新安装' ;;
        *) reason=$1 ;;
    esac
    printf 'DDNSTO：%s；状态=%s；下一步：检查当前用户、安装凭据和配置后重试；code=%s\n' "$reason" "${state:-未更改}" "${2:-2}" >&2
    if [ -z "$diagnostic_path" ] && { [ "$ACTION" = ensure ] || [ "${default_install:-0}" = 1 ]; }; then
        printf '%s\n' '诊断限制：未建立私有诊断记录。' >&2
    fi
    exit "${2:-2}"
}
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
        --help|-h) printf '%s\n' 'Usage: install-macos.sh [--plan] [--action ensure|install|update|status|start|stop|restart|repair|uninstall|configure] [--platform auto|macos] [--method auto|native] [--token TOKEN | --token-file FILE] [--version 4.2.8]' '默认 ensure：自动安装、升级或启动同账号服务，保留配置和设备身份，不降级。请传入 Token，不提供交互菜单。' 'configure 显式更换 Token；uninstall 保留配置和身份。'; exit 0 ;;
        *) fail 'unknown argument' ;;
    esac
done
[ "$(uname -s)" = Darwin ] || fail 'this installer requires macOS'
case "$REQUESTED_PLATFORM" in auto|macos) ;; *) fail 'platform mismatch: this device is macos' ;; esac
case "$REQUESTED_METHOD" in auto|native) ;; docker) fail 'Docker installer is not available for macOS' ;; *) fail 'unknown installation method' ;; esac
case "$ACTION" in ensure|install|update|status|start|stop|restart|repair|uninstall|configure) ;; *) fail 'unknown action' ;; esac
if [ "$ACTION" != install ] && [ "$ACTION" != ensure ]; then
    [ "$ACTION" = configure ] || [ -z "$TOKEN$TOKEN_FILE" ] || fail 'service actions do not accept credentials'
    [ "$PLAN_ONLY" = 0 ] || fail '--plan cannot be combined with service actions'
fi
case "$(uname -m)" in x86_64|amd64) member=ddnsto_cli.amd64 ;; arm64|aarch64) member=ddnsto_cli.arm64 ;; *) fail 'unsupported macOS architecture' ;; esac
[ "$VERSION" = 4.2.8 ] || fail 'no pinned artifact for requested version'
if [ "$PLAN_ONLY" = 1 ]; then
    [ -z "$TOKEN$TOKEN_FILE" ] || fail '--plan does not accept credentials'
    printf '%s\n' 'facts_source=local-preflight' 'platform=macos' "arch=${member#ddnsto_cli.}" \
        "client_version=$VERSION" 'zsetup_version=0.3.0' 'native_status=requires-launchd-preflight' \
        'docker_installable=false' 'installation_performed=false'
    exit 0
fi
default_install=0
if [ "$ACTION" = ensure ]; then default_install=1; ACTION=install; fi
archive_sha=8bb1e102160c8e52f670839051ca341f0a083720634da79c2142a1de6d13f446
ZSETUP_BIN=${ZSETUP_BIN:-}
for tool in launchctl tar sed grep stat shasum awk; do command -v "$tool" >/dev/null || fail "缺少依赖：$tool"; done
uid=$(id -u)
[ "$uid" != 0 ] || fail '请在已登录的普通用户终端运行，不要使用 sudo/root'
domain="gui/$uid"
for directory in "$INSTALL_DIR" "$CONFIG_DIR" "$AGENTS_DIR"; do
    case "$directory" in /*) ;; *) fail 'installation paths must be absolute' ;; esac
    [ ! -L "$directory" ] || fail 'installation directories must not be symlinks'
done
config="$CONFIG_DIR/ddnsto.yaml"
binary="$INSTALL_DIR/ddnsto"
plist="$AGENTS_DIR/$LABEL.plist"
marker="$CONFIG_DIR/.installer-macos-v1"
receipt="$CONFIG_DIR/.installer-macos-version"
# Use filesystem ownership, never shell-source a receipt or credential file.
protected_path() {
    [ ! -L "$1" ] || fail '安装路径包含符号链接，归属不明'
    [ -e "$1" ] || return 0
    metadata=$(stat -f '%u %Lp' "$1") || fail '无法读取文件归属'
    owner=${metadata%% *}; mode=${metadata#* }
    [ "$owner" = "$uid" ] || fail '安装文件不属于当前用户'
    case "$mode" in ''|*[!0-7]*) fail '无法确认文件权限' ;; esac
    [ "$((0$mode & 022))" = 0 ] || fail '安装文件可被其他用户修改'
    if [ "${2:-}" = private ]; then
        [ "$((0$mode & 077))" = 0 ] || fail '配置或凭据未受私有权限保护'
    fi
}
protected_parents() (
    parent=$1
    while [ "$parent" != / ]; do
        [ ! -L "$parent" ] || fail '安装路径包含符号链接，归属不明'
        if [ -e "$parent" ]; then
            [ -d "$parent" ] || fail '安装路径不是目录'
            metadata=$(stat -f '%u %Lp' "$parent") || fail '无法读取目录归属'
            owner=${metadata%% *}; mode=${metadata#* }
            case "$mode" in ''|*[!0-7]*) fail '无法确认目录权限' ;; esac
            [ "$owner" = 0 ] || [ "$owner" = "$uid" ] || fail '上级目录归属不明'
            # Sticky system temporary directories protect child ownership.
            [ "$((0$mode & 022))" = 0 ] || [ "$((0$mode & 01000))" != 0 ] || fail '上级目录可被其他用户修改'
        fi
        parent=${parent%/*}
        [ -n "$parent" ] || parent=/
    done
)
check_account() {
    diagnostic_event account
    [ -n "$TOKEN" ] || fail '缺少 Token，请通过 --token 或 --token-file 传入'
    # Only the installer scalar is accepted. Duplicates, YAML aliases/merges,
    # alternate documents or quoted keys make ownership ambiguous.
    [ "$(grep -c 'userToken' "$config")" = 1 ] &&
        grep -F -x -q -- "$token_line" "$config" || fail '账号不一致或 Token 配置不明，已停止'
    # A flat mapping is the format we write. Do not interpret escaped keys,
    # explicit keys or multiline YAML as proof of account ownership.
    awk '/^[A-Za-z][A-Za-z0-9_]*:/ {next}
         /^[[:space:]]*(#.*)?$/ {next}
         {exit 1}' "$config" || fail '配置结构无法确认账号归属，请人工核对配置'
    if grep -E -q '(^[[:space:]]*(---|\.\.\.|%|<<:)|[[:space:]][&*][^[:space:]])' "$config"; then
        fail '配置包含无法确认归属的 YAML 定义'
    fi
}
check_version() {
    diagnostic_event version
    [ -f "$receipt" ] || fail '缺少版本凭据，无法确认旧安装版本，需人工迁移'
    installed_version=$(sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\) [0-9a-f]*$/\1/p' "$receipt")
    printf '%s\n' "$installed_version" | grep -E -q '^[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}$' || fail '版本凭据无效'
    if [ "$state" = installed ]; then
        digest=$(shasum -a 256 "$binary") || fail '无法校验已安装程序'
        [ "$(cat "$receipt")" = "$installed_version ${digest%% *}" ] || fail '程序与版本凭据不一致，已停止'
    else
        [ "$(wc -l < "$receipt" | tr -d ' ')" = 1 ] &&
            grep -E -q '^[0-9]+\.[0-9]+\.[0-9]+ [0-9a-f]{64}$' "$receipt" || fail '版本凭据无效'
    fi
    older=$(awk -v old="$installed_version" -v target="$VERSION" 'BEGIN {
        split(old,a,"."); split(target,b,".");
        for(i=1;i<=3;i++) { if(a[i]+0<b[i]+0) {print 1;exit}; if(a[i]+0>b[i]+0) {print 0;exit} }
        print 0
    }')
    if [ "$state" = retained ] && [ "$older" = 0 ] && [ "$installed_version" != "$VERSION" ]; then
        fail '保留配置来自更新版本，不能降级安装，请使用对应新版安装器'
    fi
}
stable_running() {
    previous_pid=
    observation=0
    while [ "$observation" -lt 3 ]; do
        sleep 1
        job=$(launchctl print "$domain/$LABEL" 2>/dev/null) || fail '本地服务未运行，请检查本地日志后重试' 1
        validate_job
        job_state=$(printf '%s\n' "$job" | sed -n 's/^[[:space:]]*state = \([^[:space:]]*\)[[:space:]]*$/\1/p')
        [ "$job_state" = running ] || fail '本地服务尚未处于运行状态，请检查本地日志' 1
        current_pid=$(printf '%s\n' "$job" | sed -n 's/^[[:space:]]*pid = \([1-9][0-9]*\)[[:space:]]*$/\1/p')
        case "$current_pid" in ''|*[!0-9]*) fail '本地服务没有有效进程，请检查本地日志' 1 ;; esac
        [ -z "$previous_pid" ] || [ "$previous_pid" = "$current_pid" ] || fail '本地进程反复重启，尚未稳定，请检查本地日志' 1
        previous_pid=$current_pid
        observation=$((observation + 1))
    done
    diagnostic_event stable
}
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
    for directory in "$INSTALL_DIR" "$CONFIG_DIR" "$AGENTS_DIR"; do
        protected_parents "$directory"
        protected_path "$directory"
    done
    for file in "$config" "$binary" "$plist" "$marker" "$receipt" "$CONFIG_DIR/.ddnsto_boot.cfg"; do
        [ ! -L "$file" ] || fail 'managed files must not be symlinks'
        [ ! -e "$file" ] || [ -f "$file" ] || fail 'managed files must be regular'
        protected_path "$file"
    done
    protected_path "$config" private
    protected_path "$marker" private
    protected_path "$receipt" private
    if [ -e "$binary" ] || [ -e "$config" ] || [ -e "$plist" ] || [ -e "$marker" ] || [ -e "$receipt" ] || [ -e "$CONFIG_DIR/.ddnsto_boot.cfg" ]; then
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
                # Recreate only an otherwise owned installation's definition.
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
    validate_job
}
validate_job() {
    # Fail closed if a same-label job does not describe our exact file paths.
    normalized=$(printf '%s\n' "$job" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    printf '%s\n' "$normalized" | grep -F -x -q "program = $binary" &&
    printf '%s\n' "$normalized" | grep -F -x -q "path = $plist" &&
    printf '%s\n' "$normalized" | grep -F -x -q "$config" || fail 'existing unmanaged launchd job'
}
check_state
if [ "$default_install" = 1 ]; then
    # Ownership preflight precedes all diagnostic writes. Use a fresh private
    # directory, never a caller-provided log filename or an existing log file.
    mkdir -p "$CONFIG_DIR" || fail '无法创建私有诊断目录' 12
    protected_path "$CONFIG_DIR" private
    diagnostic_dir=$(mktemp -d "$CONFIG_DIR/.diagnostic.XXXXXX") || fail '无法创建私有诊断目录' 12
    diagnostic_path="$diagnostic_dir/events.log"
    if ! exec 9>"$diagnostic_path"; then
        diagnostic_path=
        fail '无法创建私有诊断记录' 12
    fi
    trap 'diagnostic_rc=$?; trap - EXIT; diagnostic_finish "$diagnostic_rc"; exit "$diagnostic_rc"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    diagnostic_event checking
fi
# Default diagnostics never capture raw external output, and child errors are
# not exposed as installer diagnostics. Structured launchd queries still return
# their data to the caller; explicit advanced actions retain their output.
launchctl() {
    if [ "$default_install" = 1 ]; then
        case "$1" in
            print|print-disabled) command launchctl "$@" 2>/dev/null ;;
            *) command launchctl "$@" >/dev/null 2>&1 ;;
        esac
    else
        command launchctl "$@"
    fi
}
installer_command() {
    if [ "$default_install" = 1 ]; then "$@" >/dev/null 2>&1
    else "$@"; fi
}
installer_output() {
    if [ "$default_install" = 1 ]; then "$@" 2>/dev/null
    else "$@"; fi
}
if [ "$ACTION" = update ] && [ ! -f "$marker" ]; then fail 'no existing installation; install first'; fi
if [ "$state" = retained ]; then
    case "$ACTION" in install|uninstall|status) ;; *) fail 'installation removed; use --action install to reuse retained configuration' ;; esac
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
            printf 'DDNSTO：卸载恢复未完成；状态=需人工检查；下一步：保留并检查备份 %s；code=1\n' "$work" >&2
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
    printf '%s\n' 'operation=uninstall local_service=not-installed configuration=retained cloud_status=unverified' '卸载完成：保留配置、设备身份和日志。默认重装请传入原账号 Token。'
)
manage_service() (
    # The parent owns the diagnostic exit record, including early failures.
    trap - EXIT
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
    if [ "$default_install" = 1 ]; then check_account; check_version; fi
    check_job
    if [ "$ACTION" = uninstall ]; then uninstall_managed; exit "$?"; fi
    if [ "$ACTION" = stop ]; then
        launchctl disable "$domain/$LABEL" || fail 'could not disable service'
        if launchctl print "$domain/$LABEL" >/dev/null 2>&1; then
            launchctl bootout "$domain/$LABEL" || fail 'could not stop service'
        fi
        if launchctl print "$domain/$LABEL" >/dev/null 2>&1; then fail 'service still loaded after stop'; fi
        printf '%s\n' 'local_service=stopped cloud_status=unverified' '已停止并禁用登录启动。使用 --action start 恢复。'
        exit 0
    fi
    diagnostic_event starting
    launchctl enable "$domain/$LABEL" || fail 'could not enable service'
    if [ "$ACTION" = restart ] && launchctl print "$domain/$LABEL" >/dev/null 2>&1; then
        launchctl bootout "$domain/$LABEL" || fail 'could not stop service for restart'
    fi
    if ! launchctl print "$domain/$LABEL" >/dev/null 2>&1; then
        launchctl bootstrap "$domain" "$plist" || fail 'could not load service'
    fi
    launchctl kickstart "$domain/$LABEL" || fail 'could not start service'
    stable_running
    printf '%s\n' '启动成功：本地服务稳定运行，已启用登录启动。' 'local_service=running cloud_status=unverified'
)
case "$ACTION" in install|update|repair|configure) ;; *) manage_service; exit "$?" ;; esac
case "$ACTION" in repair|configure) [ "$state" = installed ] || fail 'no managed installation';; esac
if [ -n "$TOKEN_FILE" ]; then
    [ -z "$TOKEN" ] || fail 'choose either token or token-file'
    [ -f "$TOKEN_FILE" ] && [ ! -L "$TOKEN_FILE" ] || fail 'token file must be regular'
    TOKEN=$(cat "$TOKEN_FILE"; printf '.')
    TOKEN=${TOKEN%.}
    TOKEN=${TOKEN%"
"}
fi
case "$TOKEN" in *"
"*|*"$(printf '\r')"*) fail 'token must be one line' ;; esac
yaml_token=$(printf '%s' "$TOKEN" | sed "s/'/''/g")
token_line="userToken: '$yaml_token'"
if [ "$default_install" = 1 ]; then
    [ -n "$TOKEN" ] || fail '缺少 Token，请通过 --token 或 --token-file 传入'
    [ "$state" = absent ] || check_account
fi
if [ "$ACTION" = configure ]; then
    [ -n "$TOKEN" ] || fail 'configure requires --token or --token-file'
elif [ -f "$config" ]; then
    [ -z "$TOKEN" ] || grep -F -x -q -- "$token_line" "$config" || fail 'existing token differs; edit configuration explicitly before reinstalling'
else
    [ -n "$TOKEN" ] || fail 'token is required on first installation'
fi
if [ "$state" = installed ] && { [ "$ACTION" = install ] || [ "$ACTION" = update ]; }; then
    check_version
    if [ "$older" = 0 ] && { [ "$ACTION" = install ] || [ "$installed_version" != "$VERSION" ]; }; then
        # Repair the owned definition as needed, without replacing newer bytes.
        if [ ! -f "$plist" ] || [ "$(cat "$plist")" != "$(managed_plist)" ]; then
            ACTION=repair
        else
            ACTION=start
            manage_service
            exit "$?"
        fi
    else
        ACTION=update
    fi
fi
if [ "$state" = retained ]; then check_version; fi
launchctl print "$domain" >/dev/null 2>&1 || fail '当前用户没有可用的图形登录会话，请登录 macOS 后重试'
if [ "$state" != absent ]; then check_job; fi
uid=$(id -u)
domain="gui/$uid"
work=$(mktemp -d "${TMPDIR:-/tmp}/ddnsto.XXXXXX")
changed=0
had_old=0
had_config=0
had_plist=0
had_marker=0
had_receipt=0
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
        diagnostic_event rollback
        if job=$(launchctl print "$domain/$LABEL" 2>/dev/null); then
            if (validate_job) >/dev/null 2>&1; then
                launchctl bootout "$domain/$LABEL" >/dev/null 2>&1 || recovery_failed=1
                if launchctl print "$domain/$LABEL" >/dev/null 2>&1; then recovery_failed=1; fi
            else
                recovery_failed=1
            fi
        fi
        # Never replace files underneath a candidate that could still be live.
        # A failed stop retains all recovery material and reports uncertainty.
        if [ "$recovery_failed" = 1 ]; then
            printf '%s\n' 'DDNSTO：无法安全停止当前任务，未覆盖正在使用的文件。' >&2
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
        if [ "$recovery_failed" = 0 ]; then
            if [ "$had_receipt" = 1 ]; then
                cp -p "$work/old-receipt" "$receipt" || recovery_failed=1
            else
                rm -f "$receipt" || recovery_failed=1
            fi
        fi
    fi
    # Also restore the override if enable itself failed before any file/job change.
    if [ "$code" != 0 ] && [ "$restore_disabled" = 1 ]; then
        launchctl disable "$domain/$LABEL" >&2 || recovery_failed=1
    fi
    [ -z "$candidate" ] || rm -f "$candidate"
    [ "$locked" = 0 ] || rmdir "$CONFIG_DIR/.install-lock"
    if [ "$recovery_failed" = 1 ]; then
        diagnostic_event recovery_failed
        printf 'DDNSTO：恢复未完成；状态=需人工检查；下一步：保留并检查备份 %s；code=1\n' "$work" >&2
        diagnostic_finish 1
        exit 1
    fi
    rm -rf "$work"
    [ "$code" = 0 ] || printf 'DDNSTO：操作失败，已尝试恢复；状态=需检查；下一步：检查本地服务及日志后重试；code=%s\n' "$code" >&2
    diagnostic_finish "$code"
    exit "$code"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
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

ensure_zsetup() {
    if [ -n "$ZSETUP_BIN" ]; then
        [ -x "$ZSETUP_BIN" ] && [ "$(installer_output "$ZSETUP_BIN" --version)" = 'zsetup 0.3.0' ] || fail 'explicit zsetup must be executable version 0.3.0'
        return
    fi
    command -v shasum >/dev/null || fail 'shasum is required for initial bootstrap verification'
    case "$member" in
        ddnsto_cli.amd64) native=zsetup-macos-x86_64; native_sha=608323145bcd8f083c0845b4bd0481eabccf0d74b99aa2aa6a88e59b34ce5b31 ;;
        *) native=zsetup-macos-aarch64; native_sha=06ec453f851bd0395cf9ea8539de168f80a9628d1a25597dd598c85f9dc633b0 ;;
    esac
    printf '%s\n' 'DDNSTO：正在下载并校验 zsetup 0.3.0。' >&2
    for base in https://dl.istoreos.com/binary https://fw.d4ctech.com/binary https://fw20.koolcenter.com/binary https://fw.koolcenter.com/binary; do
        fetch_code=0
        ddnsto_https_fetch "$base/zsetup/0.3.0/$native" "$work/zsetup.part" 16777216 || fetch_code=$?
        if [ "$fetch_code" = 0 ]; then
            actual=$(shasum -a 256 "$work/zsetup.part")
            if [ "${actual%% *}" = "$native_sha" ]; then
                mv "$work/zsetup.part" "$work/zsetup"
                chmod 700 "$work/zsetup"
                ZSETUP_BIN="$work/zsetup"
                [ "$(installer_output "$ZSETUP_BIN" --version)" = 'zsetup 0.3.0' ] || fail 'unexpected zsetup version'
                return
            fi
            fail 'zsetup bootstrap checksum failed' 11
        fi
        [ "$fetch_code" = 41 ] || fail 'HTTPS 证书、响应或下载边界检查失败；需要支持 TLS 校验的 curl 或 GNU Wget' 11
    done
    fail 'zsetup bootstrap download/checksum failed; no client changes made' 11
}
printf 'DDNSTO：安装器固定版本 %s，未查询推荐版本。\n' "$VERSION" >&2
mkdir -p "$CONFIG_DIR"
mkdir "$CONFIG_DIR/.install-lock" 2>/dev/null || fail 'another installation is active'
locked=1
if [ "$ACTION" != repair ] && [ "$ACTION" != configure ]; then
    diagnostic_event installing
    ensure_zsetup
    installer_command "$ZSETUP_BIN" download -o "$work/client.tar.gz" --sha256 "$archive_sha" \
        "https://fw.koolcenter.com/binary/ddnsto/macOS/ddnsto_darwin_cli_${VERSION}.tar.gz"
    installer_command tar -xzf "$work/client.tar.gz" -C "$work" "$member"
    [ -f "$work/$member" ] && [ ! -L "$work/$member" ] || fail 'missing regular client binary' 11
fi
# Revalidate ownership after locking; another installer may have just finished.
initial_state=$state
check_state
[ "$initial_state" = "$state" ] || fail 'installation changed; retry'
if [ "$default_install" = 1 ] && [ "$state" != absent ]; then check_account; fi
if [ "$ACTION" = update ] || [ "$state" = retained ] || { [ "$default_install" = 1 ] && [ "$state" != absent ]; }; then
    selected_version=$installed_version
    check_version
    [ "$selected_version" = "$installed_version" ] || fail '版本凭据已变化，请重新运行'
fi
check_job
mkdir -p "$CONFIG_DIR" "$INSTALL_DIR" "$AGENTS_DIR"
chmod 700 "$CONFIG_DIR"
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
if [ -f "$receipt" ]; then cp -p "$receipt" "$work/old-receipt"; had_receipt=1; fi
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
    printf '%s\n' 'DDNSTO：正在重新启用用户登录服务。' >&2
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
diagnostic_event starting
launchctl bootstrap "$domain" "$plist"
launchctl kickstart -k "$domain/$LABEL"
stable_running
if [ "$ACTION" = repair ] || [ "$ACTION" = configure ]; then
    : # Preserve the version receipt for operations that keep the binary.
else
    digest=$(shasum -a 256 "$binary")
    printf '%s %s\n' "$VERSION" "${digest%% *}" > "$work/receipt"
    cp "$work/receipt" "$receipt"
    chmod 600 "$receipt"
fi
printf '%s\n' 'ddnsto-macos-v1' > "$marker"
changed=0
case "$ACTION" in
    repair|configure) result_label=启动成功; result_version=${installed_version:-unknown} ;;
    *) result_label=安装成功; result_version=$VERSION ;;
esac
printf '%s\n' "DDNSTO $result_version: operation=$ACTION local_service=running cloud_status=unverified" \
    "$result_label：本地服务稳定运行，已启用登录启动；未检查云端状态。"
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
    case "$(uname -s 2>/dev/null || true)" in
        Darwin)
            ZSETUP_ARTIFACT="zsetup-macos-$ZSETUP_ARCH"
            ZSETUP_STABLE_PATH=zsetup/stable-macos ;;
        Linux)
            ZSETUP_ARTIFACT="zsetup-linux-$ZSETUP_ARCH"
            ZSETUP_STABLE_PATH=zsetup/stable ;;
        *) echo "zsetup: unsupported operating system" >&2; return 2 ;;
    esac
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
        [ "$compatibility_minor" -ge 5 ] || return 1
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
        bootstrap_fetch_from_base "$scheme" "$base" "$ZSETUP_STABLE_PATH" "$stable_file" || continue
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

# Shared Linux installer policy. Native facts come only from canonical Rust
# zsetup; this file does not download, execute metadata or install packages.

installer_storage_error() { printf 'Installer storage: %s\n' "$*" >&2; }

installer_valid_directory() {
    case "$1" in
        /*) ;;
        *) installer_storage_error 'directory must be absolute'; return 2 ;;
    esac
    case "$1" in
        /|*/../*|*/..|*/./*|*/.|*//*|*'
'*|*'	'*) installer_storage_error 'directory must be a normalized non-root path'; return 2 ;;
    esac
}

# Pure layout; no directory is created and no permission is inferred from UID.
# The business adapter must separately validate that the requested scope works.
installer_layout() {
    is_app=$1
    case "$is_app" in ''|*[!a-z0-9_-]*) return 2 ;; esac
    INSTALLER_SCOPE=${installer_scope:-$2}
    case "$INSTALLER_SCOPE" in user|system) ;; *) installer_storage_error 'scope must be user or system'; return 2 ;; esac
    if [ "$INSTALLER_SCOPE" = user ]; then
        : "${HOME:?HOME is required for user installation}"
        installer_valid_directory "$HOME" || return $?
        INSTALLER_PREFIX=${installer_prefix:-$HOME/.local/lib/linkease/$is_app}
        INSTALLER_COMMAND="$HOME/.local/bin/$is_app"
    else
        INSTALLER_PREFIX=${installer_prefix:-/opt/linkease/$is_app}
        INSTALLER_COMMAND="$INSTALLER_PREFIX/current/bin/$is_app"
    fi
    INSTALLER_PREFIX=${INSTALLER_PREFIX%/}
    installer_valid_directory "$INSTALLER_PREFIX"
}

# Extra simultaneously needed bytes: download + expanded files + commit copies
# + backup copies. An existing version already occupies disk; count it again
# only if this transaction creates an additional copy. Unknown sizes are errors.
# Keep arithmetic within signed 32-bit POSIX shell range, including the margin.
installer_space_budget() {
    [ "$#" = 4 ] || return 2
    is_sum=0
    for is_size in "$@"; do
        case "$is_size" in ''|*[!0-9]*) installer_storage_error 'artifact size budget is unknown or invalid'; return 2 ;; esac
        [ "${#is_size}" -le 10 ] && [ "$is_size" -le 1900000000 ] || return 2
        # Reject leading zeroes so shell arithmetic cannot interpret octal.
        case "$is_size" in 0) ;; 0*) return 2 ;; esac
        is_sum=$((is_sum + is_size))
        [ "$is_sum" -le 1900000000 ] || return 2
    done
    INSTALLER_REQUIRED_BYTES=$((is_sum + (is_sum + 9) / 10 + 8388608))
}

# Check at planning and again under the installation lock before activation.
# Arguments: path, peak-extra byte budget, executes-files(0/1), needs-write(0/1).
# Explicit target paths do not silently authorize tmpfs or unknown backing.
installer_storage_check() {
    is_path=$1; is_needed=$2; is_exec=$3; is_write=$4
    case "$is_needed" in ''|*[!0-9]*) return 2 ;; esac
    [ "${#is_needed}" -le 10 ] && [ "$is_needed" -le 2147483647 ] || return 2
    case "$is_exec:$is_write" in 0:0|0:1|1:0|1:1) ;; *) return 2 ;; esac
    is_memory=$("$ZSETUP_BIN" storage "$is_path" get memory_backed) || {
        installer_storage_error 'storage probe unavailable; a Rust zsetup with storage support is required'; return 12;
    }
    case "$is_memory" in
        false) ;;
        true) installer_storage_error "memory filesystem at $is_path; choose a persistent directory"; return 12 ;;
        *) installer_storage_error "cannot establish persistent backing at $is_path; choose a verified directory"; return 12 ;;
    esac
    is_readonly=$("$ZSETUP_BIN" storage "$is_path" get read_only) || return 12
    [ "$is_readonly" = false ] || { installer_storage_error "read-only or unknown mount at $is_path"; return 12; }
    if [ "$is_exec" = 1 ]; then
        is_noexec=$("$ZSETUP_BIN" storage "$is_path" get noexec) || return 12
        [ "$is_noexec" = false ] || { installer_storage_error "execution is unavailable at $is_path"; return 12; }
    fi
    if [ "$is_write" = 1 ]; then
        is_writable=$("$ZSETUP_BIN" storage "$is_path" get writable) || return 12
        [ "$is_writable" = true ] || { installer_storage_error "write permission is required at $is_path"; return 12; }
    fi
    is_available=$("$ZSETUP_BIN" storage "$is_path" get available_bytes) || return 12
    case "$is_available" in ''|*[!0-9]*) return 12 ;; esac
    [ "$is_available" -ge "$is_needed" ] || {
        installer_storage_error "insufficient space at $is_path: need $is_needed bytes, available $is_available; choose another directory"; return 12;
    }
    is_inodes=$("$ZSETUP_BIN" storage "$is_path" get available_inodes) || return 12
    case "$is_inodes" in
        unknown) installer_storage_error "inode availability is unknown at $is_path" ;;
        ''|*[!0-9]*) return 12 ;;
        *) [ "$is_inodes" -gt 0 ] || { installer_storage_error "no free inodes at $is_path"; return 12; } ;;
    esac
}

# Directory selection never creates files. In unattended mode a failed check
# is terminal; only an actual foreground terminal may supply another location.
installer_storage_select() {
    INSTALLER_STORAGE_PATH=$1
    is_select_needed=$2; is_select_exec=$3; is_select_write=$4
    while :; do
        if installer_storage_check "$INSTALLER_STORAGE_PATH" "$is_select_needed" "$is_select_exec" "$is_select_write"; then
            return 0
        fi
        [ -t 0 ] || return 12
        printf 'Enter another persistent absolute directory (empty cancels): ' >&2
        IFS= read -r INSTALLER_STORAGE_PATH || return 12
        [ -n "$INSTALLER_STORAGE_PATH" ] || return 12
        installer_valid_directory "$INSTALLER_STORAGE_PATH" || return 2
    done
}

# A single peak budget covers both locations when they share a filesystem;
# checking the same budget on each path does not sum it twice. No files created.
installer_preflight() {
    installer_layout "$1" "$2" || return $?
    installer_storage_select "$INSTALLER_PREFIX" "$3" 1 "$4" || return $?
    INSTALLER_PREFIX=$INSTALLER_STORAGE_PATH
    INSTALLER_WORK_ROOT=${installer_work_dir:-${ZSETUP_WORK_DIR:-$INSTALLER_PREFIX/.staging}}
    installer_valid_directory "$INSTALLER_WORK_ROOT" || return $?
    installer_storage_select "$INSTALLER_WORK_ROOT" "$3" 1 "$4" || return $?
    INSTALLER_WORK_ROOT=$INSTALLER_STORAGE_PATH
    printf 'Install plan: application=%s scope=%s prefix=%s staging=%s peak-extra-bytes=%s\n' \
        "$1" "$INSTALLER_SCOPE" "$INSTALLER_PREFIX" "$INSTALLER_WORK_ROOT" "$3" >&2
}

# Compatibility B: measured ceilings, not authoritative artifact size metadata.
# Measurements: docs/2026-10-16-storage-measurements.json. Ceilings allow growth;
# a future product above them needs reviewed new script policy, never bypasses.
installer_policy() {
    INSTALLER_DOWNLOAD_BYTES=0; INSTALLER_EXPANDED_BYTES=0; INSTALLER_FILE_COUNT=0
    INSTALLER_RESERVE=8388608
    case "$1" in
        fastnet|fastpve|linkspace|ks-cli|kspeeder) INSTALLER_MAX_DOWNLOAD=33554432; INSTALLER_MAX_EXPANDED=0; INSTALLER_MAX_FILES=1 ;;
        ddnsto) INSTALLER_MAX_DOWNLOAD=33554432; INSTALLER_MAX_EXPANDED=67108864; INSTALLER_MAX_FILES=16 ;;
        linkease) INSTALLER_MAX_DOWNLOAD=134217728; INSTALLER_MAX_EXPANDED=268435456; INSTALLER_MAX_FILES=128 ;;
        *) return 2 ;;
    esac
    ib_commit_budget=$INSTALLER_MAX_EXPANDED
    [ "$ib_commit_budget" != 0 ] || ib_commit_budget=$INSTALLER_MAX_DOWNLOAD
    installer_space_budget "$INSTALLER_MAX_DOWNLOAD" "$INSTALLER_MAX_EXPANDED" "$ib_commit_budget" 0
    printf '%s\n' 'Artifact size metadata is incomplete; using measured safety ceilings, not a guaranteed space estimate.' >&2
}

installer_file_size() {
    [ -f "$1" ] && [ ! -L "$1" ] || return 11
    set -- $(wc -c < "$1")
    case "$1" in ''|*[!0-9]*) return 11 ;; esac
    INSTALLER_FILE_SIZE=$1
}

# Single canonical download adapter shared by all business policies. Metadata
# remains data; no source/eval, redirects/HTTPS/roots/SHA remain native-owned.
installer_download() {
    ib_relative=$1; ib_output=$2; ib_sha=${3:-}; ib_fresh=${4:-0}; ib_expected_size=${5:-}
    case "${ib_relative##*/}" in
        version.txt|ks-cli-version.txt|VERSION|VERSION_LITE|SHA256SUMS) ib_metadata=1; ib_limit=16384 ;;
        *) ib_metadata=0; ib_limit=$((INSTALLER_MAX_DOWNLOAD - INSTALLER_DOWNLOAD_BYTES)); [ "$ib_limit" -gt 0 ] || return 11 ;;
    esac
    # Cross-UID inputs are copied into the root-owned destination with native
    # bounds, then the ordinary native download path revalidates their digest.
    # Untrusted metadata is never imported as the root phase's authority.
    if [ "$ib_metadata" = 0 ] && [ -n "${ZSETUP_PRIVILEGED_STAGE:-}" ] && [ -n "$ib_sha" ]; then
        ib_prepared="$ZSETUP_PRIVILEGED_STAGE/${ib_relative##*/}"
        if [ -f "$ib_prepared" ] && [ ! -L "$ib_prepared" ]; then
            installer_exec_native "$ZSETUP_BIN" capture -o "$ib_output" --max-bytes "$ib_limit" --min-free-bytes "$INSTALLER_RESERVE" --timeout 30s -- cat "$ib_prepared" || return $?
        fi
    fi
    set -- "$ZSETUP_BIN" download -o "$ib_output" --max-bytes "$ib_limit" --min-free-bytes "$INSTALLER_RESERVE"
    [ -z "$ib_sha" ] || set -- "$@" --sha256 "$ib_sha"
    [ -z "${ib_expected_size:-}" ] || set -- "$@" --size "$ib_expected_size"
    [ "$ib_fresh" = 0 ] || set -- "$@" --no-cache
    [ -z "${ZSETUP_CA_FILE:-}" ] || set -- "$@" --ca-file "$ZSETUP_CA_FILE"
    for ib_base in $ZSETUP_SOURCE_BASES; do set -- "$@" "${ib_base%/}/$INSTALLER_REMOTE_APP/$ib_relative"; done
    [ -z "${ZSETUP_SOURCE_FALLBACK:-}" ] || set -- "$@" --fallback-url "${ZSETUP_SOURCE_FALLBACK%/}/$INSTALLER_REMOTE_APP/$ib_relative"
    installer_exec_native "$@" || return $?
    if [ "$ib_metadata" = 0 ]; then
        installer_file_size "$ib_output" || return $?
        INSTALLER_DOWNLOAD_BYTES=$((INSTALLER_DOWNLOAD_BYTES + INSTALLER_FILE_SIZE))
        [ "$INSTALLER_DOWNLOAD_BYTES" -le "$INSTALLER_MAX_DOWNLOAD" ] || return 11
    fi
}

installer_extract_member() {
    ib_output=$1; shift
    ib_remaining=$((INSTALLER_MAX_EXPANDED - INSTALLER_EXPANDED_BYTES))
    [ "$ib_remaining" -gt 0 ] && [ "$INSTALLER_FILE_COUNT" -lt "$INSTALLER_MAX_FILES" ] || return 11
    installer_exec_native "$ZSETUP_BIN" capture -o "$ib_output" --max-bytes "$ib_remaining" --min-free-bytes "$INSTALLER_RESERVE" -- "$@" || return $?
    installer_file_size "$ib_output" || return $?
    [ "$INSTALLER_FILE_SIZE" -gt 0 ] || return 11
    INSTALLER_EXPANDED_BYTES=$((INSTALLER_EXPANDED_BYTES + INSTALLER_FILE_SIZE))
    INSTALLER_FILE_COUNT=$((INSTALLER_FILE_COUNT + 1))
}

installer_exec_native() {
    if [ "${INSTALLER_TRANSACTION_ACTIVE:-0}" = 1 ]; then installer_owned_native "$@"; else "$@"; fi
}

# One shell coordinator owns the lease, transaction, native child and cleanup.
# Native download/capture own their task/connection/process trees. Do not wrap
# them in another run owner that could SIGKILL a coordinator before its join.
installer_transaction_begin() {
    umask 077
    INSTALLER_CHILD=
    INSTALLER_SPAWNING=0
    INSTALLER_SIGNAL=0
    INSTALLER_LOCK_HELD=0
    INSTALLER_TRANSACTION_ACTIVE=0
    transaction_dir=
    [ ! -L "$INSTALLER_WORK_ROOT" ] || return 12
    mkdir -p "$INSTALLER_WORK_ROOT" || return 12
    [ "$("$ZSETUP_BIN" storage "$INSTALLER_WORK_ROOT" get private_directory)" = true ] || {
        printf 'Installer: staging must be a private directory owned by the current user: %s\n' "$INSTALLER_WORK_ROOT" >&2
        return 12
    }
    INSTALLER_LOCK="$INSTALLER_WORK_ROOT/.install-lock"
    if ! mkdir "$INSTALLER_LOCK" 2>/dev/null; then
        printf 'Installer: active or interrupted transaction at %s; inspect/recover it before retrying.\n' "$INSTALLER_LOCK" >&2
        return 2
    fi
    INSTALLER_LOCK_HELD=1
    trap 'installer_transaction_exit $?' EXIT
    trap 'installer_transaction_signal 129' HUP
    trap 'installer_transaction_signal 130' INT
    trap 'installer_transaction_signal 143' TERM
    printf '%s\n' "$$" > "$INSTALLER_LOCK/owner"
    transaction_dir=$(mktemp -d "$INSTALLER_WORK_ROOT/.transaction.XXXXXX") || return 12
    printf '%s\n' "$$" > "$transaction_dir/.owner"
    INSTALLER_TRANSACTION_ACTIVE=1
}

installer_transaction_signal() {
    INSTALLER_SIGNAL=$1
    # During spawn, record the signal until the PID has been adopted. All other
    # phases exit through the single cleanup coordinator immediately.
    [ "$INSTALLER_SPAWNING" = 1 ] || exit "$INSTALLER_SIGNAL"
}

installer_owned_native() {
    [ "$1" = "$ZSETUP_BIN" ] || return 2
    [ "$INSTALLER_SIGNAL" = 0 ] || return "$INSTALLER_SIGNAL"
    INSTALLER_SPAWNING=1
    if [ "${INSTALLER_BRIDGE_OPEN:-0}" = 1 ]; then
        "$@" <&0 3>&- 4>&- &
    else
        "$@" <&0 &
    fi
    INSTALLER_CHILD=$!
    INSTALLER_SPAWNING=0
    [ "$INSTALLER_SIGNAL" = 0 ] || exit "$INSTALLER_SIGNAL"
    it_status=0
    wait "$INSTALLER_CHILD" || it_status=$?
    INSTALLER_CHILD=
    return "$it_status"
}

installer_transaction_cleanup() {
    if [ -n "$INSTALLER_CHILD" ]; then
        kill -TERM "$INSTALLER_CHILD" 2>/dev/null || true
        wait "$INSTALLER_CHILD" 2>/dev/null || true
        INSTALLER_CHILD=
    fi
    # Business rollback runs only after all native operations have joined.
    if [ -n "${INSTALLER_CLEANUP_HOOK:-}" ]; then
        # The original signal exit is retained by transaction_exit. Recovery
        # itself must be allowed to run joined native operations after cancel.
        INSTALLER_SIGNAL=0
        "$INSTALLER_CLEANUP_HOOK" || {
            printf 'Installer: recovery incomplete; staging and lease retained at %s\n' "$INSTALLER_WORK_ROOT" >&2
            return 12
        }
    fi
    if [ -n "$transaction_dir" ]; then
        case "$transaction_dir" in "$INSTALLER_WORK_ROOT"/.transaction.*) ;; *) return 12 ;; esac
        [ ! -L "$transaction_dir" ] && [ ! -L "$transaction_dir/.owner" ] && [ -f "$transaction_dir/.owner" ] || return 12
        set -- $(wc -c < "$transaction_dir/.owner")
        [ "$1" -le 16 ] || return 12
        it_owner=
        IFS= read -r it_owner < "$transaction_dir/.owner" || return 12
        [ "$it_owner" = "$$" ] || return 12
        rm -rf "$transaction_dir" || return 12
        transaction_dir=
    fi
    if [ "$INSTALLER_LOCK_HELD" = 1 ]; then
        rm -f "$INSTALLER_LOCK/owner" || return 12
        rmdir "$INSTALLER_LOCK" || return 12
        INSTALLER_LOCK_HELD=0
    fi
    INSTALLER_TRANSACTION_ACTIVE=0
}

installer_transaction_exit() {
    it_exit=$1
    INSTALLER_EXIT_CODE=$it_exit
    trap - EXIT
    trap '' HUP INT TERM
    installer_transaction_cleanup || { [ "$it_exit" != 0 ] || it_exit=12; }
    exit "$it_exit"
}

installer_transaction_finish() {
    INSTALLER_EXIT_CODE=0
    installer_transaction_cleanup || return $?
    trap - EXIT HUP INT TERM
}

# Common options precede business arguments; -- ends installer parsing.
installer_dispatch() {
    il_app=$1; shift
    installer_scope=${ZSETUP_INSTALL_SCOPE:-}
    installer_prefix=${ZSETUP_INSTALL_PREFIX:-}
    installer_work_dir=
    il_seen_scope=0; il_seen_prefix=0; il_seen_work=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --installer-scope|--installer-prefix|--installer-work-dir)
                [ "$#" -ge 2 ] && [ -n "$2" ] || return 2
                case "$1" in
                    --installer-scope) [ "$il_seen_scope" = 0 ] || return 2; installer_scope=$2; il_seen_scope=1 ;;
                    --installer-prefix) [ "$il_seen_prefix" = 0 ] || return 2; installer_prefix=$2; il_seen_prefix=1 ;;
                    *) [ "$il_seen_work" = 0 ] || return 2; installer_work_dir=$2; il_seen_work=1 ;;
                esac
                shift 2 ;;
            --) shift; break ;;
            --installer-*) printf 'Unknown installer option: %s\n' "$1" >&2; return 2 ;;
            *) break ;;
        esac
    done
    # Application ids are fixed safe tokens; split/join needs no external tool.
    il_function=$(IFS=-; set -- $il_app; IFS=_; printf '%s' "$*")
    "${il_function}_install" "$@"
}

# Linux system-service adapter. Business programs own registration/configuration;
# this coordinator owns protected payloads, activation, health and rollback.
# An optional unprivileged preparation hands off to a distinct root owner;
# the control pipe requests cancellation and the root owner joins rollback.
installer_require_root() {
    if [ "$("$ZSETUP_BIN" storage / get effective_uid)" != 0 ]; then
        printf '%s\n' 'Installer: this operation installs a system service and requires root.' \
            'Run the downloaded installer explicitly with sudo (or from a root shell); unattended installation never requests a password.' >&2
        return 2
    fi
}

installer_service_prepare() {
    SERVICE_APP=$1
    installer_layout "$1" system || return $?
    [ "$INSTALLER_SCOPE" = system ] || { printf 'Installer: %s requires system scope; user services are not supported.\n' "$1" >&2; return 2; }
    installer_require_root || return $?
    installer_policy "$1" || return $?
    installer_preflight "$1" system "$INSTALLER_REQUIRED_BYTES" 1 || return $?
    for service_protected_path in "$INSTALLER_PREFIX" "$INSTALLER_WORK_ROOT"; do
        [ "$("$ZSETUP_BIN" storage "$service_protected_path" get system_protected)" = true ] || {
            printf 'Installer: system payload/staging ancestors must be root-owned, without symlinks or group/other write access: %s\n' "$service_protected_path" >&2; return 12;
        }
    done
    case "$1" in
        ddnsto) SERVICE_NAME=com.linkease.ddnstoshell.service; SERVICE_CONFIG=/etc/ddnsto/ddnsto-config.json ;;
        linkease) SERVICE_NAME=com.linkease.linkeasedaemon.service; SERVICE_CONFIG= ;;
        *) return 2 ;;
    esac
    SERVICE_UNIT="/etc/systemd/system/$SERVICE_NAME"
    SERVICE_BACKEND=systemd
    if [ ! -d /run/systemd/system ] || ! command -v systemctl >/dev/null 2>&1; then
        printf '%s\n' 'Installer: migration of non-systemd service supervision is pending; retain the legacy installer for this system.' >&2
        return 2
    fi
    [ "$("$ZSETUP_BIN" storage "$SERVICE_UNIT" get system_protected)" = true ] || return 12
    if [ -n "$SERVICE_CONFIG" ]; then
        [ "$("$ZSETUP_BIN" storage "$SERVICE_CONFIG" get system_protected)" = true ] || return 12
    fi
    SERVICE_OLD=
    SERVICE_CHANGED=0; SERVICE_NEW_VERSION=0; SERVICE_CANDIDATE=; SERVICE_GOOD=0
    SERVICE_HAD_UNIT=0; SERVICE_WAS_ACTIVE=0; SERVICE_WAS_ENABLED=0; SERVICE_HAD_CONFIG=0; SERVICE_CONFIG_TOUCHED=0
    SERVICE_DEST_LOCK_HELD=0
    SERVICE_COMMAND="${HOME:?HOME is required}/.local/bin/$SERVICE_APP"
    SERVICE_ALIAS_USER=
    case "${SUDO_UID:-0}" in ''|*[!0-9]*) return 2 ;; esac
    if [ "${SUDO_UID:-0}" != 0 ]; then
        command -v getent >/dev/null 2>&1 && command -v runuser >/dev/null 2>&1 || {
            printf '%s\n' 'Installer: getent and runuser are required to create the sudo caller command without root writes into its HOME.' >&2; return 2;
        }
        SERVICE_ALIAS_USER=pending
    elif [ "$("$ZSETUP_BIN" storage "${SERVICE_COMMAND%/*}" get system_protected)" != true ]; then
        printf '%s\n' 'Installer: invoke sudo with its root HOME; do not preserve a user-writable HOME for root writes.' >&2; return 2;
    fi
    # Unknown old files or service definitions are migration conflicts, never
    # an invitation to stop another installer or replace package-owned files.
    if [ -e "$INSTALLER_PREFIX/.managed" ] || [ -L "$INSTALLER_PREFIX/.managed" ]; then
        [ "$("$ZSETUP_BIN" storage "$INSTALLER_PREFIX/.managed" get system_protected)" = true ] || return 12
        installer_file_size "$INSTALLER_PREFIX/.managed" || return 2
        [ "$INSTALLER_FILE_SIZE" -le 65 ] || return 2
        IFS= read -r service_owner < "$INSTALLER_PREFIX/.managed" || return 2
        [ "$service_owner" = "$SERVICE_APP" ] || return 2
        [ "$("$ZSETUP_BIN" storage "$INSTALLER_PREFIX" get system_protected)" = true ] || return 12
    else
        for service_entry in "$INSTALLER_PREFIX"/* "$INSTALLER_PREFIX"/.[!.]* "$INSTALLER_PREFIX"/..?*; do
            [ ! -e "$service_entry" ] && [ ! -L "$service_entry" ] || { printf 'Installer: unowned installation at %s\n' "$INSTALLER_PREFIX" >&2; return 2; }
        done
        for service_legacy in "/usr/bin/$1" "/usr/local/bin/$1" "/usr/sbin/$1" "$SERVICE_UNIT" "/etc/init.d/$SERVICE_NAME" "/etc/init.d/${SERVICE_NAME%.service}"; do
            [ ! -e "$service_legacy" ] && [ ! -L "$service_legacy" ] || { printf 'Installer: existing installation requires explicit migration: %s\n' "$service_legacy" >&2; return 2; }
        done
    fi
    for service_path in "$INSTALLER_PREFIX/versions" "$INSTALLER_PREFIX/.managed"; do [ ! -L "$service_path" ] || return 2; done
    installer_service_read_current || return $?
    umask 022
    mkdir -p "$INSTALLER_PREFIX" "$INSTALLER_PREFIX/versions" || return 12
    [ "$("$ZSETUP_BIN" storage "$INSTALLER_PREFIX/versions" get system_protected)" = true ] || return 12
    if [ ! -e "$INSTALLER_PREFIX/.managed" ]; then
        (set -C; printf '%s\n' "$SERVICE_APP" > "$INSTALLER_PREFIX/.managed") || return 2
    fi
    installer_transaction_begin || return $?
    INSTALLER_CLEANUP_HOOK=installer_service_cleanup
    # Optional app-wide lease: acquired before destination snapshots and held
    # through recovery. The hook may extend cleanup, never replace rollback.
    if command -v "${SERVICE_APP}_service_lock" >/dev/null 2>&1; then
        "${SERVICE_APP}_service_lock" || return $?
    fi
    if ! mkdir "$INSTALLER_PREFIX/.service-lock" 2>/dev/null; then
        printf 'Installer: active or interrupted destination transaction at %s/.service-lock\n' "$INSTALLER_PREFIX" >&2; return 2
    fi
    SERVICE_DEST_LOCK_HELD=1
    printf '%s\n' "$$" > "$INSTALLER_PREFIX/.service-lock/owner"
    # The preliminary check is read-only. Another coordinator may have
    # committed between it and our lock acquisition; snapshot only now.
    installer_service_read_current || return $?
    if [ "$SERVICE_ALIAS_USER" = pending ]; then
        installer_exec_native "$ZSETUP_BIN" capture -o "$transaction_dir/passwd" --max-bytes 4096 --timeout 5s -- getent passwd "$SUDO_UID" || return 2
        IFS=: read -r service_user service_pass service_uid service_gid service_gecos service_home service_shell < "$transaction_dir/passwd" || return 2
        [ "$service_uid" = "$SUDO_UID" ] && [ "$service_uid" != 0 ] && [ -n "$service_user" ] || return 2
        installer_valid_directory "$service_home" || return 2
        SERVICE_ALIAS_USER=$service_user
        SERVICE_COMMAND="$service_home/.local/bin/$SERVICE_APP"
    fi
    installer_exec_native "$ZSETUP_BIN" capture -o "$transaction_dir/fragment" --max-bytes 4096 --timeout 5s -- systemctl show --property=FragmentPath --value "$SERVICE_NAME" || return $?
    service_fragment=
    IFS= read -r service_fragment < "$transaction_dir/fragment" || service_fragment=
    [ -z "$service_fragment" ] || { [ "$service_fragment" = "$SERVICE_UNIT" ] && [ "$SERVICE_HAD_UNIT" = 1 ]; } || {
        printf 'Installer: existing service belongs to another installation: %s\n' "$service_fragment" >&2; return 2;
    }
    if [ "$SERVICE_HAD_UNIT" = 1 ]; then
        cp -p "$SERVICE_UNIT" "$transaction_dir/old-unit" || return 12
        if installer_service_manager is-active; then SERVICE_WAS_ACTIVE=1; fi
        if installer_service_manager is-enabled; then SERVICE_WAS_ENABLED=1; fi
    fi
    if [ -n "$SERVICE_CONFIG" ] && [ -e "$SERVICE_CONFIG" ]; then
        [ "$("$ZSETUP_BIN" storage "$SERVICE_CONFIG" get system_protected)" = true ] || return 12
        installer_file_size "$SERVICE_CONFIG" || return 2
        [ "$INSTALLER_FILE_SIZE" -le 16384 ] || return 11
        cp -p "$SERVICE_CONFIG" "$transaction_dir/old-config" || return 12
        SERVICE_HAD_CONFIG=1
    fi
    # This alias belongs to the invoking account. Privilege boundaries never
    # follow arbitrary HOME links to write a root-owned system file.
    if [ -z "$SERVICE_ALIAS_USER" ] && { [ -e "$SERVICE_COMMAND" ] || [ -L "$SERVICE_COMMAND" ]; }; then
        [ -L "$SERVICE_COMMAND" ] && [ "$(readlink "$SERVICE_COMMAND")" = "$INSTALLER_PREFIX/current/bin/$SERVICE_APP" ] || return 2
    fi
}

installer_service_read_current() {
    SERVICE_OLD=; SERVICE_HAD_UNIT=0
    if [ -L "$INSTALLER_PREFIX/current" ]; then
        SERVICE_OLD=$(readlink "$INSTALLER_PREFIX/current") || return 2
        case "$SERVICE_OLD" in versions/*) ;; *) return 2 ;; esac
        service_old_version=${SERVICE_OLD#versions/}
        installer_service_version "$service_old_version" || return 2
        [ -x "$INSTALLER_PREFIX/$SERVICE_OLD/bin/$SERVICE_APP" ] || return 2
        [ "$("$ZSETUP_BIN" storage "$INSTALLER_PREFIX/$SERVICE_OLD/bin/$SERVICE_APP" get system_protected)" = true ] || return 12
    elif [ -e "$INSTALLER_PREFIX/current" ]; then return 2
    fi
    if [ -e "$SERVICE_UNIT" ] || [ -L "$SERVICE_UNIT" ]; then
        [ -n "$SERVICE_OLD" ] || return 2
        installer_service_definition "$INSTALLER_PREFIX/$SERVICE_OLD/bin/$SERVICE_APP" || return 2
        SERVICE_HAD_UNIT=1
    fi
}

installer_service_alias() {
    # All user-controlled path traversal happens after dropping privilege.
    # Values are argv data, never interpolated into the fixed shell program.
    set -- /bin/sh -c 'set -eu
umask 077
directory=$1; application=$2; target=$3
command_path="$directory/$application"
if [ -e "$command_path" ] || [ -L "$command_path" ]; then
    [ -L "$command_path" ] && [ "$(readlink "$command_path")" = "$target" ] || exit 2
fi
mkdir -p "$directory"
candidate="$directory/.$application.$$"
trap '\''rm -f "$candidate"'\'' EXIT
ln -s "$target" "$candidate"
mv -f "$candidate" "$command_path"
' installer-alias "${SERVICE_COMMAND%/*}" "$SERVICE_APP" "$INSTALLER_PREFIX/current/bin/$SERVICE_APP"
    if [ -n "$SERVICE_ALIAS_USER" ]; then
        installer_exec_native "$ZSETUP_BIN" run -- runuser -u "$SERVICE_ALIAS_USER" -- "$@"
    else
        installer_exec_native "$ZSETUP_BIN" run -- "$@"
    fi
}

installer_service_version() {
    case "$1" in ''|*[!0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._+-]*|.*|-*|+*|_*) return 2 ;; esac
    [ "${#1}" -le 64 ]
}

installer_service_manager() {
    service_action=$1
    if [ "$SERVICE_BACKEND" = systemd ]; then
        case "$service_action" in
            is-active|is-enabled) installer_exec_native "$ZSETUP_BIN" run -- systemctl "$service_action" --quiet "$SERVICE_NAME" ;;
            reload) installer_exec_native "$ZSETUP_BIN" run -- systemctl daemon-reload ;;
            *) installer_exec_native "$ZSETUP_BIN" run -- systemctl "$service_action" "$SERVICE_NAME" ;;
        esac
    else
        case "$service_action" in
            reload|enable|disable) return 0 ;;
            is-active) service_action=status ;;
        esac
        installer_exec_native "$ZSETUP_BIN" run -- "$SERVICE_UNIT" "$service_action"
    fi
}

# Bounded files produced by the trusted native product only. Never source/eval
# a unit or execute configuration contents in the installer.
installer_service_definition() {
    installer_file_size "$SERVICE_UNIT" || return 2
    [ "$INSTALLER_FILE_SIZE" -le 16384 ] || return 11
    [ "$("$ZSETUP_BIN" storage "$SERVICE_UNIT" get system_protected)" = true ] || return 12
    service_expected=$1
    installer_service_escape_exec "$service_expected"
    service_expected_escaped=$service_escaped
    installer_service_escape_exec "${service_expected%/*}/.service-run"
    service_expected_wrapper=$service_escaped
    service_found=0
    while IFS= read -r service_line || [ -n "$service_line" ]; do
        case "$SERVICE_BACKEND:$service_line" in
            "systemd:ExecStart=$service_expected \"run\""|"systemd:ExecStart=\"$service_expected_escaped\" \"run\"") service_found=$((service_found + 1)) ;;
            "systemd:ExecStart=/bin/sh \"$service_expected_wrapper\"") service_found=$((service_found + 1)) ;;
            sysv:*"$service_expected"*) service_found=$((service_found + 1)) ;;
        esac
    done < "$SERVICE_UNIT"
    [ "$service_found" = 1 ]
}

# POSIX literal replacement, bounded by the normalized path limit. systemd
# command parsing is not shell parsing: escape quotes/backslashes/specifiers
# and literal dollar signs independently (systemd.service Command Lines).
installer_service_replace() {
    service_replaced=
    service_rest=$1; service_needle=$2; service_replacement=$3
    while :; do
        case "$service_rest" in
            *"$service_needle"*) service_replaced="$service_replaced${service_rest%%"$service_needle"*}$service_replacement"; service_rest=${service_rest#*"$service_needle"} ;;
            *) service_replaced="$service_replaced$service_rest"; break ;;
        esac
    done
}

installer_service_escape_exec() {
    service_escaped=$1
    installer_service_replace "$service_escaped" '\' '\\'; service_escaped=$service_replaced
    installer_service_replace "$service_escaped" '"' '\"'; service_escaped=$service_replaced
    installer_service_replace "$service_escaped" '%' '%%'; service_escaped=$service_replaced
    installer_service_replace "$service_escaped" '$' '$$'; service_escaped=$service_replaced
}

installer_service_quote_unit() {
    [ "$SERVICE_BACKEND" = systemd ] || return 0
    installer_service_escape_exec "${SERVICE_EXEC%/*}/.service-run"
    service_escaped_exec=$service_escaped
    # Conditions consume a raw path with unit specifier expansion, rather than
    # command-line unquoting; only '%' needs doubling here.
    installer_service_replace "$SERVICE_EXEC" '%' '%%'
    service_condition=$service_replaced
    service_exec_count=0
    while IFS= read -r service_line || [ -n "$service_line" ]; do
        case "$service_line" in
            ExecStart=*) printf 'ExecStart=/bin/sh "%s"\n' "$service_escaped_exec"; service_exec_count=$((service_exec_count + 1)) ;;
            ConditionFileIsExecutable=*) printf 'ConditionFileIsExecutable=%s\n' "$service_condition" ;;
            *) printf '%s\n' "$service_line" ;;
        esac
    done < "$SERVICE_UNIT" > "$transaction_dir/new-unit"
    [ "$service_exec_count" = 1 ] || return 11
    installer_exec_native "$ZSETUP_BIN" capture -o "$SERVICE_UNIT" --max-bytes 16384 --min-free-bytes "$INSTALLER_RESERVE" -- cat "$transaction_dir/new-unit"
}

installer_service_cached() {
    SERVICE_VERSION=$1; SERVICE_DIGEST=$2
    installer_service_version "$SERVICE_VERSION" || return 2
    SERVICE_VERSION_DIR="$INSTALLER_PREFIX/versions/$SERVICE_VERSION"
    SERVICE_EXEC="$SERVICE_VERSION_DIR/bin/$SERVICE_APP"
    SERVICE_CACHED=0
    [ ! -L "$SERVICE_VERSION_DIR" ] || return 2
    if [ -e "$SERVICE_VERSION_DIR" ]; then
        [ "$("$ZSETUP_BIN" storage "$SERVICE_VERSION_DIR/.arch" get system_protected)" = true ] || return 12
        installer_file_size "$SERVICE_VERSION_DIR/.arch" || return 2
        [ "$INSTALLER_FILE_SIZE" -le 32 ] || return 2
        IFS= read -r service_cached_arch < "$SERVICE_VERSION_DIR/.arch" || return 2
        [ "$service_cached_arch" = "$arch" ] || {
            printf '%s\n' 'Installer: cached payload architecture differs; use a new protected prefix or explicit migration.' >&2
            return 2
        }
        installer_file_size "$SERVICE_VERSION_DIR/.artifact-sha256" || return 2
        [ "$INSTALLER_FILE_SIZE" -le 160 ] || return 2
        IFS= read -r service_digest < "$SERVICE_VERSION_DIR/.artifact-sha256" || return 2
        [ "$service_digest" = "$SERVICE_DIGEST" ] || { printf 'Installer: immutable version has a different digest.\n' >&2; return 11; }
        [ -x "$SERVICE_EXEC" ] && [ ! -L "$SERVICE_EXEC" ] || return 11
        [ -x "$SERVICE_VERSION_DIR/bin/.service-run" ] && [ ! -L "$SERVICE_VERSION_DIR/bin/.service-run" ] || return 11
        for service_cached_file in "$SERVICE_EXEC" "$SERVICE_VERSION_DIR/.artifact-sha256"; do
            [ "$("$ZSETUP_BIN" storage "$service_cached_file" get system_protected)" = true ] || return 12
        done
        installer_file_size "$SERVICE_VERSION_DIR/.files" || return 11
        [ "$INSTALLER_FILE_SIZE" -le 16384 ] || return 11
        [ "$("$ZSETUP_BIN" storage "$SERVICE_VERSION_DIR/.files" get system_protected)" = true ] || return 12
        service_cached_count=0; service_cached_bytes=0
        while IFS= read -r service_cached_relative; do
            case "$service_cached_relative" in ''|/*|*[!0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._+/-]*|../*|*/../*|*/..|./*|*/./*|*/.|*//* ) return 11 ;; esac
            service_cached_file="$SERVICE_VERSION_DIR/bin/$service_cached_relative"
            installer_file_size "$service_cached_file" || return 11
            service_cached_bytes=$((service_cached_bytes + INSTALLER_FILE_SIZE))
            service_cached_count=$((service_cached_count + 1))
            [ "$service_cached_count" -le "$INSTALLER_MAX_FILES" ] && [ "$service_cached_bytes" -le "$INSTALLER_MAX_EXPANDED" ] || return 11
            [ "$("$ZSETUP_BIN" storage "$service_cached_file" get system_protected)" = true ] || return 12
        done < "$SERVICE_VERSION_DIR/.files"
        [ "$service_cached_count" -gt 0 ] || return 11
        SERVICE_CACHED=1
        status '      Using verified cached installed version'
    fi
}

installer_service_copy() {
    service_relative=$1
    service_destination="$SERVICE_CANDIDATE/bin/$service_relative"
    mkdir -p "${service_destination%/*}" || return 12
    chmod 0755 "${service_destination%/*}"
    installer_exec_native "$ZSETUP_BIN" capture -o "$service_destination" --max-bytes "$INSTALLER_MAX_EXPANDED" --min-free-bytes "$INSTALLER_RESERVE" -- cat "$transaction_dir/products/$service_relative" || return $?
    chmod 0755 "$service_destination" || return 12
    printf '%s\n' "$service_relative" >> "$SERVICE_CANDIDATE/.files"
}

installer_service_stage() {
    SERVICE_CANDIDATE="$INSTALLER_PREFIX/versions/.candidate.$$"
    mkdir "$SERVICE_CANDIDATE" || return 12
    mkdir "$SERVICE_CANDIDATE/bin" || return 12
    chmod 0755 "$SERVICE_CANDIDATE" "$SERVICE_CANDIDATE/bin"
    : > "$SERVICE_CANDIDATE/.files"
    # systemd rejects quotes/backslashes in its executable word even when the
    # unit is correctly escaped. Its fixed executable is /bin/sh; this private,
    # root-owned wrapper performs a literal exec without evaluation of paths.
    installer_service_replace "$SERVICE_EXEC" "'" "'\\''"
    printf '#!/bin/sh\nexec '\''%s'\'' run\n' "$service_replaced" > "$SERVICE_CANDIDATE/bin/.service-run"
    chmod 0755 "$SERVICE_CANDIDATE/bin/.service-run"
    printf '%s\n' .service-run >> "$SERVICE_CANDIDATE/.files"
}

installer_service_commit_version() {
    printf '%s\n' "$SERVICE_DIGEST" > "$SERVICE_CANDIDATE/.artifact-sha256"
    printf '%s\n' "$arch" > "$SERVICE_CANDIDATE/.arch"
    chmod 0644 "$SERVICE_CANDIDATE/.artifact-sha256" "$SERVICE_CANDIDATE/.files" "$SERVICE_CANDIDATE/.arch" || return 12
    [ ! -e "$SERVICE_VERSION_DIR" ] && [ ! -L "$SERVICE_VERSION_DIR" ] || return 2
    mv "$SERVICE_CANDIDATE" "$SERVICE_VERSION_DIR" || return 12
    SERVICE_CANDIDATE=; SERVICE_NEW_VERSION=1
}

installer_service_activate() {
    installer_storage_check "$INSTALLER_PREFIX" "$INSTALLER_RESERVE" 1 1 || return $?
    [ "$("$ZSETUP_BIN" storage "$SERVICE_VERSION_DIR/bin" get system_protected)" = true ] || return 12
    if [ "$SERVICE_HAD_UNIT" = 1 ]; then installer_service_manager stop || return $?; fi
    SERVICE_CHANGED=1
    ln -s "versions/$SERVICE_VERSION" "$INSTALLER_PREFIX/.current.$$" || return 12
    mv -fT "$INSTALLER_PREFIX/.current.$$" "$INSTALLER_PREFIX/current" || return 12
    SERVICE_CONFIG_TOUCHED=1
    "${SERVICE_APP}_register" || return $?
    installer_service_definition "$SERVICE_EXEC" || { printf 'Installer: product returned success without the expected service definition.\n' >&2; return 11; }
    installer_service_quote_unit || return $?
    installer_service_manager reload || return $?
    installer_service_manager enable || return $?
    installer_service_manager start || return $?
    installer_service_manager is-active || return $?
    # Check once more after the immediate start return; an exiting daemon is
    # not accepted merely because its registration command returned zero.
    sleep 1
    installer_service_manager is-active || return $?
    # Optional business health runs inside the transaction, before aliases,
    # previous-pointer changes, the commit point, or old-version pruning.
    if command -v "${SERVICE_APP}_service_health" >/dev/null 2>&1; then
        "${SERVICE_APP}_service_health" || return $?
    fi
    installer_service_alias || return $?
    if [ -n "$SERVICE_OLD" ] && [ "$SERVICE_OLD" != "versions/$SERVICE_VERSION" ]; then
        ln -s "$SERVICE_OLD" "$INSTALLER_PREFIX/.previous.$$" || return 12
        mv -fT "$INSTALLER_PREFIX/.previous.$$" "$INSTALLER_PREFIX/previous" || return 12
    fi
    # Reach the commit point before pruning; current and previous are retained.
    SERVICE_GOOD=1; SERVICE_CHANGED=0; SERVICE_NEW_VERSION=0
    service_previous=$(readlink "$INSTALLER_PREFIX/previous" 2>/dev/null || true)
    for service_version_dir in "$INSTALLER_PREFIX"/versions/*; do
        [ -d "$service_version_dir" ] && [ ! -L "$service_version_dir" ] || continue
        service_target="versions/${service_version_dir##*/}"
        [ "$service_target" != "versions/$SERVICE_VERSION" ] && [ "$service_target" != "$service_previous" ] || continue
        [ -f "$service_version_dir/.artifact-sha256" ] && [ ! -L "$service_version_dir/.artifact-sha256" ] || continue
        rm -rf "$service_version_dir" || return 12
    done
    status "Installed $SERVICE_APP: $SERVICE_COMMAND (system service; $SERVICE_EXEC)"
}

installer_service_cleanup() {
    if [ "$SERVICE_CHANGED" = 1 ]; then
        printf 'Installer: restoring the previous installation and service.\n' >&2
        installer_service_manager stop || true
        if [ "$SERVICE_HAD_UNIT" = 1 ]; then
            cp -p "$transaction_dir/old-unit" "$SERVICE_UNIT" || return 1
        else
            installer_service_manager disable || return 1
            rm -f "$SERVICE_UNIT" || return 1
        fi
        if [ "$SERVICE_CONFIG_TOUCHED" = 1 ] && [ -n "$SERVICE_CONFIG" ]; then
            if [ "$SERVICE_HAD_CONFIG" = 1 ]; then cp -p "$transaction_dir/old-config" "$SERVICE_CONFIG" || return 1
            else rm -f "$SERVICE_CONFIG" || return 1; fi
        fi
        if [ -n "$SERVICE_OLD" ]; then
            ln -s "$SERVICE_OLD" "$INSTALLER_PREFIX/.restore.$$" || return 1
            mv -fT "$INSTALLER_PREFIX/.restore.$$" "$INSTALLER_PREFIX/current" || return 1
        else rm -f "$INSTALLER_PREFIX/current" || return 1; fi
        installer_service_manager reload || return 1
        if [ "$SERVICE_HAD_UNIT" = 1 ]; then
            if [ "$SERVICE_WAS_ENABLED" = 1 ]; then installer_service_manager enable || return 1
            else installer_service_manager disable || return 1; fi
        fi
        if [ "$SERVICE_WAS_ACTIVE" = 1 ]; then
            installer_service_manager start || return 1
            installer_service_manager is-active || return 1
        fi
        SERVICE_CHANGED=0
    fi
    [ -z "$SERVICE_CANDIDATE" ] || rm -rf "$SERVICE_CANDIDATE" || return 1
    if [ "$SERVICE_NEW_VERSION" = 1 ]; then rm -rf "$SERVICE_VERSION_DIR" || return 1; fi
    rm -f "$INSTALLER_PREFIX/.current.$$" "$INSTALLER_PREFIX/.previous.$$" "$INSTALLER_PREFIX/.restore.$$"
    if [ "$SERVICE_DEST_LOCK_HELD" = 1 ]; then
        rm -f "$INSTALLER_PREFIX/.service-lock/owner" || return 1
        rmdir "$INSTALLER_PREFIX/.service-lock" || return 1
        SERVICE_DEST_LOCK_HELD=0
    fi
}

# Native packages own their installed paths and services. Only their verified
# inputs, PM scratch/cache/list data and bounded receipts are managed here.
installer_package_prepare() {
    PACKAGE_APP=$1; PACKAGE_PHASE=preflight
    PACKAGE_CACHE=; INSTALLER_PACKAGE_CLEANUP=
    PACKAGE_DEST_LOCK_HELD=0
    PACKAGE_GLOBAL_LOCK_HELD=0
    installer_require_root || return $?
    installer_layout "$1" system || return $?
    [ "$INSTALLER_SCOPE" = system ] || return 2
    installer_policy "$1" || return $?
    # A package target cannot be relocated by changing the download directory.
    installer_storage_check / "$INSTALLER_REQUIRED_BYTES" 1 1 || {
        printf '%s\n' 'Installer: native package target / is unsuitable; moving its download cache does not relocate package-owned files. Keep the legacy entry until the system target is verified.' >&2
        return 12
    }
    installer_preflight "$1" system "$INSTALLER_REQUIRED_BYTES" 1 || return $?
    for ip_path in "$INSTALLER_PREFIX" "$INSTALLER_WORK_ROOT"; do
        [ "$("$ZSETUP_BIN" storage "$ip_path" get system_protected)" = true ] || return 12
    done
    [ ! -L "$INSTALLER_PREFIX/.managed" ] && [ ! -L "$INSTALLER_PREFIX/.package-manager" ] || return 2
    if [ -f "$INSTALLER_PREFIX/.managed" ]; then
        for ip_marker in "$INSTALLER_PREFIX/.managed" "$INSTALLER_PREFIX/.package-manager"; do
            [ "$("$ZSETUP_BIN" storage "$ip_marker" get system_protected)" = true ] || return 12
        done
        installer_file_size "$INSTALLER_PREFIX/.managed" || return 2
        [ "$INSTALLER_FILE_SIZE" -le 65 ] || return 2
        IFS= read -r ip_owner < "$INSTALLER_PREFIX/.managed" || return 2
        [ "$ip_owner" = "$PACKAGE_APP" ] || return 2
        installer_file_size "$INSTALLER_PREFIX/.package-manager" || return 2
        [ "$INSTALLER_FILE_SIZE" -le 8 ] || return 2
        IFS= read -r ip_manager < "$INSTALLER_PREFIX/.package-manager" || return 2
        [ "$ip_manager" = "$package_manager" ] || return 2
    else
        for ip_entry in "$INSTALLER_PREFIX"/* "$INSTALLER_PREFIX"/.[!.]* "$INSTALLER_PREFIX"/..?*; do
            [ ! -e "$ip_entry" ] && [ ! -L "$ip_entry" ] || return 2
        done
        umask 022
        mkdir -p "$INSTALLER_PREFIX" || return 12
        (set -C; printf '%s\n' "$PACKAGE_APP" > "$INSTALLER_PREFIX/.managed") || return 2
        (set -C; printf '%s\n' "$package_manager" > "$INSTALLER_PREFIX/.package-manager") || return 2
    fi
    [ ! -L "$INSTALLER_PREFIX/package-result" ] && [ ! -L "$INSTALLER_PREFIX/.packages" ] || return 2
    installer_transaction_begin || return $?
    INSTALLER_CLEANUP_HOOK=installer_package_cleanup
    # Native package/config state is global even when input caches use distinct
    # prefixes. This small root-owned lease serializes the whole app transaction.
    PACKAGE_GLOBAL_LOCK="/etc/zsetup/install-locks/$PACKAGE_APP"
    [ "$("$ZSETUP_BIN" storage "$PACKAGE_GLOBAL_LOCK" get system_protected)" = true ] || return 12
    umask 022
    mkdir -p /etc/zsetup/install-locks || return 12
    umask 077
    [ "$("$ZSETUP_BIN" storage /etc/zsetup/install-locks get system_protected)" = true ] || return 12
    mkdir "$PACKAGE_GLOBAL_LOCK" 2>/dev/null || return 2
    PACKAGE_GLOBAL_LOCK_HELD=1
    printf '%s\n' "$$" > "$PACKAGE_GLOBAL_LOCK/owner"
    if ! mkdir "$INSTALLER_PREFIX/.package-lock" 2>/dev/null; then
        printf 'Installer: active or interrupted destination transaction at %s/.package-lock\n' "$INSTALLER_PREFIX" >&2
        return 2
    fi
    PACKAGE_DEST_LOCK_HELD=1
    printf '%s\n' "$$" > "$INSTALLER_PREFIX/.package-lock/owner"
    mkdir -p "$transaction_dir/pm-tmp" "$transaction_dir/pm-cache" "$transaction_dir/pm-lists"
    # PMs and their maintainer scripts use disk scratch, rather than default /tmp.
    TMPDIR="$transaction_dir/pm-tmp"; export TMPDIR
    for ip_existing in "/usr/bin/$PACKAGE_APP" "/usr/sbin/$PACKAGE_APP" "/usr/local/bin/$PACKAGE_APP"; do
        [ -e "$ip_existing" ] || [ -L "$ip_existing" ] || continue
        if [ "$package_manager" = opkg ]; then
            installer_exec_native "$ZSETUP_BIN" capture -o "$transaction_dir/owner" --max-bytes 4096 --timeout 5s -- opkg search "$ip_existing" || return 2
            ip_count=0
            while IFS= read -r ip_line; do
                case "$ip_line" in "$PACKAGE_APP - "*) ip_count=$((ip_count + 1)) ;; *) return 2 ;; esac
            done < "$transaction_dir/owner"
            [ "$ip_count" = 1 ] || return 2
        else
            installer_exec_native "$ZSETUP_BIN" capture -o "$transaction_dir/owner" --max-bytes 4096 --timeout 5s -- apk info --who-owns "$ip_existing" || return 2
            IFS= read -r ip_line < "$transaction_dir/owner" || return 2
            case "$ip_line" in "$ip_existing is owned by $PACKAGE_APP-"*) ;; *) return 2 ;; esac
        fi
    done
    PACKAGE_PHASE=download
}

installer_package_cache() {
    installer_service_version "$1" || return 2
    case "$2" in x86_64|aarch64|armv7|arm|mipsel) ;; *) return 2 ;; esac
    ip_cache_root="$INSTALLER_PREFIX/.packages"
    ip_key="$package_manager-$1-$2"
    ip_previous=
    [ ! -L "$ip_cache_root/recent" ] || return 2
    if [ -f "$ip_cache_root/recent" ]; then
        installer_file_size "$ip_cache_root/recent" || return 2
        [ "$INSTALLER_FILE_SIZE" -le 128 ] || return 2
        IFS= read -r ip_previous < "$ip_cache_root/recent" || return 2
        case "$ip_previous" in ''|*[!0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._+-]*|.*) return 2 ;; esac
    fi
    PACKAGE_CACHE="$ip_cache_root/$ip_key"
    [ ! -L "$PACKAGE_CACHE" ] || return 2
    mkdir -p "$PACKAGE_CACHE" || return 12
    [ "$("$ZSETUP_BIN" storage "$PACKAGE_CACHE" get system_protected)" = true ] || return 12
    [ ! -L "$PACKAGE_CACHE/.owned" ] || return 2
    if [ -e "$PACKAGE_CACHE/.owned" ]; then
        [ "$("$ZSETUP_BIN" storage "$PACKAGE_CACHE/.owned" get system_protected)" = true ] || return 12
        installer_file_size "$PACKAGE_CACHE/.owned" || return 2
        [ "$INSTALLER_FILE_SIZE" -le 65 ] || return 2
        IFS= read -r ip_owner < "$PACKAGE_CACHE/.owned" || return 2
        [ "$ip_owner" = "$PACKAGE_APP" ] || return 2
    else
        (set -C; printf '%s\n' "$PACKAGE_APP" > "$PACKAGE_CACHE/.owned") || return 12
    fi
    # Keep the current and preceding attempt, including verified recovery inputs
    # after a partial PM failure. Never pretend this rolls back package scripts.
    for ip_old in "$ip_cache_root"/*; do
        [ -d "$ip_old" ] && [ ! -L "$ip_old" ] || continue
        [ "${ip_old##*/}" != "$ip_key" ] && [ "${ip_old##*/}" != "$ip_previous" ] || continue
        installer_file_size "$ip_old/.owned" || continue
        [ "$INSTALLER_FILE_SIZE" -le 65 ] || continue
        IFS= read -r ip_owner < "$ip_old/.owned" || continue
        [ "$ip_owner" != "$PACKAGE_APP" ] || rm -rf "$ip_old" || return 12
    done
    printf '%s\n' "$ip_key" > "$transaction_dir/recent"
    mv -f "$transaction_dir/recent" "$ip_cache_root/recent" || return 12
}

installer_package_command() {
    installer_storage_check / "$INSTALLER_RESERVE" 1 1 || return $?
    installer_storage_check "$INSTALLER_WORK_ROOT" "$INSTALLER_RESERVE" 0 1 || return $?
    PACKAGE_PHASE=$1; shift
    ip_query_output=
    if [ "$PACKAGE_PHASE" = query ]; then ip_query_output=$1; shift; fi
    case "$package_manager" in
        opkg) set -- opkg --cache "$transaction_dir/pm-cache" --tmp-dir "$transaction_dir/pm-tmp" --lists-dir "$transaction_dir/pm-lists" "$@" ;;
        apk) set -- apk --cache-dir "$transaction_dir/pm-cache" "$@" ;;
        *) return 2 ;;
    esac
    if [ -n "$ip_query_output" ]; then
        installer_exec_native "$ZSETUP_BIN" capture -o "$ip_query_output" --max-bytes 4096 --min-free-bytes "$INSTALLER_RESERVE" --timeout 5s -- "$@"
    else
        installer_exec_native "$ZSETUP_BIN" run -- "$@"
    fi
}

installer_package_immutable() {
    ip_marker=$1; ip_expected=$2
    [ ! -L "$ip_marker" ] || return 2
    if [ -f "$ip_marker" ]; then
        installer_file_size "$ip_marker" || return 2
        [ "$INSTALLER_FILE_SIZE" -le 128 ] || return 2
        IFS= read -r ip_record < "$ip_marker" || return 2
        ip_digest=${ip_record%%:*}
        case "$ip_digest" in ''|*[!0123456789abcdef]*) return 11 ;; esac
        [ "${#ip_digest}" = 64 ] && [ "$ip_digest" = "$ip_expected" ] || return 11
    fi
}

installer_package_cleanup() {
    if [ "$PACKAGE_DEST_LOCK_HELD" = 1 ]; then
    [ -z "$INSTALLER_PACKAGE_CLEANUP" ] || "$INSTALLER_PACKAGE_CLEANUP" || return 1
    printf 'application=%s\nmanager=%s\nphase=%s\nexit=%s\npackage_rollback=not_guaranteed\n' \
        "$PACKAGE_APP" "$package_manager" "$PACKAGE_PHASE" "${INSTALLER_EXIT_CODE:-0}" > "$INSTALLER_PREFIX/.package-result.$$" || return 1
    mv -f "$INSTALLER_PREFIX/.package-result.$$" "$INSTALLER_PREFIX/package-result" || return 1
    rm -f "$INSTALLER_PREFIX/.package-lock/owner" || return 1
    rmdir "$INSTALLER_PREFIX/.package-lock" || return 1
    PACKAGE_DEST_LOCK_HELD=0
    fi
    if [ "$PACKAGE_GLOBAL_LOCK_HELD" = 1 ]; then
        rm -f "$PACKAGE_GLOBAL_LOCK/owner" || return 1
        rmdir "$PACKAGE_GLOBAL_LOCK" || return 1
        PACKAGE_GLOBAL_LOCK_HELD=0
    fi
}

# Only the optional sudo bootstrap uses OS copy/hash tools. Ordinary root
# installs and all business downloads/hashes continue to use canonical zsetup.
# The root coordinator owns its monitor and installer; EOF requests cancellation
# and it joins the installer (including rollback) before releasing bootstrap files.
installer_privilege_root_code() {
    cat <<'ZSETUP_ROOT_COORDINATOR'
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin; export PATH
umask 077
exec 5>&1
exec 1>&2
root_directory=; root_child=; root_monitor=; root_ready=0; root_cancel=0; root_spawning=0
root_signal() { root_cancel=$1; trap '' HUP INT TERM; [ "$root_spawning" = 1 ] || exit "$root_cancel"; }
root_finish() {
    root_result=$1
    trap - EXIT
    trap '' HUP INT TERM
    if [ -n "$root_child" ]; then kill -TERM "$root_child" 2>/dev/null || true; wait "$root_child" 2>/dev/null || true; root_child=; fi
    if [ -n "$root_monitor" ]; then kill -TERM "$root_monitor" 2>/dev/null || true; wait "$root_monitor" 2>/dev/null || true; root_monitor=; fi
    if [ -n "$root_directory" ]; then
        case "$root_directory" in /tmp/zsetup-privileged.*) rm -rf "$root_directory" || root_result=12 ;; *) root_result=12 ;; esac
    fi
    [ "$root_ready" = 1 ] || printf E >&5
    printf '%03d\n' "$root_result" >&5 || true
    exec 5>&-
    exit "$root_result"
}
trap 'root_finish $?' EXIT
trap 'root_signal 129' HUP
trap 'root_signal 130' INT
trap 'root_signal 143' TERM
[ "$(id -u)" = 0 ] && [ "$1" = "${SUDO_UID:-0}" ] || exit 2
root_caller=$1; root_native=$2; root_native_sha=$3; root_program=$4; root_program_sha=$5
root_ca=$6; root_ca_sha=$7; root_prepared=$8; root_os=$9
shift 9
root_pm=$1; root_arch=$2; root_bases=$3; root_fallback=$4; root_prefix=$5; root_version=$6
shift 6
root_directory=$(mktemp -d /tmp/zsetup-privileged.XXXXXX) || exit 12
root_parent=$$
IFS= read -r root_stat < "/proc/$root_parent/stat" || exit 12
set -f; set -- "$@" # do not expand proc text as filenames in the monitor
# Save business argv before inspecting /proc positional fields in a function.
root_cookie() { IFS= read -r rc_line < "/proc/$root_parent/stat" || return 1; set -- $rc_line; [ "$#" -ge 22 ] || return 1; shift 21; printf '%s\n' "$1"; }
root_birth=$(root_cookie) || exit 12
exec 6<&0
root_spawning=1
(
    trap 'exit 0' HUP INT TERM
    while IFS= read -r root_control; do
        [ "$root_control" = G ] && (set -C; : > "$root_directory/go") || break
    done
    # The root PID is held until normal monitor join. The birth guard also
    # avoids signalling an unrelated process after an exceptional root SIGKILL.
    if [ "$(root_cookie 2>/dev/null || true)" = "$root_birth" ]; then kill -TERM "$root_parent" 2>/dev/null || true; fi
) <&6 6<&- 5>&- &
root_monitor=$!
exec 6<&-
root_spawning=0
[ "$root_cancel" = 0 ] || exit "$root_cancel"
root_run() {
    root_spawning=1
    "$@" </dev/null 5>&- &
    root_child=$!
    root_spawning=0
    [ "$root_cancel" = 0 ] || exit "$root_cancel"
    root_status=0
    wait "$root_child" || root_status=$?
    root_child=
    return "$root_status"
}
root_copy_verified() {
    rcv_source=$1; rcv_target=$2; rcv_sha=$3; rcv_blocks=$4
    case "$rcv_sha" in ''|*[!0123456789abcdef]*) return 11 ;; esac
    [ "${#rcv_sha}" = 64 ] || return 11
    # Nonblocking open and a hard count also bound FIFO/device/race inputs.
    root_run dd "if=$rcv_source" "of=$rcv_target" bs=32768 "count=$rcv_blocks" iflag=nonblock 2>/dev/null || return 12
    if command -v sha256sum >/dev/null 2>&1; then
        root_run /bin/sh -c 'exec sha256sum "$1" > "$2"' hash "$rcv_target" "$root_directory/hash" || return 12
        IFS= read -r rcv_actual < "$root_directory/hash" || return 12
        rcv_actual=${rcv_actual%% *}
    elif command -v openssl >/dev/null 2>&1; then
        root_run /bin/sh -c 'exec openssl dgst -sha256 "$1" > "$2"' hash "$rcv_target" "$root_directory/hash" || return 12
        IFS= read -r rcv_actual < "$root_directory/hash" || return 12
        rcv_actual=${rcv_actual##*= }
    else printf '%s\n' 'Privilege bootstrap needs sha256sum or openssl; use the explicit root installer when unavailable.' >&2; return 2; fi
    [ "$rcv_actual" = "$rcv_sha" ] || return 11
}
root_copy_verified "$root_native" "$root_directory/zsetup" "$root_native_sha" 2049 || exit $?
root_copy_verified "$root_program" "$root_directory/install.sh" "$root_program_sha" 33 || exit $?
chmod 0755 "$root_directory/zsetup"
if [ -n "$root_ca" ]; then root_copy_verified "$root_ca" "$root_directory/ca.pem" "$root_ca_sha" 33 || exit $?; root_ca="$root_directory/ca.pem"; fi
printf R >&5
root_ready=1
while [ ! -f "$root_directory/go" ]; do sleep .05; done
# User data is argv/environment data. Neither a configuration expression nor
# the original user-writable installer/native is executed with root privileges.
root_run env -i PATH="$PATH" HOME=/root SUDO_UID="$root_caller" \
    ZSETUP_BIN="$root_directory/zsetup" ZSETUP_INSTALLER_MODE=1 \
    ZSETUP_OS="$root_os" ZSETUP_PACKAGE_MANAGER="$root_pm" ZSETUP_ARCH="$root_arch" \
    ZSETUP_SOURCE_BASES="$root_bases" ZSETUP_SOURCE_FALLBACK="$root_fallback" ZSETUP_CA_FILE="$root_ca" \
    ZSETUP_PRIVILEGED_STAGE="$root_prepared" DDNSTO_VERSION="$root_version" \
    /bin/sh "$root_directory/install.sh" --installer-prefix "$root_prefix" -- "$@" || exit $?
exit 0
ZSETUP_ROOT_COORDINATOR
}

installer_privilege_hash() {
    if command -v sha256sum >/dev/null 2>&1; then
        ip_hash=$(sha256sum "$1") || return 12
        INSTALLER_HASH=${ip_hash%% *}
    elif command -v openssl >/dev/null 2>&1; then
        ip_hash=$(openssl dgst -sha256 "$1") || return 12
        INSTALLER_HASH=${ip_hash##*= }
    else
        printf '%s\n' 'Automatic privilege bootstrap needs sha256sum or openssl; run the installer explicitly as root instead.' >&2
        return 2
    fi
}

# The ordinary-user coordinator owns preparation and its sudo transport. Root
# owns privileged children; closing control requests root cancellation/join.
installer_privilege_read() {
    ip_read_count=$1
    installer_exec_native "$ZSETUP_BIN" capture -o "$transaction_dir/bridge-read" --max-bytes "$ip_read_count" --timeout 60s -- \
        dd "if=$transaction_dir/status" bs=1 "count=$ip_read_count" iflag=fullblock || return $?
    installer_file_size "$transaction_dir/bridge-read" || return 12
    [ "$INSTALLER_FILE_SIZE" = "$ip_read_count" ] || return 12
}

installer_privilege_result() {
    installer_privilege_read 4 || return $?
    ip_transport_only=0
    case "$(cat "$transaction_dir/bridge-read")" in
        T*)
            # A sudo transport exit after ready without a root result is a
            # protocol failure, but it must still be reaped before cleanup.
            ip_transport_code=$(cat "$transaction_dir/bridge-read")
            ip_transport_code=${ip_transport_code#T}
            installer_privilege_read 1 || return $?
            printf '%s\n' "$ip_transport_code" > "$transaction_dir/bridge-read"
            ip_transport_only=1
            ;;
    esac
    IFS= read -r ip_result < "$transaction_dir/bridge-read" || return 12
    case "$ip_result" in [012][0123456789][0123456789]) ;; *) return 12 ;; esac
    # decimal conversion without shell-dependent octal interpretation
    ip_h=${ip_result%??}; ip_t=${ip_result#?}; ip_t=${ip_t%?}; ip_o=${ip_result#??}
    INSTALLER_ROOT_RESULT=$((ip_h * 100 + ip_t * 10 + ip_o))
    [ "$INSTALLER_ROOT_RESULT" -le 255 ] || return 12
    INSTALLER_ROOT_ACK=1
    [ "$ip_transport_only" = 0 ] || return 12
}

installer_privilege_transport() {
    # A distinct ordinary-user owner reaps sudo even when its command policy
    # refuses startup before the root protocol exists. Caught signals interrupt
    # wait; repeat wait until the owned child actually exits.
    ip_transport_signal=0
    trap 'ip_transport_signal=1' HUP INT TERM
    exec 6<&0
    /usr/bin/sudo -n "$@" <&6 6<&- &
    ip_transport_pid=$!
    exec 6<&-
    while :; do
        ip_transport_exit=0
        wait "$ip_transport_pid" || ip_transport_exit=$?
        if [ "$ip_transport_signal" = 1 ]; then ip_transport_signal=0; continue; fi
        break
    done
    printf 'T%03d\n' "$ip_transport_exit" || true
    return "$ip_transport_exit"
}

installer_privilege_cleanup() {
    if [ "${INSTALLER_BRIDGE_OPEN:-0}" = 1 ]; then
        exec 3>&-
        # EOF is the only request across UIDs. Never kill the root coordinator
        # before its rollback/native operations have joined.
        if [ "$INSTALLER_ROOT_ACK" = 0 ]; then installer_privilege_result || return 1; fi
        ip_sudo_status=0
        wait "$INSTALLER_SUDO_PID" || ip_sudo_status=$?
        INSTALLER_SUDO_PID=
        exec 4>&-
        INSTALLER_BRIDGE_OPEN=0
        [ "$ip_sudo_status" = "$INSTALLER_ROOT_RESULT" ] || return 1
    fi
}

installer_privilege_install() {
    ip_app=$1; shift
    [ -x /usr/bin/sudo ] && /usr/bin/sudo -n true || {
        printf '%s\n' 'Installer: system service needs sudo credentials. Run sudo -v in a terminal and retry, or invoke the installer explicitly as root. No password prompt was started.' >&2
        return 2
    }
    installer_layout "$ip_app" system || return $?
    [ "$INSTALLER_SCOPE" = system ] || return 2
    installer_policy "$ip_app" || return $?
    installer_space_budget "$INSTALLER_MAX_DOWNLOAD" "$INSTALLER_MAX_EXPANDED" "$INSTALLER_MAX_EXPANDED" "$INSTALLER_MAX_DOWNLOAD" || return $?
    installer_storage_select "$INSTALLER_PREFIX" "$INSTALLER_REQUIRED_BYTES" 1 0 || return $?
    INSTALLER_PREFIX=$INSTALLER_STORAGE_PATH
    [ "$("$ZSETUP_BIN" storage "$INSTALLER_PREFIX" get system_protected)" = true ] || return 12
    INSTALLER_WORK_ROOT=${installer_work_dir:-${ZSETUP_WORK_DIR:-$HOME/.local/state/linkease/$ip_app/.staging}}
    installer_valid_directory "$INSTALLER_WORK_ROOT" || return $?
    installer_storage_select "$INSTALLER_WORK_ROOT" "$INSTALLER_REQUIRED_BYTES" 1 1 || return $?
    INSTALLER_WORK_ROOT=$INSTALLER_STORAGE_PATH
    printf 'Prepare as uid=%s: prefix=%s staging=%s; privileged commit uses protected prefix/.staging\n' "$ip_uid" "$INSTALLER_PREFIX" "$INSTALLER_WORK_ROOT" >&2
    installer_transaction_begin || return $?
    # Shared metadata/version selection, no extracted business program executes
    # under the ordinary account during preparation.
    SERVICE_APP=$ip_app
    "${ip_app}_linux_metadata" || return $?
    case "$ip_app" in
        ddnsto)
            installer_service_cached "$version_num" "$digest" || return $?
            [ "$SERVICE_CACHED" = 1 ] || installer_download "linux-binary/$archive_name" "$transaction_dir/$archive_name" "$digest" || return $?
            # Older adapters retain their original token-only protocol.
            if command -v ddnsto_privilege_args >/dev/null 2>&1; then
                ddnsto_privilege_args || return $?
                set -- --action "$DDNSTO_ROOT_ACTION"
                [ -z "$DDNSTO_ROOT_TOKEN" ] || set -- "$@" --token "$DDNSTO_ROOT_TOKEN"
            else
                set -- --token "$TOKEN"
            fi
            ;;
        linkease)
            installer_service_cached "$version_num" "$le_archive_sha:$le_mount_sha" || return $?
            if [ "$SERVICE_CACHED" = 0 ]; then
                installer_download "$relative_folder/$archive_name" "$transaction_dir/$archive_name" "$le_archive_sha" || return $?
                installer_download "$relative_folder/$mount_name" "$transaction_dir/$mount_name" "$le_mount_sha" || return $?
            fi
            set -- --version "$version_num"
            ;;
        *) return 2 ;;
    esac
    installer_privileged_program > "$transaction_dir/root-program" || return 12
    installer_privilege_hash "$ZSETUP_BIN" || return $?
    ip_native_sha=$INSTALLER_HASH
    installer_privilege_hash "$transaction_dir/root-program" || return $?
    ip_program_sha=$INSTALLER_HASH
    ip_ca_sha=
    if [ -n "${ZSETUP_CA_FILE:-}" ]; then installer_privilege_hash "$ZSETUP_CA_FILE" || return $?; ip_ca_sha=$INSTALLER_HASH; fi
    mkfifo "$transaction_dir/control" "$transaction_dir/status" || return 12
    exec 3<> "$transaction_dir/control"
    exec 4<> "$transaction_dir/status"
    INSTALLER_BRIDGE_OPEN=1; INSTALLER_ROOT_ACK=0; INSTALLER_SUDO_PID=
    INSTALLER_CLEANUP_HOOK=installer_privilege_cleanup
    INSTALLER_SPAWNING=1
    (
    # Close permanently in this subshell. Redirecting a shell function's FD3
    # alone saves a hidden restoration descriptor and keeps the control writer
    # alive, preventing root from observing cancellation EOF.
    exec 3>&- 4>&-
    installer_privilege_transport /bin/sh -eu -c "$(installer_privilege_root_code)" zsetup-root \
        "$ip_uid" "$ZSETUP_BIN" "$ip_native_sha" "$transaction_dir/root-program" "$ip_program_sha" \
        "${ZSETUP_CA_FILE:-}" "$ip_ca_sha" "$transaction_dir" "$os" "$package_manager" "$arch" \
        "$ZSETUP_SOURCE_BASES" "${ZSETUP_SOURCE_FALLBACK:-}" "$INSTALLER_PREFIX" "${DDNSTO_VERSION:-}" "$@" \
    ) < "$transaction_dir/control" > "$transaction_dir/status" &
    INSTALLER_SUDO_PID=$!
    INSTALLER_SPAWNING=0
    [ "$INSTALLER_SIGNAL" = 0 ] || exit "$INSTALLER_SIGNAL"
    installer_privilege_read 1 || return $?
    ip_ready=$(cat "$transaction_dir/bridge-read")
    case "$ip_ready" in
        R) printf 'G\n' >&3 ;;
        E) installer_privilege_result || return $?; return "$INSTALLER_ROOT_RESULT" ;;
        T) installer_privilege_result || return $?; return 2 ;;
        *) return 12 ;;
    esac
    installer_privilege_result || return $?
    ip_return=$INSTALLER_ROOT_RESULT
    installer_transaction_finish || return $?
    return "$ip_return"
}

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


# Business logic: maintained in ddnsto/business.sh
ddnsto_usage() {
    printf '%s\n' 'Usage: ddnsto-install.sh [--plan] [--action ensure|install|update|status|start|stop|restart|repair|configure|uninstall|download] [--platform auto|linux|openwrt|macos|windows|synology|asus|qnap|unraid] [--method auto|native|docker] [--token TOKEN | --token-file FILE] [--force-version lite|standard] [--verify-status]' \
        '默认 ensure：必须提供 Token，自动安装/升级/启用启动，不降级，不切换账号；仅验证本地稳定运行，不判断设备在线。' \
        '群晖 DSM 7 支持自动安装/升级/启动，需管理员 sudo；其他 NAS/Docker 暂不支持默认自动安装。以下选项用于高级操作。' \
        '华硕软件中心自动识别 rogsoft/armsoft/mtksoft/ipq32soft/ipq64soft/qcasoft；安装后在软件中心管理。' \
        '--plan: read-only local preflight; no downloads, token, or service changes.' \
        'Platform is a constraint, not an override. QNAP/Unraid are unavailable; Windows requires install.ps1.' \
        'Synology: DSM 7 default ensure installs/starts a verified SPK; DS220j / DSM 7.1 tested, ARM64 limited to DS220j. DSM 6 and explicit download/install use manual handoff.' \
        'Docker: explicit selection only; no automatic native/container migration.' \
        'Linux: protected systemd install/update and owned-service lifecycle.' \
        'OpenWrt: package install/update and offline procd lifecycle; update preserves UCI identity and enabled state.' \
        'Shared options precede business options: --installer-prefix PATH --installer-work-dir PATH --installer-scope system.' \
        'Explicit install on OpenWrt: token optional; automatic Lite selection below 900 MB.' \
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
    ACTION=ensure
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
    case "$REQUESTED_PLATFORM" in auto|linux|openwrt|macos|windows|synology|asus|qnap|unraid) ;; *) ddnsto_error 'unknown platform'; return 2 ;; esac
    case "$REQUESTED_METHOD" in auto|native|docker) ;; *) ddnsto_error 'unknown installation method'; return 2 ;; esac
    [ "$REQUESTED_METHOD" = docker ] || [ -z "$DEVICE_NAME$NETWORK" ] || { ddnsto_error 'device-name/network require explicit Docker'; return 2; }
    case "$NETWORK" in ''|bridge|host) ;; *) ddnsto_error 'network must be bridge or host'; return 2 ;; esac
    if [ -n "$OUTPUT_DIR" ]; then
        case "$ACTION" in install|download) ;; *) ddnsto_error 'output-dir only applies to Synology downloads'; return 2 ;; esac
    fi
    case "$FORCE_VERSION" in ''|lite|standard) ;; *) ddnsto_error 'version must be lite or standard'; return 2 ;; esac
    case "$ACTION" in
        ensure|install|update) ;;
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
        token_bytes=$(wc -c < "$TOKEN_FILE") || return 2
        [ "$token_bytes" -le 16384 ] || { ddnsto_error 'token file exceeds 16 KiB'; return 2; }
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
    elif [ -x "$appliance_root/bin/nvram" ] && { [ -d "$appliance_root/koolshare" ] || [ -f "$appliance_root/www/Advanced_System_Content.asp" ]; }; then
        printf '%s\n' asus
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
        ensure|install|update|download) return 0 ;;
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
    if [ "$detected_platform" = asus ]; then
        ddnsto_asus_facts || return $?
        printf '%s\n' 'facts_source=local-preflight' 'platform=asus' "channel=$ASUS_CHANNEL" "arch=$ASUS_ARCH" 'client_version=4.2.8' 'native_status=requires-plugin-preflight' 'installation_performed=false'
        return 0
    fi
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
            [ "${DDNSTO_VERSION:-4.2.8}" = 4.2.8 ] || { ddnsto_error 'no pinned artifact for requested version'; return 2; }
            [ "$FORCE_VERSION" != lite ] && [ "$VERIFY_STATUS" = 0 ] || { ddnsto_error 'OpenWrt options are not supported on Linux'; return 2; }
            native_status=requires-service-preflight
            client_version=${DDNSTO_VERSION:-4.2.8} ;;
        openwrt:*)
            native_status=requires-package-preflight
            client_version=standard-4.2.8-or-lite-4.2.8 ;;
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

# DDNSTO actions use the shared protected service coordinator, never flat paths.
ddnsto_managed_native() {
    # Offline operations must use the same reviewed bytes as installation.
    # This reads compiled-in pins only: no bootstrap, download or cache writes.
    bootstrap_arch || return 2
    fetch_bootstrap_metadata https '' '' || return 2
    if [ -n "${ZSETUP_BIN:-}" ]; then
        if is_expected_zsetup "$ZSETUP_BIN"; then return 0; fi
    elif find_existing_zsetup; then
        ZSETUP_BIN=$ACTIVE_ZSETUP
        return 0
    fi
    ddnsto_error 'offline management requires the verified pinned zsetup in the installer cache, PATH or ZSETUP_BIN; restore it using the installer before retrying'
    return 2
}

ddnsto_privilege_args() {
    case "${ACTION:-install}" in ensure|install|update) ;; *) return 2 ;; esac
    DDNSTO_ROOT_ACTION=${ACTION:-install}
    DDNSTO_ROOT_TOKEN=$TOKEN
    [ "$DDNSTO_ROOT_ACTION" != update ] || [ -z "$TOKEN" ]
}

# Update only the verified managed ExecStart/condition, preserving unit options
# and every configuration byte. No product -u invocation during an update.
ddnsto_managed_rewrite_unit() {
    [ "$SERVICE_HAD_UNIT" = 1 ] || { ddnsto_error 'update requires an owned service'; return 2; }
    installer_service_quote_unit
}

# Only the reviewed 4.2.8 client defines this local health protocol. Historical
# explicit version overrides retain the upstream systemd health checks.
ddnsto_service_health() {
    if [ "${DDNSTO_ENSURE_ACTIVE:-0}" = 1 ]; then
        ddnsto_ensure_linux_running || return 13
    fi
    [ "${version_num:-}" = 4.2.8 ] || return 0
    managed_health_attempt=0
    while [ "$managed_health_attempt" -lt 5 ]; do
        if ddnsto_managed_health_probe; then return 0; fi
        managed_health_attempt=$((managed_health_attempt + 1))
        sleep 1
    done
    ddnsto_error 'local client health failed; rolling back (cloud status unverified)'
    return 13
}

ddnsto_managed_health_probe() (
    managed_info=${SERVICE_CONFIG%/*}/.ddnsto_http_addr.json
    [ -f "$managed_info" ] && [ ! -L "$managed_info" ] || exit 13
    [ "$("$ZSETUP_BIN" storage "$managed_info" get system_protected)" = true ] || exit 13
    installer_file_size "$managed_info" || exit 13
    [ "$INSTALLER_FILE_SIZE" -le 1024 ] || exit 13
    info=$(cat "$managed_info") || exit 13
    case "$info" in '{"addr":"127.0.0.1:'*'","pid":'*',"startedAt":"'*'"}') ;; *) exit 13 ;; esac
    port=${info#*127.0.0.1:}; port=${port%%\"*}
    pid=${info#*\"pid\":}; pid=${pid%%,*}
    case "$port:$pid" in *[!0-9:]*|:*|*:) exit 13 ;; esac
    [ "${#port}" -le 5 ] && [ "$port" -gt 0 ] && [ "$port" -le 65535 ] || exit 13
    [ "${#pid}" -le 10 ] && [ "$pid" -gt 0 ] || exit 13
    [ "$(readlink "/proc/$pid/exe")" = "$SERVICE_EXEC" ] || exit 13
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy
    no_proxy='*'; NO_PROXY='*'; export no_proxy NO_PROXY
    if command -v curl >/dev/null 2>&1; then
        set -- curl -q --noproxy '*' -fsS --connect-timeout 1 --max-time 2 "http://127.0.0.1:$port/healthz"
    elif command -v wget >/dev/null 2>&1; then
        WGETRC=/dev/null; export WGETRC
        set -- wget -q -T 2 -O - "http://127.0.0.1:$port/healthz"
    else exit 13; fi
    installer_exec_native "$ZSETUP_BIN" capture -o "$transaction_dir/client-health" --max-bytes 16 --timeout 3s -- "$@" >/dev/null 2>&1 || exit 13
    [ "$(cat "$transaction_dir/client-health")" = ok ] || exit 13
)

# Read-only ownership proof; no mkdir, lock, package query or configuration read.
# The service adapter rechecks under its destination lock before any mutation.
ddnsto_managed_owned() {
    installer_layout ddnsto system || return $?
    [ "$INSTALLER_SCOPE" = system ] || return 2
    SERVICE_APP=ddnsto
    SERVICE_NAME=com.linkease.ddnstoshell.service
    SERVICE_UNIT=/etc/systemd/system/$SERVICE_NAME
    SERVICE_BACKEND=systemd
    SERVICE_CONFIG=/etc/ddnsto/ddnsto-config.json
    for managed_path in "$INSTALLER_PREFIX" "$INSTALLER_PREFIX/.managed" "$SERVICE_UNIT"; do
        [ "$("$ZSETUP_BIN" storage "$managed_path" get system_protected)" = true ] || return 12
    done
    [ -f "$INSTALLER_PREFIX/.managed" ] && [ ! -L "$INSTALLER_PREFIX/.managed" ] || {
        ddnsto_error 'managed installation required; legacy migration is not automatic'; return 2;
    }
    installer_file_size "$INSTALLER_PREFIX/.managed" || return 2
    [ "$INSTALLER_FILE_SIZE" = 7 ] || return 2
    IFS= read -r managed_owner < "$INSTALLER_PREFIX/.managed" || return 2
    [ "$managed_owner" = ddnsto ] || return 2
    if [ "${1:-}" = locked ]; then
        [ "${SERVICE_DEST_LOCK_HELD:-0}" = 1 ] || return 2
        ddnsto_managed_lock_owner "$INSTALLER_PREFIX/.service-lock" || return 2
    else
        [ ! -e "$INSTALLER_PREFIX/.service-lock" ] && [ ! -L "$INSTALLER_PREFIX/.service-lock" ] || {
            ddnsto_error 'active or interrupted service transaction requires recovery'; return 2;
        }
    fi
    installer_service_read_current || return $?
    [ -n "$SERVICE_OLD" ] || return 2
    [ "$SERVICE_HAD_UNIT" = 1 ] || [ "${ACTION:-}" = repair ] || return 2
    ddnsto_managed_receipt "$SERVICE_OLD" || return $?
    SERVICE_EXEC="$INSTALLER_PREFIX/$SERVICE_OLD/bin/ddnsto"
    version_num=${SERVICE_OLD#versions/}
}

# Called by the shared service coordinator for install/update as well as local
# writes. Same non-stealable machine lease as native packages and Docker.
ddnsto_service_lock() {
    DDNSTO_GLOBAL_HELD=0; DDNSTO_UNINSTALL_BACKUP=; DDNSTO_UNINSTALL_MOVED=0
    INSTALLER_CLEANUP_HOOK=ddnsto_managed_cleanup
    DDNSTO_GLOBAL_LOCK=/etc/zsetup/install-locks/ddnsto
    [ "$("$ZSETUP_BIN" storage "$DDNSTO_GLOBAL_LOCK" get system_protected)" = true ] || return 12
    umask 022
    mkdir -p /etc/zsetup/install-locks || return 12
    [ "$("$ZSETUP_BIN" storage /etc/zsetup/install-locks get system_protected)" = true ] || return 12
    umask 077
    mkdir "$DDNSTO_GLOBAL_LOCK" 2>/dev/null || {
        ddnsto_error 'active or interrupted machine-wide DDNSTO transaction requires recovery'; return 2;
    }
    DDNSTO_GLOBAL_HELD=1
    printf '%s\n' "$$" > "$DDNSTO_GLOBAL_LOCK/owner" || return 12
    # Recheck method conflict under the same lock used by Docker writers.
    [ ! -e /etc/ddnsto-docker ] && [ ! -L /etc/ddnsto-docker ] || {
        ddnsto_error 'Docker state conflicts with native installation'; return 2;
    }
    # Install/update already performed a preliminary read. Authenticate an
    # existing installation again under the global lease, before snapshots.
    if [ -n "${SERVICE_OLD:-}" ]; then
        ddnsto_managed_owned || return $?
        ddnsto_managed_effective || {
            ddnsto_error 'effective systemd service is not exclusively owned'; return 2;
        }
    fi
    if command -v ddnsto_ensure_linux_locked >/dev/null 2>&1; then
        ddnsto_ensure_linux_locked || return $?
    fi
}

ddnsto_managed_lock_owner() {
    [ -d "$1" ] && [ ! -L "$1" ] || return 2
    [ "$("$ZSETUP_BIN" storage "$1/owner" get system_protected)" = true ] || return 12
    installer_file_size "$1/owner" || return 2
    [ "$INSTALLER_FILE_SIZE" -le 16 ] || return 2
    [ "$(cat "$1/owner")" = "$$" ]
}

# Receipt trust is the same protected-file trust as install-service cached
# versions, with a closed inventory for DDNSTO's single binary and wrapper.
ddnsto_managed_receipt() (
    case "$1" in versions/*) ;; *) exit 2 ;; esac
    v=${1#versions/}; installer_service_version "$v" || exit 2
    dir="$INSTALLER_PREFIX/$1"
    for f in "$dir" "$dir/bin" "$dir/.files" "$dir/.arch" "$dir/.artifact-sha256" "$dir/bin/ddnsto" "$dir/bin/.service-run"; do
        [ "$("$ZSETUP_BIN" storage "$f" get system_protected)" = true ] || exit 12
        [ ! -L "$f" ] || exit 2
    done
    [ -d "$dir" ] && [ -d "$dir/bin" ] || exit 2
    for f in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        case "${f##*/}" in bin|.files|.arch|.artifact-sha256) ;; *) exit 2 ;; esac
    done
    for f in "$dir/bin"/* "$dir/bin"/.[!.]* "$dir/bin"/..?*; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        case "${f##*/}" in ddnsto|.service-run) ;; *) exit 2 ;; esac
    done
    for f in .files .arch .artifact-sha256; do
        installer_file_size "$dir/$f" || exit 2
        [ "$INSTALLER_FILE_SIZE" -le 160 ] || exit 2
    done
    [ "$(cat "$dir/.files")" = "$(printf '.service-run\nddnsto')" ] || exit 2
    case "$(cat "$dir/.arch")" in x86_64|aarch64|armv7) ;; *) exit 2 ;; esac
    sha=$(cat "$dir/.artifact-sha256")
    [ "${#sha}" = 64 ] || exit 2
    case "$sha" in *[!a-f0-9]*) exit 2 ;; esac
    for f in ddnsto .service-run; do
        installer_file_size "$dir/bin/$f" || exit 2
        [ "$INSTALLER_FILE_SIZE" -gt 0 ] && [ "$INSTALLER_FILE_SIZE" -le 67108864 ] && [ -x "$dir/bin/$f" ] || exit 2
    done
    installer_file_size "$dir/bin/.service-run" || exit 2
    [ "$INSTALLER_FILE_SIZE" -le 4096 ] || exit 2
    installer_service_replace "$dir/bin/ddnsto" "'" "'\\''"
    [ "$(cat "$dir/bin/.service-run")" = "$(printf '#!/bin/sh\nexec '\''%s'\'' run\n' "$service_replaced")" ] || exit 2
)

ddnsto_managed_property() {
    installer_exec_native "$ZSETUP_BIN" run -- systemctl show "--property=$1" --value "$SERVICE_NAME"
}

# Prove loaded state as well as the file: matching one ExecStart line alone
# cannot authorize hooks, drop-ins, a stale loaded unit, or a foreign fragment.
ddnsto_managed_effective() {
    managed_fragment=$(ddnsto_managed_property FragmentPath) || return 2
    managed_load=$(ddnsto_managed_property LoadState) || return 2
    managed_reload=$(ddnsto_managed_property NeedDaemonReload) || return 2
    [ "$managed_reload" = no ] || return 2
    for managed_property in DropInPaths ExecCondition ExecStartPre ExecStartPost ExecStop ExecStopPost ExecReload RootDirectory RootImage Environment User Group WorkingDirectory BindPaths BindReadOnlyPaths; do
        managed_value=$(ddnsto_managed_property "$managed_property") || return 2
        [ -z "$managed_value" ] || return 2
    done
    managed_env=$(ddnsto_managed_property EnvironmentFiles) || return 2
    if [ -n "$managed_env" ]; then
        managed_optional=/etc/sysconfig/com.linkease.ddnstoshell
        [ "$managed_env" = "$managed_optional (ignore_errors=yes)" ] || return 2
        [ "$("$ZSETUP_BIN" storage "$managed_optional" get system_protected)" = true ] || return 12
        [ ! -e "$managed_optional" ] && [ ! -L "$managed_optional" ] || return 2
    fi
    managed_exec=$(ddnsto_managed_property ExecStart) || return 2
    if [ "$SERVICE_HAD_UNIT" = 0 ]; then
        [ "$ACTION" = repair ] && [ "$managed_load" = not-found ] && [ -z "$managed_fragment" ] && [ -z "$managed_exec" ] || return 2
        [ ! -e "$SERVICE_UNIT" ] && [ ! -L "$SERVICE_UNIT" ] || return 2
    else
        [ "$managed_load" = loaded ] && [ "$managed_fragment" = "$SERVICE_UNIT" ] || return 2
        case "$managed_exec" in
            "{ path=/bin/sh ; argv[]=/bin/sh ${SERVICE_EXEC%/*}/.service-run ; ignore_errors=no ; "*' }') ;;
            *) return 2 ;;
        esac
        [ -z "${managed_exec#*\}}" ] || return 2
    fi
    managed_state=$(ddnsto_managed_property ActiveState) || return 2
    case "$managed_state" in active) [ "$SERVICE_HAD_UNIT" = 1 ] || return 2 ;; inactive|failed) ;; *) return 2 ;; esac
    managed_enabled=$(ddnsto_managed_property UnitFileState) || return 2
    case "$managed_enabled" in enabled|disabled) ;; '') [ "$SERVICE_HAD_UNIT" = 0 ] || return 2 ;; *) return 2 ;; esac
}

ddnsto_managed_cleanup() {
    # A failed stop is not permission to rewrite a running service's files.
    if [ "$SERVICE_CHANGED" = 1 ]; then
        installer_service_manager stop || return 1
        managed_stopped=$(ddnsto_managed_property ActiveState) || return 1
        case "$managed_stopped" in inactive|failed) ;; *) return 1 ;; esac
    fi
    if [ "${DDNSTO_UNINSTALL_MOVED:-0}" = 1 ]; then
        for managed_entry in versions current previous .managed; do
            if [ -e "$DDNSTO_UNINSTALL_BACKUP/$managed_entry" ] || [ -L "$DDNSTO_UNINSTALL_BACKUP/$managed_entry" ]; then
                [ ! -e "$INSTALLER_PREFIX/$managed_entry" ] && [ ! -L "$INSTALLER_PREFIX/$managed_entry" ] || return 1
                mv "$DDNSTO_UNINSTALL_BACKUP/$managed_entry" "$INSTALLER_PREFIX/$managed_entry" || return 1
            fi
        done
        DDNSTO_UNINSTALL_MOVED=0
    fi
    installer_service_cleanup || return 1
    if [ "${DDNSTO_GLOBAL_HELD:-0}" = 1 ]; then
        ddnsto_managed_lock_owner "$DDNSTO_GLOBAL_LOCK" || return 1
        rm -f "$DDNSTO_GLOBAL_LOCK/owner" || return 1
        rmdir "$DDNSTO_GLOBAL_LOCK" || return 1
        DDNSTO_GLOBAL_HELD=0
    fi
}

ddnsto_managed_uninstall_inventory() {
    for managed_entry in "$INSTALLER_PREFIX"/* "$INSTALLER_PREFIX"/.[!.]* "$INSTALLER_PREFIX"/..?*; do
        [ -e "$managed_entry" ] || [ -L "$managed_entry" ] || continue
        case "${managed_entry##*/}" in versions|current|previous|.managed|.staging|.service-lock) ;; *) return 2 ;; esac
    done
    [ -d "$INSTALLER_PREFIX/versions" ] && [ ! -L "$INSTALLER_PREFIX/versions" ] || return 2
    for managed_entry in "$INSTALLER_PREFIX/versions"/* "$INSTALLER_PREFIX/versions"/.[!.]* "$INSTALLER_PREFIX/versions"/..?*; do
        [ -e "$managed_entry" ] || [ -L "$managed_entry" ] || continue
        ddnsto_managed_receipt "versions/${managed_entry##*/}" || return 2
    done
    if [ -e "$INSTALLER_PREFIX/previous" ] || [ -L "$INSTALLER_PREFIX/previous" ]; then
        [ -L "$INSTALLER_PREFIX/previous" ] || return 2
        ddnsto_managed_receipt "$(readlink "$INSTALLER_PREFIX/previous")" || return 2
    fi
}

ddnsto_managed_write() (
    # This subshell owns traps and flags. Caller/environment flags never grant
    # permission to bypass another coordinator's locks.
    SERVICE_CHANGED=0; SERVICE_NEW_VERSION=0; SERVICE_CANDIDATE=; SERVICE_GOOD=0
    SERVICE_DEST_LOCK_HELD=0; SERVICE_CONFIG_TOUCHED=0; SERVICE_HAD_CONFIG=0
    SERVICE_WAS_ACTIVE=0; SERVICE_WAS_ENABLED=0; DDNSTO_GLOBAL_HELD=0
    INSTALLER_CLEANUP_HOOK=
    [ "$("$ZSETUP_BIN" storage / get effective_uid)" = 0 ] || {
        ddnsto_error 'local writes require a root shell: run sudo -i, then rerun the installer in that shell'; exit 2;
    }
    ddnsto_managed_owned || exit $?
    INSTALLER_WORK_ROOT="$INSTALLER_PREFIX/.staging"
    INSTALLER_RESERVE=8388608
    [ "$("$ZSETUP_BIN" storage "$INSTALLER_WORK_ROOT" get system_protected)" = true ] || exit 12
    installer_transaction_begin || exit $?
    INSTALLER_CLEANUP_HOOK=ddnsto_managed_cleanup
    ddnsto_service_lock || exit $?
    mkdir "$INSTALLER_PREFIX/.service-lock" 2>/dev/null || exit 2
    SERVICE_DEST_LOCK_HELD=1
    printf '%s\n' "$$" > "$INSTALLER_PREFIX/.service-lock/owner" || exit 12
    ddnsto_managed_owned locked || exit $?
    ddnsto_managed_effective || { ddnsto_error 'effective systemd service is not exclusively owned'; exit 2; }
    [ "$managed_state" != active ] || SERVICE_WAS_ACTIVE=1
    [ "$managed_enabled" != enabled ] || SERVICE_WAS_ENABLED=1
    [ "$SERVICE_HAD_UNIT" != 1 ] || cp -p "$SERVICE_UNIT" "$transaction_dir/old-unit" || exit 12
    [ "$("$ZSETUP_BIN" storage "$SERVICE_CONFIG" get system_protected)" = true ] || exit 12
    installer_file_size "$SERVICE_CONFIG" || exit 2
    [ "$INSTALLER_FILE_SIZE" -le 16384 ] || exit 11
    cp -p "$SERVICE_CONFIG" "$transaction_dir/old-config" || exit 12
    SERVICE_HAD_CONFIG=1
    if [ "$ACTION" = configure ]; then
        [ -n "${TOKEN:-}" ] && command -v jq >/dev/null 2>&1 || { ddnsto_error 'configure requires a nonempty Token and jq'; exit 2; }
        installer_exec_native "$ZSETUP_BIN" capture -o "$transaction_dir/new-config" --max-bytes 16384 --min-free-bytes "$INSTALLER_RESERVE" -- jq -e -s --arg token "$TOKEN" 'if length == 1 and (.[0] | type == "object" and (.token | type == "string")) then .[0] | .token = $token else error("unsupported configuration") end' "$SERVICE_CONFIG" >/dev/null 2>&1 || { ddnsto_error 'configuration must contain one JSON object with a token string'; exit 2; }
        chmod 0600 "$transaction_dir/new-config" || exit 12
    fi
    if [ "$ACTION" = uninstall ]; then
        ddnsto_managed_uninstall_inventory || { ddnsto_error 'unknown uninstall inventory; no changes made'; exit 2; }
        DDNSTO_UNINSTALL_BACKUP=$(mktemp -d "$INSTALLER_PREFIX/.uninstalled.XXXXXX") || exit 12
        cp -p "$transaction_dir/old-unit" "$DDNSTO_UNINSTALL_BACKUP/unit" || exit 12
        cp -p "$transaction_dir/old-config" "$DDNSTO_UNINSTALL_BACKUP/config" || exit 12
        printf 'active=%s\nenabled=%s\n' "$SERVICE_WAS_ACTIVE" "$SERVICE_WAS_ENABLED" > "$DDNSTO_UNINSTALL_BACKUP/state" || exit 12
    fi
    ddnsto_managed_effective || exit 2
    SERVICE_CHANGED=1
    # All actions may cause the client to persist config while stopping. Restore
    # its original bytes on failure, even when this operation is not configure.
    SERVICE_CONFIG_TOUCHED=1
    if [ "$SERVICE_HAD_UNIT" = 1 ] && [ "$ACTION" != start ]; then
        installer_service_manager stop || exit $?
        managed_stopped=$(ddnsto_managed_property ActiveState) || exit 2
        case "$managed_stopped" in inactive|failed) ;; *) exit 13 ;; esac
    fi
    case "$ACTION" in
        stop) installer_service_manager disable || exit $? ;;
        uninstall)
            installer_service_manager disable || exit $?
            rm -f "$SERVICE_UNIT" || exit 12
            installer_service_manager reload || exit $?
            [ "$(ddnsto_managed_property LoadState)" = not-found ] || exit 13
            [ -z "$(ddnsto_managed_property FragmentPath)" ] || exit 13
            DDNSTO_UNINSTALL_MOVED=1
            for managed_entry in versions current previous .managed; do
                [ -e "$INSTALLER_PREFIX/$managed_entry" ] || [ -L "$INSTALLER_PREFIX/$managed_entry" ] || continue
                mv "$INSTALLER_PREFIX/$managed_entry" "$DDNSTO_UNINSTALL_BACKUP/$managed_entry" || exit 12
            done
            cp -p "$transaction_dir/old-config" "$SERVICE_CONFIG" || exit 12
            ;;
        *)
            if [ "$ACTION" = configure ]; then
                installer_exec_native "$ZSETUP_BIN" capture -o "$SERVICE_CONFIG" --max-bytes 16384 --min-free-bytes "$INSTALLER_RESERVE" -- cat "$transaction_dir/new-config" || exit $?
                chmod 0600 "$SERVICE_CONFIG" || exit 12
            fi
            if [ "$SERVICE_HAD_UNIT" = 0 ]; then
                installer_service_escape_exec "${SERVICE_EXEC%/*}/.service-run"
                printf '[Unit]\nDescription=DdnstoShell Service\nAfter=network.target\n[Service]\nType=simple\nExecStart=/bin/sh "%s"\nRestart=always\nRestartSec=5\nLimitNOFILE=1048576\n[Install]\nWantedBy=multi-user.target\n' "$service_escaped" > "$transaction_dir/new-unit" || exit 12
                installer_exec_native "$ZSETUP_BIN" capture -o "$SERVICE_UNIT" --max-bytes 16384 --min-free-bytes "$INSTALLER_RESERVE" -- cat "$transaction_dir/new-unit" || exit $?
                chmod 0644 "$SERVICE_UNIT" || exit 12
                installer_service_manager reload || exit $?
            fi
            installer_service_manager enable || exit $?
            installer_service_manager start || exit $?
            installer_service_manager is-active || exit $?
            ddnsto_service_health || exit $?
            ;;
    esac
    SERVICE_CHANGED=0; SERVICE_GOOD=1; DDNSTO_UNINSTALL_MOVED=0
    installer_transaction_finish || exit $?
    printf 'operation=%s cloud_status=unverified\n' "$ACTION"
    [ "$ACTION" != uninstall ] || printf 'config=retained backup=%s user_aliases=retained\n' "$DDNSTO_UNINSTALL_BACKUP"
)

ddnsto_managed_action() {
    [ "$detected_platform" = linux ] || { ddnsto_error 'protected OpenWrt local lifecycle is not yet ported'; return 2; }
    case "$ACTION" in
        status) ;;
        start|stop|restart|repair|configure|uninstall) ddnsto_managed_write; return $? ;;
        *) return 2 ;;
    esac
    installer_layout ddnsto system || return $?
    [ "$INSTALLER_SCOPE" = system ] || return 2
    if [ ! -e "$INSTALLER_PREFIX" ] && [ ! -L "$INSTALLER_PREFIX" ]; then
        printf '%s\n' 'local_service=not-installed cloud_status=unverified'
        return 0
    fi
    ddnsto_managed_owned || return $?
    ddnsto_managed_effective || return $?
    case "$managed_state" in active) managed_state=running ;; inactive) managed_state=stopped ;; failed|activating|deactivating|reloading) ;; *) return 2 ;; esac
    printf 'local_service=%s cloud_status=unverified\n' "$managed_state"
}

# Included at build time; only ddnsto-install.sh is a public installer.
ddnsto_error() { printf 'DDNSTO: %s\n' "$*" >&2; }

# CLI/platform helpers are composed from managed-cli.sh in both entry programs.

ddnsto_download() { installer_download "$@"; }

# Markers are written only after zsetup has verified and committed an artifact.
ddnsto_verified_download() {
    verified_relative=$1
    verified_output=$2
    verified_sha=$3
    verified_marker="$verified_output.verified"
    installer_package_immutable "$verified_marker" "$verified_sha" || return $?
    ddnsto_download "$verified_relative" "$verified_output" "$verified_sha" || return $?
    verified_size=$(wc -c < "$verified_output" | tr -d '[:space:]')
    printf '%s:%s\n' "$verified_sha" "$verified_size" > "$transaction_dir/verified"
    mv -f "$transaction_dir/verified" "$verified_marker"
}

ddnsto_checksum() {
    "$ZSETUP_BIN" metadata sha256 "$1" "$2" || {
        ddnsto_error "invalid, missing or duplicate SHA256 for $2"; return 11;
    }
}

ddnsto_package_restore() {
    if [ "${deprecated_config:-0}" = 1 ] && [ -f "$transaction_dir/deprecated-config" ]; then
        [ "$("$ZSETUP_BIN" storage "$config_path" get system_protected)" = true ] || return 1
        installer_exec_native "$ZSETUP_BIN" run -- cp -p "$transaction_dir/deprecated-config" "$config_path" || return 1
    fi
}

ddnsto_register() {
    if [ "${ACTION:-install}" = update ]; then
        SERVICE_CONFIG_TOUCHED=0
        ddnsto_managed_rewrite_unit
        return $?
    fi
    # Rebinding requires explicit configure, never a repeated install.
    if [ "$SERVICE_HAD_UNIT" = 1 ]; then
        ddnsto_error 'already installed; use update to preserve identity or configure to change Token'
        return 2
    fi
    installer_exec_native "$ZSETUP_BIN" run -- "$SERVICE_EXEC" -u "$TOKEN" -daemon
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
    version_num=$(ddnsto_pinned_version "$SELECTED_VERSION") || return $?
    version_folder=$SELECTED_VERSION
    [ "$pkg_ext" != apk ] || version_folder="$version_folder-apk"
    relative_folder="openwrt/$version_folder/$version_num"
    status "      DDNSTO $version_num ($SELECTED_VERSION; Lite below 900 MB)"
    status '[3/4] Downloading and verifying DDNSTO packages...'
    installer_package_cache "$version_num-$version_folder" "$arch" || return $?
    package_cache=$PACKAGE_CACHE
    main_package="ddnsto_$package_arch.$pkg_ext"
    ui_package="luci-app-ddnsto.$pkg_ext"
    language_package="luci-i18n-ddnsto-zh-cn.$pkg_ext"
    for package in "$main_package" "$ui_package" "$language_package"; do
        case "$package" in ddnsto_*) product_path="$relative_folder/$package" ;; *) product_path="openwrt/$package" ;; esac
        digest=$(ddnsto_pinned_sha "$product_path") || return $?
        ddnsto_verified_download "$product_path" "$package_cache/$package" "$digest" || return $?
    done
    status '[4/4] Installing DDNSTO packages...'
    ddnsto_openwrt_apply
}

# Package hooks run while the retained-config wrapper has disabled the service.
# Do not remove existing packages first: opkg upgrade preserves dependency state.
ddnsto_openwrt_apply_packages() {
    if [ "$package_manager" = opkg ]; then
        if [ -f /www/luci-static/resources/luci.js ] && [ ! -f /usr/lib/lua/luci/cbi.lua ]; then
            installer_package_command update update && installer_package_command install install luci-compat || status 'DDNSTO: luci-compat installation failed'
        fi
        ddnsto_has_runtime=0
        if installer_package_command query "$transaction_dir/pm-query" list-installed luci-lua-runtime; then
            while IFS= read -r ddnsto_query_line; do
                case "$ddnsto_query_line" in 'luci-lua-runtime '*) ddnsto_has_runtime=1 ;; esac
            done < "$transaction_dir/pm-query"
        fi
        if [ "$ddnsto_has_runtime" = 0 ]; then
            installer_package_command update update && installer_package_command install install luci-lua-runtime || status 'DDNSTO: luci-lua-runtime installation failed'
        fi
        for package in "$main_package" "$ui_package" "$language_package"; do installer_package_command install install --force-reinstall "$package_cache/$package" || return $?; done
    else
        if [ -f /www/luci-static/resources/luci.js ] && [ ! -f /usr/lib/lua/luci/cbi.lua ]; then
            installer_package_command update update && installer_package_command add add luci-compat || status 'DDNSTO: luci-compat installation failed'
        fi
        if ! installer_package_command query "$transaction_dir/pm-query" info -e luci-lua-runtime >/dev/null 2>&1; then
            installer_package_command update update && installer_package_command add add luci-lua-runtime || status 'DDNSTO: luci-lua-runtime installation failed'
        fi
        for package in "$main_package" "$ui_package" "$language_package"; do installer_package_command add add --allow-untrusted "$package_cache/$package" || return $?; done
    fi

    installer_exec_native "$ZSETUP_BIN" run -- "${DDNSTO_OPENWRT_BIN_PATH:-/usr/sbin/ddnstod}" -v || return $?
}

ddnsto_linux_metadata() {
    case "$arch" in x86_64|aarch64) ;; *) ddnsto_error "unsupported Linux architecture: $arch"; return 2 ;; esac
    [ "$FORCE_VERSION" != lite ] || { ddnsto_error 'Linux only supports standard'; return 2; }
    [ "$VERIFY_STATUS" = 0 ] || { ddnsto_error '--verify-status is for OpenWrt'; return 2; }
    if [ -z "$TOKEN" ] && [ "${ACTION:-install}" != update ]; then
        if [ -t 0 ]; then
            printf 'DDNSTO token: ' >&2
            IFS= read -r TOKEN
        else
            ddnsto_error 'Linux needs --token TOKEN for noninteractive installation'; return 2
        fi
    fi
    [ -n "$TOKEN" ] || [ "${ACTION:-install}" = update ] || { ddnsto_error 'empty token'; return 2; }
    version_num=${DDNSTO_VERSION:-4.2.8}
    case "$version_num" in ''|*[!0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._+-]*) ddnsto_error 'invalid DDNSTO_VERSION'; return 2 ;; esac
    status "[2/4] Checking DDNSTO standard $version_num ($arch)..."
    archive_name="ddnsto-standard-$version_num.tar.gz"
    if [ "$version_num" = 4.2.8 ]; then
        digest=$(ddnsto_pinned_sha "linux-binary/$archive_name") || return $?
        return 0
    fi
    # Explicit historical DDNSTO_VERSION keeps the upstream metadata contract.
    ddnsto_download linux-binary/SHA256SUMS "$transaction_dir/sums" '' 1 || return $?
    digest=$(ddnsto_checksum "$transaction_dir/sums" "$archive_name") || return $?
}

ddnsto_linux() {
    ddnsto_linux_metadata || return $?
    installer_service_cached "$version_num" "$digest" || return $?
    if [ "$SERVICE_CACHED" = 0 ]; then
        archive_path="$transaction_dir/product.tar.gz"
        status '[3/4] Downloading DDNSTO with bounded staging...'
        ddnsto_download "linux-binary/$archive_name" "$archive_path" "$digest" || return $?
        mkdir -p "$transaction_dir/products"
        installer_extract_member "$transaction_dir/products/ddnsto" tar -xOzf "$archive_path" "ddnsto-standard-$version_num/ddnsto.$arch" || return $?
        chmod 0755 "$transaction_dir/products/ddnsto"
        installer_exec_native "$ZSETUP_BIN" run -- "$transaction_dir/products/ddnsto" -v || return $?
        installer_service_stage || return $?
        installer_service_copy ddnsto || return $?
        installer_service_commit_version || return $?
    else
        installer_exec_native "$ZSETUP_BIN" run -- "$SERVICE_EXEC" -v || return $?
    fi
    status '[4/4] Installing and checking the DDNSTO system service...'
    installer_service_activate || return $?
    status 'DDNSTO installation completed'
}

ddnsto_install() {
    ddnsto_parse_args "$@" || return $?
    if [ "$PLAN_ONLY" = 1 ]; then ddnsto_plan; return $?; fi
    : "${ZSETUP_BIN:?zsetup is required}"
    os=${ZSETUP_OS:-$("$ZSETUP_BIN" context get os)}
    package_manager=${ZSETUP_PACKAGE_MANAGER:-$("$ZSETUP_BIN" context get package_manager)}
    arch=${ZSETUP_ARCH:-$("$ZSETUP_BIN" context get arch)}
    ddnsto_detect_platform || return $?
    ddnsto_validate_platform_options || return $?
    [ "$REQUESTED_METHOD" != docker ] || { ddnsto_error 'Docker requires the public entry'; return 2; }
    case "$detected_platform" in linux|openwrt) business_platform=$detected_platform ;; *) ddnsto_error 'native installation unavailable for this device'; return 2 ;; esac
    case "$ACTION" in
        status|start|stop|restart|repair|configure|uninstall) ddnsto_managed_action; return $? ;;
    esac
    : "${ZSETUP_SOURCE_BASES:?source group is required}"
    INSTALLER_REMOTE_APP=ddnsto
    if [ "$ACTION" = ensure ]; then
        ddnsto_ensure_preflight || return $?
        DDNSTO_ENSURE_ACTIVE=1
        ENSURE_TOKEN=$TOKEN
        ip_uid=$("$ZSETUP_BIN" storage / get effective_uid) || return 12
        if [ "$ip_uid" != 0 ]; then
            if [ "$business_platform" = linux ]; then
                ddnsto_ensure_authorize || return $?
                installer_privilege_install ddnsto "$@" || return $?
                # The protected root program returns zero only after its own
                # local stability check; it never writes our user-owned log.
                ddnsto_flow_note installed
                ddnsto_flow_note started
                return 0
            fi
            ddnsto_flow_error E_PERMISSION '管理路由器服务需要 root 权限' '请以 root 登录设备后粘贴同一条命令'; return 2
        fi
        if [ "$business_platform" = linux ]; then ddnsto_ensure_linux
        else ddnsto_ensure_openwrt; fi
        return $?
    fi
    if [ "$business_platform" = linux ]; then
        [ -z "${DDNSTO_BIN_PATH:-}" ] || { ddnsto_error 'DDNSTO_BIN_PATH is retired; use --installer-prefix for the protected installation root'; return 2; }
        [ ! -e "${DDNSTO_DOCKER_STATE_DIR:-/etc/ddnsto-docker}" ] && [ ! -L "${DDNSTO_DOCKER_STATE_DIR:-/etc/ddnsto-docker}" ] || { ddnsto_error 'Docker state conflicts with native installation'; return 2; }
        if [ "$ACTION" = update ]; then ddnsto_managed_owned || return $?; fi
        ip_uid=$("$ZSETUP_BIN" storage / get effective_uid) || return 12
        if [ "$ip_uid" != 0 ]; then installer_privilege_install ddnsto "$@"; return $?; fi
        installer_service_prepare ddnsto || return $?
        if [ "$ACTION" = install ] && { [ -n "$SERVICE_OLD" ] || [ "$SERVICE_HAD_UNIT" = 1 ]; }; then
            ddnsto_error 'already installed; use update to preserve identity or configure to change Token'
            return 2
        fi
        if [ "$ACTION" = update ]; then
            [ -n "$SERVICE_OLD" ] && [ "$SERVICE_HAD_UNIT" = 1 ] && [ "$SERVICE_HAD_CONFIG" = 1 ] || { ddnsto_error 'update requires a complete managed installation'; return 2; }
        fi
        ddnsto_linux || return $?
        installer_transaction_finish
        return $?
    fi
    case "$ACTION" in install|update) ;; *) return 2 ;; esac
    ddnsto_openwrt_preflight || return $?
    installer_package_prepare ddnsto || return $?
    # Recheck installed/config state under the machine lease before downloads.
    ddnsto_openwrt_preflight || return $?
    INSTALLER_PACKAGE_CLEANUP=ddnsto_package_restore
    ddnsto_openwrt || return $?
    PACKAGE_PHASE=complete
    installer_transaction_finish
}

# Maintained product metadata; embedded in install.sh, never fetched at runtime.
# HTTPS bytes verified 2026-11-03; see docs/ddnsto-artifacts-2026-11-03.json.
# lite retains the package naming used by the Micro client release.
ddnsto_pinned_version() {
    case "$1" in
        standard|lite) printf '%s\n' 4.2.8 ;;
        *) printf '%s\n' 'DDNSTO: unknown pinned variant' >&2; return 11 ;;
    esac
}

ddnsto_pinned_sha() {
    case "$1" in
        linux-binary/ddnsto-standard-4.2.8.tar.gz) printf '%s\n' 3bf7ada14448b5aa04afa171e497f85d0b8bb4adcf2209991e52ef5826d4e975 ;;
        openwrt/lite-apk/4.2.8/ddnsto_aarch64.apk) printf '%s\n' aaf16937cad6373849ad1d1f15d64b9a085a55d4f44778c2458997fb2af0b65d ;;
        openwrt/lite-apk/4.2.8/ddnsto_arm.apk) printf '%s\n' 2834dfe9fe683d6dfffed8b73a71a7d84867789fbd8537fe3e21f8ea7e4e8c6b ;;
        openwrt/lite-apk/4.2.8/ddnsto_mipsel.apk) printf '%s\n' 91cfe44983494d3efea407fe5bd4ee5c76e227e821cd5729684ef92f46d3043e ;;
        openwrt/lite-apk/4.2.8/ddnsto_x86_64.apk) printf '%s\n' b725dab7fd7387527c03015f37cfa1e5424e13d550cc0d2fba3a7067627cef96 ;;
        openwrt/lite/4.2.8/ddnsto_aarch64.ipk) printf '%s\n' f400d53e82b4ad83da42e05b8561e3a92afbaca21f228fb994d2a5ed659474a7 ;;
        openwrt/lite/4.2.8/ddnsto_arm.ipk) printf '%s\n' c9ab02d44f753eb1129570687ec1fd31246f654444fc77dc219a7dd91fb7417e ;;
        openwrt/lite/4.2.8/ddnsto_mipsel.ipk) printf '%s\n' 3e331d2f59f891f33b2f3c00a8cecd429a266c5a52810966f78051aef267c1fb ;;
        openwrt/lite/4.2.8/ddnsto_x86_64.ipk) printf '%s\n' ed4bd946f54840a61312e4121cc6887e874baea00506711c2ce3e69f4f8411ac ;;
        openwrt/luci-app-ddnsto.apk) printf '%s\n' edd733e46d476b688da2dc046f6d87eee5365c72b1be34c82c6b9f5ef4b87a18 ;;
        openwrt/luci-app-ddnsto.ipk) printf '%s\n' 702828cdfc1cf2e33dc1b2894ec69a49f1739dfd3ece8948da0d093c6348d123 ;;
        openwrt/luci-i18n-ddnsto-zh-cn.apk) printf '%s\n' dbb3b6d2176f1c223e82ca46e6be4fda50ff30f449c9302be3382eb6162d8e2d ;;
        openwrt/luci-i18n-ddnsto-zh-cn.ipk) printf '%s\n' fff0850c893a75eb597d9e60cada9350caf5bc22219628a8c212f79f82e90679 ;;
        openwrt/standard-apk/4.2.8/ddnsto_aarch64.apk) printf '%s\n' 67e3e784a38a05aa8d3c8693caa8fd20d8316ca950268b956f688df6a1f11d8f ;;
        openwrt/standard-apk/4.2.8/ddnsto_arm.apk) printf '%s\n' 4d5c656af9560ba2a039f7305968ad086788204dcc678e8bc6bbbe345a481bf9 ;;
        openwrt/standard-apk/4.2.8/ddnsto_mipsel.apk) printf '%s\n' 8ef767b45b7546e2b4e979ac0fc426d663e34988c816e465a6c0b8b54a62d9b8 ;;
        openwrt/standard-apk/4.2.8/ddnsto_x86_64.apk) printf '%s\n' 6740fea1fbc6f58de41d5024af0d4c6d523599947c50b70889c15646f0a482c0 ;;
        openwrt/standard/4.2.8/ddnsto_aarch64.ipk) printf '%s\n' 5f291b4c28daefe4298f33d8dae9860945091bdb4af357d58b1c4553e41828cf ;;
        openwrt/standard/4.2.8/ddnsto_arm.ipk) printf '%s\n' acc8df1f81049cde0695357347aeeeecec1f99046e5e91fed1cfdde5cbedc3c6 ;;
        openwrt/standard/4.2.8/ddnsto_mipsel.ipk) printf '%s\n' 0afd87b8a17db1616b73e64625badd7eae714cf1bcdb963cc46038b8288a0553 ;;
        openwrt/standard/4.2.8/ddnsto_x86_64.ipk) printf '%s\n' d2965019064df274cea7a04433aabeb767a4b49502f724d61aa26adf641eda63 ;;
        *) printf '%s\n' "DDNSTO: no pinned artifact for $1; use a reviewed newer installer" >&2; return 11 ;;
    esac
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

#!/bin/sh
# Shared SPK selection; manual downloads and automatic DSM adapter use one pin.
ddnsto_synology_select() {
    synology_error() { printf 'DDNSTO: %s\n' "$1" >&2; }
    version_file=${DDNSTO_DSM_VERSION_FILE:-/etc.defaults/VERSION}
    [ -f "$version_file" ] && [ -r "$version_file" ] || {
        synology_error 'cannot read DSM VERSION'; return 2;
    }
    # Read data only. Do not source vendor VERSION or evaluate its contents.
    # Extract every occurrence so duplicate/ambiguous keys fail validation.
    # Count first: command substitution strips trailing empty lines.
    [ "$(grep -c '^[[:space:]]*majorversion[[:space:]]*=' "$version_file")" = 1 ] &&
        [ "$(grep -c '^[[:space:]]*buildnumber[[:space:]]*=' "$version_file")" = 1 ] || {
        synology_error 'DSM VERSION requires exactly one majorversion and buildnumber'; return 2;
    }
    major=$(sed -n '/^[[:space:]]*majorversion[[:space:]]*=/ {
        s/^[[:space:]]*majorversion[[:space:]]*=[[:space:]]*//
        s/[[:space:]]*$//
        s/^"\(.*\)"$/\1/
        p
    }' "$version_file") || return 2
    build=$(sed -n '/^[[:space:]]*buildnumber[[:space:]]*=/ {
        s/^[[:space:]]*buildnumber[[:space:]]*=[[:space:]]*//
        s/[[:space:]]*$//
        s/^"\(.*\)"$/\1/
        p
    }' "$version_file") || return 2
    case "$major" in 6|7) ;; *) synology_error 'unsupported or ambiguous DSM major version'; return 2 ;; esac
    case "$build" in ''|*[!0-9]*) synology_error 'invalid or ambiguous DSM build number'; return 2 ;; esac
    [ "${#build}" -le 9 ] || { synology_error 'invalid DSM build number'; return 2; }
    case "$major" in 6) minimum=5940 ;; 7) minimum=41890 ;; esac
    [ "$build" -ge "$minimum" ] || { synology_error 'DSM build is below the supported minimum'; return 2; }
    arch=$(uname -m) || return 2
    case "$arch" in
        x86_64) family=x86 ;;
        armv7|armv7l) family=arm ;;
        aarch64)
            # This model has a real ARM32 package canary; do not infer support
            # for every ARM64 DSM kernel from the SPK architecture list.
            model=$(cat "${DDNSTO_DSM_MODEL_FILE:-/proc/sys/kernel/syno_hw_version}" 2>/dev/null) || return 2
            [ "$major:$model" = 7:DS220j ] || { synology_error 'ARM64 model compatibility is unverified'; return 2; }
            family=arm ;;
        *) synology_error 'Synology SPK supports only x86_64 and armv7'; return 2 ;;
    esac
    case "$family:$major" in
        arm:6) digest=b83750595c95db591be99eb06749a7a657597426d13e4b699bce4c0ad16c3e60 ;;
        arm:7) digest=7286134081b518e5e339b60be7f51bc270979cbd4708998121f61e1d08470ad9 ;;
        x86:6) digest=9f3409198a7794212931e044c095a3133489c1241320f2fb45acea0c08011f03 ;;
        x86:7) digest=2842ea8b3b191528ccd8bf0f0600c99de540a56812531fe8b3fa4aacdde3fb87 ;;
    esac
    filename="ddnsto_${family}-dsm${major}.spk"
    relative="synology/4.2.8-7/$filename"
}

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

    ddnsto_synology_select || exit $?
    handoff() {
        printf '%s\n' 'platform=synology' 'package_version=4.2.8-7' \
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

# Non-service adapters still use the published native downloader. They never
# enter the Linux system-service installer on a NAS or a Docker-selected path.
ddnsto_synology_entry() (
    if [ "${PLAN_ONLY:-0}" = 1 ]; then ddnsto_synology_download "$@"; exit $?; fi
    if [ "${ZSETUP_INSTALLER_MODE:-0}" != 1 ]; then
        ddnsto_bootstrap_zsetup || exit $?
        ZSETUP_BIN=$ACTIVE_ZSETUP
    fi
    ZSETUP_SOURCE_BASES=${ZSETUP_SOURCE_BASES:-$DIRECT_PRIMARY_BASES}
    ZSETUP_SOURCE_FALLBACK=${ZSETUP_SOURCE_FALLBACK-$DIRECT_FALLBACK_BASE}
    ddnsto_download() (
        relative=$1; output=$2; digest=$3
        set -- "$ZSETUP_BIN" download -o "$output" --sha256 "$digest" \
            --max-bytes 33554432 --min-free-bytes 8388608
        [ -z "${ZSETUP_CA_FILE:-}" ] || set -- "$@" --ca-file "$ZSETUP_CA_FILE"
        for base in $ZSETUP_SOURCE_BASES; do set -- "$@" "${base%/}/ddnsto/$relative"; done
        [ -z "$ZSETUP_SOURCE_FALLBACK" ] || set -- "$@" --fallback-url "${ZSETUP_SOURCE_FALLBACK%/}/ddnsto/$relative"
        # The private download owner joins its child before caller cleanup.
        native_child=
        trap '[ -z "$native_child" ] || { kill -TERM "$native_child" 2>/dev/null || true; wait "$native_child" 2>/dev/null || true; }' EXIT
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM
        "$@" &
        native_child=$!
        result=0; wait "$native_child" || result=$?
        native_child=
        exit "$result"
    )
    ddnsto_synology_download "$@"
)

ddnsto_docker_locked() (
    ddnsto_machine_locked ddnsto_docker_lifecycle
)

ddnsto_machine_locked() (
    [ "$(id -u)" = 0 ] || { printf '%s\n' 'DDNSTO: changes require an explicit root shell' >&2; exit 2; }
    # The same root-owned lease is used by native package/service adapters.
    ddnsto_bootstrap_safe_ancestors /etc || exit 12
    for directory in /etc/zsetup /etc/zsetup/install-locks; do
        [ -e "$directory" ] || mkdir -m 755 "$directory" || exit 12
        ddnsto_bootstrap_safe_ancestors "$directory" || exit 12
    done
    docker_lock=/etc/zsetup/install-locks/ddnsto
    mkdir -m 700 "$docker_lock" 2>/dev/null || { printf '%s\n' 'DDNSTO: another installation or recovery lease exists' >&2; exit 16; }
    trap 'result=$?; trap - EXIT HUP INT TERM; rmdir "$docker_lock" || result=16; exit "$result"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    ( "$@" )
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
    case "${ACTION:-}" in start|stop|restart|configure|repair|uninstall) ;; *) ddnsto_ow_error 'unsupported lifecycle action'; return 2 ;; esac
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
    elif [ "$ACTION" != stop ]; then
        ow_token=$(uci -c "$ow_work/config" -t "$ow_work/delta" -q get 'ddnsto.@ddnsto[0].token' 2>/dev/null)
        [ -n "$ow_token" ] || { ddnsto_ow_error 'existing token required; use configure first'; return 2; }
        unset ow_token
    fi
    ow_enable=1
    [ "$ACTION" != stop ] || ow_enable=0
    uci -c "$ow_work/config" -t "$ow_work/delta" -q set "ddnsto.@ddnsto[0].enabled=$ow_enable" >/dev/null 2>&1 || return 2
    uci -c "$ow_work/config" -t "$ow_work/delta" -q commit ddnsto >/dev/null 2>&1 || return 2
    ow_dirty=1
    mv -f "$ow_work/config/ddnsto" "$config" || return 2
    if [ "$ACTION" = stop ]; then
        "$service_path" disable >/dev/null 2>&1 && "$service_path" stop >/dev/null 2>&1 &&
            ddnsto_ow_wait_service stopped || return 13
        ow_dirty=0
        printf 'operation=stop local_service=stopped cloud_status=unverified\n'
        return 0
    fi
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

# OpenWrt owns its package files and procd service, not a Linux systemd unit.
ddnsto_openwrt_paths() {
    binary=${DDNSTO_OPENWRT_BIN_PATH:-/usr/sbin/ddnstod}
    config=${DDNSTO_CONFIG_PATH:-/etc/config/ddnsto}
    service_path=${DDNSTO_SERVICE_PATH:-/etc/init.d/ddnsto}
}

ddnsto_openwrt_protected() {
    for ow_target in "$binary" "$config" "$service_path"; do
        ddnsto_ow_safe_path "$ow_target" || return 2
        ddnsto_bootstrap_safe_ancestors "${ow_target%/*}" || return 12
        [ -f "$ow_target" ] && [ "$(stat -c %u "$ow_target")" = "$(id -u)" ] || return 2
        ow_mode=$(stat -c %a "$ow_target") || return 12
        [ "$((0$ow_mode & 0022))" = 0 ] || return 12
        ddnsto_ow_owned "$ow_target" || return 2
    done
    ow_bytes=$(wc -c < "$config") || return 12
    [ "$ow_bytes" -le 16384 ] || return 11
}

ddnsto_openwrt_preflight() {
    ddnsto_openwrt_paths
    DDNSTO_OW_RETAINED=0
    if [ "${ACTION:-install}" = update ]; then
        ddnsto_openwrt_protected || return 2
        if command -v ddnsto_ensure_ow_locked >/dev/null 2>&1; then
            ddnsto_ensure_ow_locked || return $?
        fi
        return 0
    fi
    ow_packages=$(ddnsto_ow_packages) || return 2
    if ddnsto_ow_has_package ddnsto; then
        ddnsto_error 'DDNSTO package already registered; use update or configure'; return 2
    fi
    if [ -e "$config" ] || [ -L "$config" ]; then
        ddnsto_openwrt_retained_state_valid && [ -z "$TOKEN" ] || {
            ddnsto_error 'existing OpenWrt configuration: use update or configure; automatic rebinding refused'; return 2;
        }
        [ ! -e "$binary" ] && [ ! -L "$binary" ] && [ ! -e "$service_path" ] && [ ! -L "$service_path" ] || return 2
        ddnsto_bootstrap_safe_ancestors "${config%/*}" || return 12
        [ "$(stat -c %u "$config")" = "$(id -u)" ] || return 2
        ow_mode=$(stat -c %a "$config") || return 12
        [ "$((0$ow_mode & 0022))" = 0 ] || return 12
        DDNSTO_OW_RETAINED=1
    fi
}

# Called under the same machine lease as package installation. No downloads or
# zsetup are needed to operate an already installed OpenWrt package.
ddnsto_openwrt_local() {
    ddnsto_openwrt_paths
    case "$ACTION" in status|start|stop|restart|repair|configure|uninstall) ;; *) return 2 ;; esac
    ddnsto_openwrt_protected || { ddnsto_error 'complete protected package-owned OpenWrt installation required'; return 2; }
    if [ "$ACTION" = status ]; then
        ow_status=0
        "$service_path" status >/dev/null 2>&1 || ow_status=$?
        case "$ow_status" in 0) ow_state=running ;; 1|3) ow_state=stopped ;; *) return 13 ;; esac
        printf 'local_service=%s cloud_status=unverified\n' "$ow_state"
        return 0
    fi
    if [ "$ACTION" = configure ] && [ -z "$TOKEN" ]; then
        TOKEN=$(ddnsto_prompt_token) || return $?
    fi
    ddnsto_openwrt_lifecycle
}

# All artifacts have already passed the shared bounded downloader. Preserve
# UCI bytes before package hooks, including disabled state and identity fields.
ddnsto_openwrt_apply() {
    ddnsto_openwrt_paths
    if [ -e "$config" ] || [ -L "$config" ]; then
        [ "${ACTION:-install}" = update ] || [ "${DDNSTO_OW_RETAINED:-0}" = 1 ] || {
            ddnsto_error 'existing OpenWrt configuration: use update or configure; automatic rebinding refused'; return 2;
        }
        if [ "${DDNSTO_OW_RETAINED:-0}" = 1 ]; then
            ddnsto_openwrt_retained_state_valid || return 2
        else ddnsto_openwrt_protected || return 2; fi
        ddnsto_openwrt_with_retained_config ddnsto_openwrt_apply_packages || return $?
        ddnsto_openwrt_resume_config || return $?
        if [ "${DDNSTO_OW_RETAINED:-0}" = 1 ]; then
            ddnsto_openwrt_retained_state_valid || return 2
            rm -f "${config%/*}/.uninstalled-openwrt-v1" || return 12
        fi
    else
        [ "${ACTION:-install}" = install ] || { ddnsto_error 'update requires existing configuration'; return 2; }
        # Missing files must not authorize replacing a registered foreign or
        # damaged installation. Recovery must be inspected explicitly.
        ow_packages=$(ddnsto_ow_packages) || return 2
        if ddnsto_ow_has_package ddnsto; then return 2; fi
        ddnsto_openwrt_apply_packages || return $?
        if [ -n "$TOKEN" ]; then
            ( ACTION=configure; ddnsto_openwrt_local ) || return $?
        fi
    fi
    if [ "${VERIFY_STATUS:-0}" = 1 ]; then
        ddnsto_ow_wait_service running || return 13
        "$binary" -w >/dev/null 2>&1 || return 13
    fi
    printf 'operation=%s config=retained cloud_status=unverified\n' "$ACTION"
}

# Default workflow. Platform executors keep their own locks and rollback.
# Logs contain bounded installer events, never raw child output or credentials.
ddnsto_flow_note() {
    [ -n "${DDNSTO_FLOW_DIR:-}" ] || return 0
    case "$1" in checking|installing|installed|starting|started) ;; *) return 2 ;; esac
    printf '%s\n' "$1" > "$DDNSTO_FLOW_DIR/state"
    printf 'stage=%s\n' "$1" >> "$DDNSTO_FLOW_DIR/events.log"
}

ddnsto_flow_error() {
    if [ -n "${DDNSTO_FLOW_DIR:-}" ]; then
        printf '%s\n' "$1" "$2" "$3" > "$DDNSTO_FLOW_DIR/reason"
        printf 'error=%s\n' "$1" >> "$DDNSTO_FLOW_DIR/events.log"
    fi
    printf 'DDNSTO [%s]：%s。%s\n' "$1" "$2" "$3" >&2
    return 2
}

# Strict numeric release triples. Unknown/prerelease versions require review,
# never lexical comparison or a silent downgrade. Bound arithmetic operands.
ddnsto_version_parts() (
    case "$1" in ''|*[!0-9.]*|.*|*.|*..*) exit 2 ;; esac
    IFS=.; set -- $1
    [ "$#" = 3 ] || exit 2
    for part do
        [ "${#part}" -le 6 ] || exit 2
        case "$part" in 0|[1-9]|[1-9][0-9]*) ;; *) exit 2 ;; esac
    done
    printf '%s %s %s\n' "$1" "$2" "$3"
)

ddnsto_version_order() (
    left=$(ddnsto_version_parts "$1") || exit 2
    right=$(ddnsto_version_parts "$2") || exit 2
    set -- $left $right
    while [ "$#" -gt 3 ]; do
        [ "$1" -le "$4" ] || { printf '1\n'; exit 0; }
        [ "$1" -ge "$4" ] || { printf '%s\n' -1; exit 0; }
        shift
    done
    printf '0\n'
)

ddnsto_ensure_decision() {
    ENSURE_ACTION=install
    [ -n "$1" ] || return 0
    ensure_order=$(ddnsto_version_order "$1" "$2") || {
        ddnsto_flow_error E_VERSION '无法安全判断已安装版本，未执行覆盖' '请检查现有安装来源'; return 2;
    }
    ENSURE_ACTION=start
    [ "$ensure_order" != -1 ] || ENSURE_ACTION=update
}

ddnsto_ensure_preflight() {
    case "$detected_platform" in linux|openwrt|synology|asus) ;; *)
        ddnsto_flow_error E_PLATFORM '此设备暂不支持自动安装' '请使用该设备的手动安装教程'; return 2 ;;
    esac
    [ -n "$TOKEN" ] && [ "${#TOKEN}" -le 16384 ] || {
        ddnsto_flow_error E_TOKEN '缺少有效的账号 Token' '请登录控制台重新复制完整命令'; return 2;
    }
    [ "$REQUESTED_METHOD" != docker ] || {
        ddnsto_flow_error E_METHOD 'Docker 自动安装尚未完成验收' '请使用已验收的原生平台；不会自动切换安装方式'; return 2;
    }
    [ -z "$FORCE_VERSION" ] && [ "$VERIFY_STATUS" = 0 ] || {
        ddnsto_flow_error E_OPTIONS '默认流程不接受手选版本或云端检查选项' '请重新复制默认命令'; return 2;
    }
    [ "${DDNSTO_VERSION:-4.2.8}" = 4.2.8 ] || {
        ddnsto_flow_error E_VERSION '默认流程只使用该审核安装器固定的客户端版本' '请使用推荐版本入口'; return 2;
    }
}

ddnsto_flow_finish() {
    flow_rc=$1
    trap - EXIT
    # Once cancellation starts, repeated signals must not interrupt the join
    # or abandon the platform controller's rollback/lock cleanup.
    trap '' HUP INT TERM
    if [ -n "${flow_child:-}" ]; then
        kill -TERM "$flow_child" 2>/dev/null || true
        wait "$flow_child" 2>/dev/null || true
    fi
    flow_state=$(cat "$DDNSTO_FLOW_DIR/state")
    if [ "$flow_rc" = 0 ] && [ "$flow_state" != started ]; then flow_rc=13; fi
    if [ "$flow_rc" = 0 ]; then
        printf '%s\n' 'DDNSTO：安装成功，启动成功。' '仅验证本地运行；设备在线状态请查看客户端运行日志。'
    else
        flow_code=E_EXECUTOR
        flow_reason="平台执行失败（退出码 $flow_rc），未能确认启动成功"
        flow_next='请检查安装状态和服务日志后重试；不要删除配置或强制重装'
        if [ -f "$DDNSTO_FLOW_DIR/reason" ]; then
            { IFS= read -r flow_code; IFS= read -r flow_reason; IFS= read -r flow_next; } < "$DDNSTO_FLOW_DIR/reason"
        fi
        printf 'DDNSTO [%s]：%s\n' "$flow_code" "$flow_reason" >&2
        case "$flow_state" in installed|starting) printf '%s\n' '当前状态：安装成功，启动失败；配置保留，请检查服务日志。' >&2 ;;
            installing) printf '%s\n' '当前状态：安装未完成；恢复已由平台执行器尝试，需检查残留状态。' >&2 ;;
            *) printf '%s\n' '当前状态：未确认安装完成；未自动换绑或卸载。' >&2 ;; esac
        printf '下一步：%s\n' "$flow_next" >&2
    fi
    printf 'exit_code=%s\n' "$flow_rc" >> "$DDNSTO_FLOW_DIR/events.log"
    printf '脱敏诊断记录：%s/events.log\n' "$DDNSTO_FLOW_DIR" >&2
    exit "$flow_rc"
}

# This terminal entry exits via ddnsto_flow_finish. Keep its traps in the public
# shell, not an implicit function subshell that SIGTERM to the public PID skips.
ddnsto_ensure_entry() {
    set +x
    umask 077
    # mktemp creates the private destination, never reuse an inherited path.
    if [ "${detected_platform:-}" = asus ]; then
        ddnsto_asus_storage || { ddnsto_flow_error E_STORAGE '华硕受保护存储不可用' '请检查 /jffs 挂载，不要放宽目录权限'; exit 12; }
        DDNSTO_FLOW_DIR=$(ddnsto_asus_mktemp "$ASUS_STATE") || exit 12
    else
        DDNSTO_FLOW_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ddnsto-result.XXXXXX") || exit 12
    fi
    flow_child=
    trap 'ddnsto_flow_finish $?' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    ddnsto_flow_note checking
    printf '%s\n' 'DDNSTO：正在检查并安装，请稍候…' >&2
    ( set -e; ddnsto_ensure_preflight; ddnsto_ensure_execute "$@" ) >/dev/null 2>&1 &
    flow_child=$!
    flow_rc=0; wait "$flow_child" || flow_rc=$?
    flow_child=
    exit "$flow_rc"
}

ddnsto_ensure_execute() {
    if [ "$detected_platform" = asus ]; then ddnsto_asus_ensure; return $?; fi
    if [ "$detected_platform" = synology ]; then ddnsto_synology_ensure; return $?; fi
    ZSETUP_INSTALL_SCOPE=${installer_scope:-system}
    ZSETUP_INSTALL_PREFIX=${installer_prefix:-}
    [ -z "${installer_work_dir:-}" ] || ZSETUP_WORK_DIR=$installer_work_dir
    if [ "${ZSETUP_INSTALLER_MODE:-0}" = 1 ]; then ddnsto_install "$@"
    else bootstrap_and_run "$@"; fi
}

# Linux default workflow: protected installation receipts + data-only identity.
ddnsto_ensure_tty_available() ( : <>/dev/tty ) 2>/dev/null

ddnsto_ensure_authorize() {
    if [ -x /usr/bin/sudo ]; then
        /usr/bin/sudo -n true 2>/dev/null && return 0
        # Only the operating system password prompt is interactive. The
        # existing verified-copy privilege bridge owns the actual root phase.
        if ddnsto_ensure_tty_available && /usr/bin/sudo -v </dev/tty >/dev/tty 2>&1; then return 0; fi
    fi
    ddnsto_flow_error E_PERMISSION '未取得系统服务所需的管理员权限' '请执行 sudo -i 后重新粘贴命令，或请管理员安装'
}

ddnsto_ensure_protected_config() {
    [ -f "$SERVICE_CONFIG" ] && [ ! -L "$SERVICE_CONFIG" ] || return 2
    [ "$("$ZSETUP_BIN" storage "$SERVICE_CONFIG" get system_protected)" = true ] || return 2
    ensure_config_size=$(wc -c < "$SERVICE_CONFIG") || return 2
    [ "$ensure_config_size" -le 16384 ]
}

ddnsto_ensure_linux_account() {
    ddnsto_ensure_protected_config &&
        DDNSTO_EXPECTED_ACCOUNT="$ENSURE_TOKEN" jq -e -s '
        length == 1 and (.[0] | type == "object" and
        (.token | type == "string" and length > 0) and
        .token == env.DDNSTO_EXPECTED_ACCOUNT)' "$SERVICE_CONFIG" >/dev/null 2>&1 || {
        ddnsto_flow_error E_ACCOUNT '现有安装不属于当前账号，或无法确认配置归属' '请使用原账号管理；不会自动换绑或覆盖配置'; return 2;
    }
}

ddnsto_ensure_jq() {
    command -v jq >/dev/null 2>&1 && return 0
    # Fixed dependency only, using configured system repositories. Never add a
    # repository, update the OS, install unsigned packages or disable TLS.
    if command -v apt-get >/dev/null 2>&1; then
        "$ZSETUP_BIN" run -- env DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends install jq >/dev/null 2>&1 || return 2
    elif command -v dnf >/dev/null 2>&1; then
        "$ZSETUP_BIN" run -- dnf -y install jq >/dev/null 2>&1 || return 2
    elif command -v yum >/dev/null 2>&1; then
        "$ZSETUP_BIN" run -- yum -y install jq >/dev/null 2>&1 || return 2
    else return 2; fi
    command -v jq >/dev/null 2>&1
}

ddnsto_ensure_linux_running() {
    ensure_pid=$(ddnsto_managed_property MainPID) || return 13
    case "$ensure_pid" in ''|0|*[!0-9]*) return 13 ;; esac
    ensure_probe=0
    while [ "$ensure_probe" -lt 3 ]; do
        [ "$(ddnsto_managed_property ActiveState)" = active ] || return 13
        [ "$(ddnsto_managed_property MainPID)" = "$ensure_pid" ] || return 13
        ensure_probe=$((ensure_probe + 1))
        [ "$ensure_probe" = 3 ] || sleep 1
    done
}

ddnsto_ensure_linux() {
    case "$arch" in x86_64|aarch64) ;; *)
        ddnsto_flow_error E_ARCH '此 Linux CPU 架构尚未支持自动安装' '请使用对应平台的手动安装包'; return 2 ;; esac
    [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1 || {
        ddnsto_flow_error E_SERVICE_MANAGER '当前系统没有可用的 systemd 服务管理器' '请使用该平台手动安装方式；不会自动切换 Docker'; return 2;
    }
    installer_layout ddnsto system || return $?
    SERVICE_CONFIG=/etc/ddnsto/ddnsto-config.json
    ensure_current=
    if [ -e "$INSTALLER_PREFIX/.managed" ] || [ -L "$INSTALLER_PREFIX/.managed" ]; then
        ddnsto_managed_owned || {
            ddnsto_flow_error E_OWNERSHIP '现有安装不完整或不是可管理的安装' '请先检查安装来源和残留事务'; return 2;
        }
        ddnsto_ensure_jq || {
            ddnsto_flow_error E_DEPENDENCY '无法从现有软件源补齐 jq，不能安全确认账号' '请用系统包管理器安装 jq 后重试'; return 2;
        }
        ddnsto_ensure_linux_account || return $?
        ensure_current=${SERVICE_OLD#versions/}
    elif [ -e "$SERVICE_CONFIG" ] || [ -L "$SERVICE_CONFIG" ]; then
        ddnsto_flow_error E_OWNERSHIP '发现未归属的历史配置' '请先人工确认历史安装；不会自动覆盖'; return 2
    fi
    ddnsto_ensure_decision "$ensure_current" "$(ddnsto_pinned_version standard)" || return $?
    if [ "$ENSURE_ACTION" = start ]; then
        ddnsto_flow_note installed
        ddnsto_flow_note starting
        ( ACTION=start; TOKEN=; ddnsto_managed_write ) || return $?
    else
        ddnsto_flow_note installing
        if [ "$ENSURE_ACTION" = install ]; then
            ddnsto_install --action install --token "$ENSURE_TOKEN" || return $?
        else
            ddnsto_install --action update || return $?
        fi
        ddnsto_flow_note installed
    fi
    ddnsto_ensure_linux_running || return 13
    ddnsto_flow_note started
}

# Called again while holding the shared machine lease, before mutation.
ddnsto_ensure_linux_locked() {
    [ "${DDNSTO_ENSURE_ACTIVE:-0}" = 1 ] || return 0
    if [ -n "${SERVICE_OLD:-}" ]; then
        ddnsto_ensure_linux_account || return $?
        if [ "${ACTION:-}" = update ]; then
            ensure_locked_order=$(ddnsto_version_order "${SERVICE_OLD#versions/}" "$(ddnsto_pinned_version standard)") || return 2
            [ "$ensure_locked_order" != 1 ] || {
                ddnsto_flow_error E_VERSION '已安装版本在执行期间变为更高版本' '请重新执行同一命令；不会降级'; return 2;
            }
        fi
    elif [ -e "$SERVICE_CONFIG" ] || [ -L "$SERVICE_CONFIG" ]; then
        ddnsto_flow_error E_OWNERSHIP '执行期间出现未归属的配置' '请检查并发安装；不会覆盖'; return 2
    fi
}

# Default OpenWrt workflow; package ownership and UCI stay authoritative.
ddnsto_ensure_ow_account() {
    ddnsto_openwrt_protected || {
        ddnsto_flow_error E_OWNERSHIP '现有路由器安装文件归属不明或权限不安全' '请检查包管理器记录及配置权限；不会覆盖'; return 2;
    }
    ensure_pending=$(uci -c "${config%/*}" -q changes ddnsto 2>/dev/null) && [ -z "$ensure_pending" ] || {
        ddnsto_flow_error E_CONFIG '存在尚未提交的 UCI 修改，无法安全处理' '请在路由器管理界面保存或撤销修改后重试'; return 2;
    }
    [ "$(uci -c "${config%/*}" -q get 'ddnsto.@ddnsto[0]' 2>/dev/null)" = ddnsto ] &&
        ! uci -c "${config%/*}" -q get 'ddnsto.@ddnsto[1]' >/dev/null 2>&1 || {
        ddnsto_flow_error E_CONFIG '配置中缺少唯一的 DDNSTO 服务段' '请人工核对 UCI 配置；不会自动合并或覆盖'; return 2;
    }
    ensure_account=$(uci -c "${config%/*}" -q get 'ddnsto.@ddnsto[0].token' 2>/dev/null) || ensure_account=
    if [ -z "$ensure_account" ] || [ "$ensure_account" != "$ENSURE_TOKEN" ]; then
        unset ensure_account
        ddnsto_flow_error E_ACCOUNT '设备已绑定其他账号，或无法确认账号归属' '请使用原账号管理；不会自动换绑'; return 2
    fi
    unset ensure_account
}

ddnsto_ensure_ow_version() (
    if [ "$package_manager" = opkg ]; then
        listing=$(opkg list-installed 2>/dev/null) || exit 2
        count=0; installed=
        while read -r name dash version rest; do
            [ "$name" = ddnsto ] || continue
            [ "$dash" = - ] || exit 2
            count=$((count + 1)); installed=$version
        done <<EOF
$listing
EOF
        [ "$count" = 1 ] || exit 2
    else
        installed=$(apk info -v ddnsto 2>/dev/null) || exit 2
        case "$installed" in ddnsto-*) installed=${installed#ddnsto-} ;; *) exit 2 ;; esac
    fi
    # Official OpenWrt packages use PKG_SOURCE_DATE~ARCH_HEXCODE-rREV.
    # Accept only the publisher's exact architecture tag, not arbitrary
    # tilde/prerelease versions, and compare the underlying client release.
    case "$installed" in
        *~*)
            case "${arch:-}" in
                x86_64) arch_tag=8664 ;; aarch64) arch_tag=aa64 ;;
                armv7) arch_tag=aa32 ;; mipsel) arch_tag=1b0c ;;
                *) exit 2 ;;
            esac
            case "${installed#*~}" in "$arch_tag"-*) ;; *) exit 2 ;; esac
            suffix=${installed#*~}
            suffix=${suffix#"$arch_tag"-}
            installed="${installed%%~*}-$suffix"
            ;;
    esac
    case "$installed" in ''|*[!0-9.r-]*) exit 2 ;; esac
    release=${installed%%-*}
    if [ "$release" != "$installed" ]; then
        revision=${installed#*-}
        revision=${revision#r}
        case "$revision" in ''|*[!0-9]*) exit 2 ;; esac
    fi
    ddnsto_version_parts "$release" >/dev/null || exit 2
    printf '%s\n' "$release"
)

ddnsto_ensure_ow_pid() {
    # Do not log the ubus document: service command arguments may be sensitive.
    ensure_procd=$(ubus call service list '{"name":"ddnsto"}' 2>/dev/null) || return 13
    printf '%s\n' "$ensure_procd" | jsonfilter -e '@.ddnsto.instances.*.pid' 2>/dev/null
}

ddnsto_ensure_ow_running() {
    ensure_pid=$(ddnsto_ensure_ow_pid) || return 13
    case "$ensure_pid" in ''|0|*[!0-9]*) return 13 ;; esac
    ensure_probe=0
    while [ "$ensure_probe" -lt 3 ]; do
        "$service_path" status >/dev/null 2>&1 || return 13
        [ "$(ddnsto_ensure_ow_pid)" = "$ensure_pid" ] || return 13
        ensure_probe=$((ensure_probe + 1))
        [ "$ensure_probe" = 3 ] || sleep 1
    done
}

ddnsto_ensure_ow_start() {
    ddnsto_ensure_ow_account || return $?
    ddnsto_flow_note starting
    ( ACTION=start; TOKEN=; ddnsto_openwrt_local ) || return $?
    ddnsto_ensure_ow_running || return 13
}

ddnsto_ensure_openwrt() {
    case "$arch:$package_manager" in
        x86_64:opkg|aarch64:opkg|armv7:opkg|mipsel:opkg|x86_64:apk|aarch64:apk|armv7:apk|mipsel:apk) ;;
        *) ddnsto_flow_error E_ARCH '此路由器架构或包管理器不受支持' '请使用设备厂商支持的安装方式'; return 2 ;;
    esac
    for ensure_tool in uci ubus jsonfilter; do
        command -v "$ensure_tool" >/dev/null 2>&1 || {
            ddnsto_flow_error E_DEPENDENCY '缺少路由器 UCI/procd 状态检查工具' '请恢复固件自带的 uci、ubus、jsonfilter 后重试'; return 2;
        }
    done
    ddnsto_openwrt_paths
    ow_packages=$(ddnsto_ow_packages) || return 2
    ensure_current=
    if ddnsto_ow_has_package ddnsto; then
        ddnsto_ensure_ow_account || return $?
        ensure_current=$(ddnsto_ensure_ow_version) || {
            ddnsto_flow_error E_VERSION '无法识别当前路由器客户端版本' '请检查包管理器记录；不会强制覆盖'; return 2;
        }
    else
        for ensure_path in "$config" "$binary" "$service_path"; do
            [ ! -e "$ensure_path" ] && [ ! -L "$ensure_path" ] || {
                ddnsto_flow_error E_OWNERSHIP '发现未归属的历史安装或配置' '请先确认原安装来源；不会自动覆盖'; return 2;
            }
        done
    fi
    ddnsto_ensure_decision "$ensure_current" "$(ddnsto_pinned_version standard)" || return $?
    if [ "$ENSURE_ACTION" != start ]; then
        ddnsto_flow_note installing
        if [ "$ENSURE_ACTION" = install ]; then
            ddnsto_install --action install --token "$ENSURE_TOKEN" || return $?
        else ddnsto_install --action update || return $?; fi
    fi
    ddnsto_flow_note installed
    ddnsto_machine_locked ddnsto_ensure_ow_start || return $?
    ddnsto_flow_note started
}

ddnsto_ensure_ow_locked() {
    [ "${DDNSTO_ENSURE_ACTIVE:-0}" = 1 ] || return 0
    [ "${ACTION:-}" = update ] || return 0
    ddnsto_ensure_ow_account || return $?
    ensure_current=$(ddnsto_ensure_ow_version) || return 2
    ensure_order=$(ddnsto_version_order "$ensure_current" "$(ddnsto_pinned_version standard)") || return 2
    [ "$ensure_order" != 1 ] || {
        ddnsto_flow_error E_VERSION '执行期间已安装版本变为更高版本' '请重新执行；不会降级'; return 2;
    }
}

# DSM package-managed default workflow. Never install a generic Linux service.
ddnsto_synopkg() { /usr/syno/bin/synopkg "$@"; }

ddnsto_synology_storage() {
    # DSM /tmp is noexec; /var/tmp can be world-writable without sticky bit.
    # Do not change mounts or weaken the shared cache ownership rules.
    syno_storage=/var/lib/ddnsto-installer
    ddnsto_bootstrap_safe_ancestors /var/lib && ddnsto_bootstrap_private_dir "$syno_storage" || {
        ddnsto_flow_error E_STORAGE '群晖安装器缓存目录不安全或不可写' '请检查 /var/lib/ddnsto-installer 权限'; return 12;
    }
}

ddnsto_synology_preflight() {
    [ "$(id -u)" = 0 ] || { ddnsto_flow_error E_PRIVILEGE '群晖套件安装需要管理员权限' '请使用 sudo -i 后重新执行'; return 2; }
    for tool in jq readlink stat; do
        command -v "$tool" >/dev/null 2>&1 || { ddnsto_flow_error E_DEPENDENCY '缺少群晖配置或进程检查工具' '请检查 DSM 的 jq、stat、readlink'; return 2; }
    done
    [ -x /usr/syno/bin/synopkg ] || { ddnsto_flow_error E_DEPENDENCY '找不到 DSM 套件管理器' '请通过套件中心手动安装'; return 2; }
    ddnsto_synology_select || { ddnsto_flow_error E_PLATFORM '此 DSM 版本或架构尚未支持自动安装' '请使用匹配机型的手动套件'; return 2; }
    [ "$major" = 7 ] || { ddnsto_flow_error E_PLATFORM 'DSM 6 暂仅支持手动安装' '请使用套件中心手动安装'; return 2; }
    syno_pkg=/var/packages/ddnsto
    syno_config=$syno_pkg/var/ddnsto-config.json
    ddnsto_synology_storage
}

ddnsto_synology_check_paths() {
    # DSM owns target/var symlinks. Resolve and check their actual ancestors;
    # package data may be owned by the dedicated service user, never strangers.
    syno_uid=$(id -u ddnsto) || return 2
    for path in "$syno_pkg/INFO" "$syno_pkg/target/bin/ddnsto" "$syno_config"; do
        [ -f "$path" ] || return 2
        resolved=$(readlink -f "$path") || return 2
        while [ "$resolved" != / ]; do
            owner=$(stat -c %u "$resolved") || return 2
            mode=$(stat -c %a "$resolved") || return 2
            case "$owner" in 0|"$syno_uid") ;; *) return 2 ;; esac
            [ "$((0$mode & 0022))" = 0 ] || return 2
            resolved=${resolved%/*}; [ -n "$resolved" ] || resolved=/
        done
    done
}

ddnsto_synology_account() {
    ddnsto_synology_check_paths || { ddnsto_flow_error E_OWNERSHIP '群晖套件文件缺失或权限不安全' '请核对套件来源与配置权限，不要强制覆盖'; return 2; }
    # Token comes via stdin, never jq argv or diagnostic output.
    printf '%s' "$TOKEN" | jq -Rse --slurpfile config "$syno_config" '
        . as $expected | ($config | length == 1) and
        ($config[0] | type == "object" and (.token == $expected) and
        (.routeridx | type == "number" and . >= 0 and . <= 99 and floor == .))
    ' >/dev/null 2>&1 || {
        ddnsto_flow_error E_ACCOUNT '套件账号不匹配或设备编号无法安全确认' '请使用原账号检查套件设置，不会自动换绑'; return 2;
    }
}

ddnsto_synology_version() {
    syno_version=$(ddnsto_synopkg version ddnsto) || return 2
    case "$syno_version" in *-*) ;; *) return 2 ;; esac
    syno_release=${syno_version%-*}; syno_revision=${syno_version##*-}
    ddnsto_version_parts "$syno_release" >/dev/null || return 2
    case "$syno_revision" in ''|*[!0-9]*|0*) return 2 ;; esac
    [ "${#syno_revision}" -le 6 ]
}

ddnsto_synology_fetch() (
    ddnsto_synology_storage || exit $?
    WORK_ROOT="$syno_storage/native"
    ddnsto_bootstrap_zsetup || { ddnsto_flow_error E_BOOTSTRAP 'zsetup 下载或校验失败' '请检查 HTTPS 下载和缓存权限'; exit 2; }
    ddnsto_synology_select || exit 2
    "$ACTIVE_ZSETUP" download -o "$1" --sha256 "$digest" --max-bytes 33554432 --min-free-bytes 8388608 \
        "https://fw.koolcenter.com/binary/ddnsto/$relative" \
        "https://fw.d4ctech.com/binary/ddnsto/$relative" \
        --fallback-url "https://fw20.koolcenter.com/binary/ddnsto/$relative"
)

ddnsto_synology_running() {
    binary=$(readlink -f "$syno_pkg/target/bin/ddnsto") || return 13
    pid=$(cat "$syno_pkg/var/ddnsto.pid") || return 13
    case "$pid" in ''|*[!0-9]*) return 13 ;; esac
    [ "$pid" -gt 1 ] || return 13
    for probe in 1 2 3; do
        ddnsto_synopkg status ddnsto | jq -e '.status == "running"' >/dev/null || return 13
        kill -0 "$pid" 2>/dev/null && [ "$(readlink "/proc/$pid/exe")" = "$binary" ] || return 13
        [ "$(cat "$syno_pkg/var/ddnsto.pid")" = "$pid" ] || return 13
        [ "$probe" = 3 ] || sleep 1
    done
}

ddnsto_synology_ensure_locked() (
    umask 077
    ddnsto_synology_preflight || exit $?
    case "$TOKEN" in ''|*[!a-zA-Z0-9_-]*) ddnsto_flow_error E_TOKEN 'Token 格式不适用于群晖套件' '请从控制台重新复制'; exit 2 ;; esac
    need_install=1; existing=0
    if [ -e "$syno_pkg/INFO" ]; then
        existing=1
        ddnsto_synology_account || exit $?
        ddnsto_synology_version || { ddnsto_flow_error E_VERSION '无法识别当前套件版本' '请检查套件中心，不会强制覆盖'; exit 2; }
        order=$(ddnsto_version_order "$syno_release" 4.2.8) || exit 2
        if [ "$order" = 1 ] || { [ "$order" = 0 ] && [ "$syno_revision" -ge 7 ]; }; then need_install=0; fi
    elif [ -e "$syno_config" ] || [ -e "$syno_pkg/target" ] || [ -L "$syno_pkg/target" ]; then
        ddnsto_flow_error E_OWNERSHIP '发现未登记的群晖套件残留' '请在套件中心检查，不会覆盖原配置'; exit 2
    else
        ddnsto_synology_fresh_preflight || exit $?
    fi
    if [ "$need_install" = 1 ]; then
        syno_work=$(mktemp -d "$syno_storage/package.XXXXXX") || exit 12
        # Keep private backup and package for recovery; never auto-uninstall.
        [ "$existing" = 0 ] || cp -p "$syno_config" "$syno_work/config.before.json" || exit 12
        ddnsto_synology_fetch "$syno_work/package.spk" || {
            ddnsto_flow_error E_DOWNLOAD '群晖套件下载或校验失败，尚未修改套件' '请检查下载连通性后重试'; exit 11;
        }
        if [ "$existing" = 1 ]; then
            ddnsto_synology_account || exit $?
            cmp -s "$syno_config" "$syno_work/config.before.json" || { ddnsto_flow_error E_CONFIG '下载期间配置已改变' '请重新执行，不会覆盖修改'; exit 2; }
            ddnsto_synology_version || exit 2
            order=$(ddnsto_version_order "$syno_release" 4.2.8) || exit 2
            [ "$order" != 1 ] && { [ "$order" != 0 ] || [ "$syno_revision" -le 7 ]; } || {
                ddnsto_flow_error E_VERSION '下载期间已安装版本变更' '请重新执行，不会降级'; exit 2;
            }
        fi
        ddnsto_flow_note installing
        if [ "$existing" = 0 ]; then
            ddnsto_synology_fresh_install "$syno_work/package.spk" || exit $?
        else
            ddnsto_synopkg install "$syno_work/package.spk" >/dev/null 2>&1 || {
            ddnsto_flow_error E_PACKAGE 'DSM 套件安装失败，未自动卸载或删除配置' "请检查套件中心；私有备份目录：$syno_work"; exit 11;
            }
        fi
        ddnsto_synology_version && [ "$syno_version" = 4.2.8-7 ] || {
            ddnsto_flow_error E_PACKAGE '套件版本未达到预期' '请检查套件中心安装记录'; exit 11;
        }
        if [ "$existing" = 1 ]; then
            cmp -s "$syno_config" "$syno_work/config.before.json" || {
                ddnsto_flow_error E_CONFIG '升级后配置与备份不一致' "停止自动操作，请检查私有备份：$syno_work"; exit 12;
            }
        fi
    fi
    ddnsto_synology_account || exit $?
    ddnsto_flow_note installed
    ddnsto_flow_note starting
    ddnsto_synopkg start ddnsto >/dev/null 2>&1 && ddnsto_synology_running || {
        ddnsto_flow_error E_START '套件已安装，但未确认稳定启动' '请检查套件中心和套件运行日志，配置已保留'; exit 13;
    }
    ddnsto_flow_note started
)

ddnsto_synology_ensure() { ddnsto_machine_locked ddnsto_synology_ensure_locked; }

# DSM's Package Center API carries wizard values; synopkg drops shell env.
ddnsto_synowebapi() { /usr/syno/bin/synowebapi --exec "$@"; }

ddnsto_synology_absent_paths() {
    for path do
        if [ -e "$path" ] || [ -L "$path" ]; then
            ddnsto_flow_error E_OWNERSHIP '发现群晖套件或历史配置残留，未执行新装' '请检查套件中心和原配置，不会自动删除或换绑'; return 2
        fi
    done
}

ddnsto_synology_fresh_check() {
    ddnsto_synology_absent_paths "$syno_pkg" /volume*/@appdata/ddnsto \
        /volume*/@appstore/ddnsto /tmp/.ddnsto/ddnsto-config.json
}

ddnsto_synology_fresh_preflight() {
    [ -x /usr/syno/bin/synowebapi ] || {
        ddnsto_flow_error E_DEPENDENCY 'DSM 缺少套件中心本机安装接口' '请通过套件中心手动安装 SPK'; return 2;
    }
    syno_check=$(ddnsto_synowebapi api=SYNO.Core.Package.Installation method=check version=1 'id="ddnsto"' 2>/dev/null) &&
    syno_volume=$(printf '%s' "$syno_check" | jq -er '
        select(.success == true and .data.is_occupied == false) |
        .data | .volume_path as $v | select(.volume_list | any(.mount_point == $v)) |
        $v | select(type == "string")
    ' 2>/dev/null) || {
        ddnsto_flow_error E_STORAGE 'DSM 无法确认可用的默认套件安装卷，或安装器正忙' '请在套件中心设置默认安装卷，等待其他安装完成后重试'; return 2;
    }
    # DSM jq 1.5 may be compiled without regex support.
    case "$syno_volume" in
        /volume*) volume_number=${syno_volume#/volume} ;;
        *) volume_number=invalid ;;
    esac
    case "$volume_number" in ''|*[!0-9]*)
        ddnsto_flow_error E_STORAGE 'DSM 返回的默认安装卷路径不受支持' '请通过套件中心手动安装'; return 2 ;;
    esac
    ddnsto_bootstrap_safe_ancestors "$syno_volume" || {
        ddnsto_flow_error E_STORAGE '群晖安装卷权限不安全' '请检查默认安装卷权限'; return 2;
    }
    ddnsto_synology_fresh_check
}

ddnsto_synology_fresh_install() (
    ddnsto_synology_fresh_check || exit $?
    # JSON string containing a JSON object: same encoding as DSM Package Center.
    # No shared temporary token file. Native CLI requires argv; suppress its
    # argument-echoing stderr and never copy its raw reply into diagnostics.
    extra=$(printf '%s' "$TOKEN" | jq -Rsc '{wizard_ddnsto_token:.,wizard_ddnsto_idx:"0"}|tojson') || exit 2
    package_path=$(printf '%s' "$1" | jq -Rsc .) || exit 2
    result=$(ddnsto_synowebapi api=SYNO.Core.Package.Installation method=install version=1 \
        "path=$package_path" "volume_path=\"$syno_volume\"" "extra_values=$extra" \
        check_codesign=false force=false installrunpackage=false 2>/dev/null) || {
        ddnsto_flow_error E_PACKAGE 'DSM 本机安装接口执行失败' '请检查套件中心安装记录；不会自动卸载或强制重装'; exit 11;
    }
    unset extra
    # Accept only this SHA-verified third-party SPK, as in Package Center's
    # third-party confirmation. Never change global trust settings or force.
    printf '%s' "$result" | jq -e '.success == true and (.data.has_fail != true)' >/dev/null 2>&1 || {
        code=$(printf '%s' "$result" | jq -r '.error.code | select(type == "number" and floor == .)' 2>/dev/null) || code=
        case "$code" in ''|*[!0-9]*) code=unknown ;; esac
        ddnsto_flow_error E_PACKAGE "DSM 套件安装被拒绝（接口错误码 $code）" '请检查套件中心安装记录；不会自动卸载或强制重装'; exit 11;
    }
)

# Pure channel selection. Inputs are firmware facts, never executable settings.
# Caller must first establish ASUS firmware + an existing software center.
# Keep CPU selection separate: each modern archive contains two binaries.
ddnsto_asus_channel() (
    model=$1 kernel=$2 architecture=$3 source=$4
    model_channel= source_channel=
    case "$kernel" in ''|*[!a-zA-Z0-9._+-]*) return 2 ;; esac
    release=${kernel%%-*}; release=${release%%+*}
    case "$release" in ''|*[!0-9.]*|.*|*.|*..*) return 2 ;; esac
    # Validate every numeric component, without arithmetic on untrusted input.
    IFS=.; set -- $release; unset IFS
    [ "$#" -ge 3 ] || return 2
    for component do
        case "$component" in 0|[1-9]*) ;; *) return 2 ;; esac
    done
    case "$architecture" in armv7l|aarch64) ;; *) return 2 ;; esac
    case "$model" in
        TX-AX6000|TUF-AX4200Q|RT-AX57_Go|GS7|ZenWiFi_BT8P|GS7_Air|GS-BE7200X)
            model_channel=mtksoft ;;
        ZenWiFi_BD4) model_channel=ipq32soft ;;
        TUF_6500) model_channel=ipq64soft ;;
        RT-AX89X) model_channel=qcasoft ;;
    esac
    # Only use a source as a classification hint. It is never a download URL.
    # Do not guess HND from ARM64 or an unfamiliar model alone.
    case "${source%/}" in
        '') ;;
        https://rogsoft.ddnsto.com) source_channel=rogsoft ;;
        https://armsoft.ddnsto.com) source_channel=armsoft ;;
        https://mtksoft.ddnsto.com) source_channel=mtksoft ;;
        https://ipq32soft.ddnsto.com) source_channel=ipq32soft ;;
        https://ipq64soft.ddnsto.com) source_channel=ipq64soft ;;
        https://qcasoft.ddnsto.com) source_channel=qcasoft ;;
        *) return 2 ;;
    esac
    if [ -n "$model_channel" ] && [ -n "$source_channel" ]; then
        [ "$model_channel" = "$source_channel" ] || return 2
    fi
    channel=${model_channel:-$source_channel}
    case "$kernel" in
        2.6.*)
            [ "$architecture" = armv7l ] || return 2
            [ -z "$channel" ] || [ "$channel" = armsoft ] || return 2
            channel=armsoft ;;
        4.[1-9]*|5.*|6.*)
            [ -n "$channel" ] && [ "$channel" != armsoft ] || return 2 ;;
        *) return 2 ;;
    esac
    printf '%s\n' "$channel"
)

# Reviewed CDN bytes on 2026-11-10. These URLs are mutable, so a changed
# package must fail verification until a new installer reviews its pin.
# Output: URL, plugin version, .valid marker, byte size, SHA-256.
ddnsto_asus_package() (
    case "$1" in
        rogsoft) marker=hnd size=8104981 sha=671c1c77d7b867f5019af35e8702be665695e30c107138ae150d045e11df1960 ;;
        armsoft) marker=arm384 size=3430887 sha=8e0ff71269b8ba8674427896310d99309d97eae92b007d97cb968eb1d880664d ;;
        mtksoft) marker=mtk size=8105004 sha=8d08921e49bed7bcafed48dc6c6b6795467f77767a97cc8af23f0b463285248a ;;
        ipq32soft) marker=ipq32 size=8105008 sha=56c0298ec811e51cf93390bbfa2f9489752188320aaf96c43d2b19289ba7580d ;;
        ipq64soft) marker=ipq64 size=8105008 sha=4cb863a85d5c5dcd00ff8a3f5a09fa90465b59b48e48cdce12163be62b1f10ce ;;
        qcasoft) marker=qca size=8105006 sha=fa021afaf9424f032ff9e084e76c80fadd7fe74e844060e0d84ac6053db19216 ;;
        *) return 2 ;;
    esac
    printf '%s\n' "https://asusgo.koolcenter.com/$1/ddnsto/ddnsto.tar.gz" 4.2.8 "$marker" "$size" "$sha"
)

# Source-only ASUS storage helpers. No environment-selected trust roots.
# Caller must supply a trusted shell/PATH and establish ASUS firmware identity.
# Public predicates return 0 on success, nonzero on refusal/error. Only uid,
# fields, hash and mktemp print results; storage sets ASUS_STATE in the caller.
# Checks are not protection against concurrent root writers or mount changes:
# callers must serialize transactions. This does not secure legacy /koolshare.
_ddnsto_asus_status() { cat /proc/self/status; }

# Print effective UID, or fail without output on malformed/duplicate records.
ddnsto_asus_uid() (
    status=$(_ddnsto_asus_status) || return 1
    printf '%s\n' "$status" | LC_ALL=C awk '
        $1 == "Uid:" {
            count++
            if (NF != 5) bad=1
            for (i=2; i<=5; i++) if ($i !~ /^[0-9]+$/) bad=1
            uid=$3
        }
        END { if (count != 1 || bad) exit 1; print uid }
    '
)

ddnsto_asus_has() { [ "$#" = 1 ] && type "$1" >/dev/null 2>&1; }

_ddnsto_asus_ls() { LC_ALL=C ls -nd "$1"; }

# Internal output adds the file type as a fourth field.
# Restrict names and reject ACL/extra-line output, never eval it.
_ddnsto_asus_metadata() (
    [ "$#" = 1 ] || return 1
    case "$1" in /*) ;; *) return 1 ;; esac
    case "$1" in *[!a-zA-Z0-9_./-]*|*/|*//*|*/../*|*/..|*/./*|*/.) return 1 ;; esac
    listing=$(_ddnsto_asus_ls "$1") || return 1
    printf '%s\n' "$listing" | LC_ALL=C awk '
        NR == 1 && NF == 9 &&
        $1 ~ /^[-d][r-][w-][xsS-][r-][w-][xsS-][r-][w-][xtT-]$/ &&
        $2 ~ /^[1-9][0-9]*$/ && $3 ~ /^[0-9]+$/ &&
        $4 ~ /^[0-9]+$/ && $5 ~ /^[0-9]+$/ {
            mode=0
            for (i=2; i<=10; i++) {
                c=substr($1,i,1)
                mode=mode*2 + (c != "-" && c != "S" && c != "T")
            }
            if (substr($1,4,1) ~ /[sS]/) mode+=2048
            if (substr($1,7,1) ~ /[sS]/) mode+=1024
            if (substr($1,10,1) ~ /[tT]/) mode+=512
            value=sprintf("%s %o %s %s", $3, mode, $2, substr($1,1,1)); ok=1
        }
        END { if (NR != 1 || !ok) exit 1; print value }
    '
)

# Equivalent to stat -c "%u %a %h" for supported unambiguous paths.
ddnsto_asus_fields() (
    fields=$(_ddnsto_asus_metadata "$@") || return 1
    set -- $fields
    printf '%s %s %s\n' "$1" "$2" "$3"
)

_ddnsto_asus_mounts() { cat /proc/mounts; }
_ddnsto_asus_mkdir() { mkdir -m 700 "$1"; }

# Bounded ASUS compatibility exception: a live mount cannot be renamed or
# unlinked by writers of /. Never extend this to ordinary writable ancestors.
# Trust kernel /proc/mounts, not user-selected paths or source-device symlinks.
# Approve local block ext2/3/4, MTD jffs2, and UBI ubifs sources only. These
# records do not prove backing-media durability or protect against privileged
# mount attackers; six-channel device acceptance remains a separate check.
ddnsto_asus_anchor() (
    [ "$(ddnsto_asus_uid)" = 0 ] || return 1
    mounts=$(_ddnsto_asus_mounts) || return 1
    printf '%s\n' "$mounts" | LC_ALL=C awk '
        function approved_source(source, fs) {
            if (fs == "ext2" || fs == "ext3" || fs == "ext4")
                return source ~ /^\/dev\/[a-zA-Z0-9_-]+(\/[a-zA-Z0-9_-]+)*$/
            if (fs == "jffs2")
                return source ~ /^\/dev\/mtdblock([0-9]+|\/[0-9]+)$/
            if (fs == "ubifs")
                return source ~ /^\/dev\/ubi[0-9]+_[0-9]+$/ ||
                       source ~ /^ubi[0-9]+:[a-zA-Z0-9_][a-zA-Z0-9_.-]*$/
            return 0
        }
        $2 == "/jffs" {
            count++
            if (NF != 6 || !approved_source($1,$3)) bad=1
            n=split($4,opts,","); rw=0
            for (i=1;i<=n;i++) {
                if (opts[i] == "rw") rw++
                if (opts[i] == "ro" || opts[i] == "noexec" || opts[i] == "bind" || opts[i] == "rbind") bad=1
            }
            if (rw != 1) bad=1
        }
        index($2,"/jffs/") == 1 { bad=1 }
        END { if (count != 1 || bad) exit 1 }
    ' || return 1
    fields=$(_ddnsto_asus_metadata /jffs) || return 1
    set -- $fields
    [ "$1" = 0 ] && [ "$4" = d ] || return 1
    case "$2" in 700|750|755) ;; *) return 1 ;; esac
)

# Initialize only our own directory; never repair modes of existing objects.
# On failure ASUS_STATE is empty, even if inherited from the environment.
ddnsto_asus_storage() {
    ASUS_STATE=
    ddnsto_asus_anchor || return 1
    if ! _ddnsto_asus_metadata /jffs/.ddnsto-installer >/dev/null 2>&1; then
        (umask 077; _ddnsto_asus_mkdir /jffs/.ddnsto-installer) || return 1
    fi
    _ddnsto_asus_private_existing /jffs/.ddnsto-installer || return 1
    ASUS_STATE=/jffs/.ddnsto-installer
}

_ddnsto_asus_private_existing() (
    fields=$(_ddnsto_asus_metadata "$1") || return 1
    set -- $fields
    [ "$1" = 0 ] && [ "$2" = 700 ] && [ "$4" = d ]
)

_ddnsto_asus_descendant() {
    [ "$#" = 1 ] || return 1
    case "$1" in /jffs/*) ;; *) return 1 ;; esac
    case "$1" in *[!a-zA-Z0-9_./-]*|*/|*//*|*/../*|*/..|*/./*|*/.) return 1 ;; esac
}

# Check parents of PATH (leaf may not exist); stop at the mounted /jffs.
# The leaf is excluded: to validate directory DIR itself, pass "$DIR/probe".
# No probe file is opened or created.
# Walk top-down so metadata lookup never traverses an unverified symlink.
ddnsto_asus_safe_ancestors() (
    _ddnsto_asus_descendant "$@" || return 1
    ddnsto_asus_anchor || return 1
    rest=${1#/jffs/} parent=/jffs
    while case "$rest" in */*) true;; *) false;; esac; do
        parent=$parent/${rest%%/*}; rest=${rest#*/}
        fields=$(_ddnsto_asus_metadata "$parent") || return 1
        set -- $fields
        [ "$1" = 0 ] && [ "$4" = d ] || return 1
        case "$2" in 7[0145][0145]) ;; *) return 1 ;; esac
    done
)

_ddnsto_asus_private_path() {
    _ddnsto_asus_descendant "$@" || return 1
    case "$1" in /jffs/.ddnsto-installer|/jffs/.ddnsto-installer/*) ;; *) return 1 ;; esac
    ddnsto_asus_safe_ancestors "$1" || return 1
    _ddnsto_asus_private_existing /jffs/.ddnsto-installer
}

# Idempotent mkdir of one leaf inside initialized state; no mkdir -p/chmod.
ddnsto_asus_private_dir() (
    _ddnsto_asus_private_path "$@" || return 1
    if ! _ddnsto_asus_metadata "$1" >/dev/null 2>&1; then
        (umask 077; _ddnsto_asus_mkdir "$1") || return 1
    fi
    _ddnsto_asus_private_existing "$1"
)

# Existing regular root-owned single-link file inside private state; readable
# by root, no group/other writes or special bits. Never opens FIFOs/devices.
ddnsto_asus_safe_file() (
    _ddnsto_asus_private_path "$@" || return 1
    fields=$(_ddnsto_asus_metadata "$1") || return 1
    set -- $fields
    [ "$1" = 0 ] && [ "$3" = 1 ] && [ "$4" = - ] || return 1
    case "$2" in [4567][0145][0145]) ;; *) return 1 ;; esac
)

_ddnsto_asus_random() { openssl rand -hex 12; }

# Print a fresh 0700 directory. Atomic mkdir claims ownership; an existing
# name is never reused, removed, or repaired. Eight attempts bound collisions.
# Caller owns cleanup and transaction locking; this helper acquires no lock.
ddnsto_asus_mktemp() (
    _ddnsto_asus_private_path "$@" || return 1
    _ddnsto_asus_private_existing "$1" || return 1
    parent=$1 attempt=0
    umask 077
    while [ "$attempt" -lt 8 ]; do
        random=$(_ddnsto_asus_random) || return 1
        [ "${#random}" = 24 ] || return 1
        case "$random" in *[!0-9a-f]*) return 1 ;; esac
        path=$parent/tmp.$random
        if _ddnsto_asus_mkdir "$path" 2>/dev/null; then
            _ddnsto_asus_private_existing "$path" || return 1
            printf '%s\n' "$path"
            return 0
        fi
        attempt=$((attempt + 1))
    done
    return 1
)

_ddnsto_asus_openssl_hash() { openssl dgst -sha256 < "$1"; }
_ddnsto_asus_sha256_hash() { sha256sum < "$1"; }

# Hash only a checked private-state file. stdin avoids filename-dependent
# digest output. A present but failing backend is an error, not a fallback.
ddnsto_asus_hash() (
    ddnsto_asus_safe_file "$@" || return 1
    if ddnsto_asus_has openssl; then
        output=$(_ddnsto_asus_openssl_hash "$1") || return 1
        backend=openssl
    elif ddnsto_asus_has sha256sum; then
        output=$(_ddnsto_asus_sha256_hash "$1") || return 1
        backend=sha256sum
    else
        return 1
    fi
    printf '%s\n' "$output" | LC_ALL=C awk -v backend="$backend" '
        NR == 1 && NF == 2 {
            if (backend == "openssl" && ($1 == "SHA256(stdin)=" || $1 == "SHA2-256(stdin)=" || $1 == "(stdin)=")) digest=$2
            if (backend == "sha256sum" && $2 == "-") digest=$1
        }
        END {
            if (NR != 1 || length(digest) != 64 || digest ~ /[^0-9a-fA-F]/) exit 1
            print tolower(digest)
        }
    '
)

# Controlled ASUS package adapter; source asus-platform.sh before this module.
# ddnsto_asus_extract ARCHIVE DEST CHANNEL ARCH -> 0 success, nonzero rejection.
# Caller MUST verify ARCHIVE size + SHA256 against ddnsto_asus_package CHANNEL,
# keep it immutable through this call, and establish trusted owner state for
# DEST's parent and all ancestors. A private child of writable /tmp or
# /koolshare is NOT sufficient. This module does not establish that trust.
# Success leaves only three private staged files; it never runs package code.
# OS commands remain shell-function mockable; no stat/id/command dependency.
# Requires tar (-t/-v/-xO/-z), awk, wc, cmp, mkdir/rmdir, rm, chmod and shell
# ulimit/type. od is optional: absent od relies on the caller-verified pin;
# present but failing od is fatal. ARCH is armv7l or aarch64 (armsoft: armv7l).
# Limits: compressed archive/binary 12 MiB, other members 64 KiB, metadata
# extraction 64 B, each listing 16 KiB, declared aggregate 26 MiB.
# Validation covers the complete logical member listing reported by tar, not
# raw extension headers or bytes tar ignores after its end marker. Exact pins
# remain mandatory. Output is bounded; decompression CPU time is not bounded
# here. Caller owns cancellation, trusted storage, and subsequent installation.
# On failure only this call's fixed staging filenames are removed. An existing
# DEST is never reused/deleted. SIGKILL or I/O failure may leave private residue;
# never consume DEST unless the function returned zero.
_ddnsto_asus_package_tar() { tar "$@"; }
_ddnsto_asus_package_od() { od "$@"; }
_ddnsto_asus_package_has_od() { type od >/dev/null 2>&1; }

# Per-file kernel ceiling before opening output, then an exact byte ceiling.
# POSIX/ash uses 512-byte blocks; shells using 1024-byte blocks can transiently
# write up to twice the ceiling. No unbounded command substitution or pipeline
# masks tar failure. gzip/tar stream data; no archive tree is ever materialized.
_ddnsto_asus_package_capture() (
    ceiling=$1 output=$2; shift 2
    (ulimit -c 0 || exit 1
     ulimit -f "$(((ceiling + 511) / 512))" || exit 1
     _ddnsto_asus_package_tar "$@" > "$output" 2>/dev/null) || return 1
    bytes=$(wc -c < "$output") || return 1
    [ "$bytes" -gt 0 ] && [ "$bytes" -le "$ceiling" ]
)

_ddnsto_asus_package_member() (
    member=$1 output=$2 ceiling=$3
    expected=$(awk -v name="$member" '$6 == name {print $3}' .types) || return 1
    _ddnsto_asus_package_capture "$ceiling" "$output" -xOzf "$archive" "$member" || return 1
    [ "$(wc -c < "$output")" -eq "$expected" ]
)

ddnsto_asus_extract() (
    [ "$#" = 4 ] || return 2
    unset IFS # POSIX default splitting, independent of caller overrides.
    archive=$1 dest=$2 channel=$3 arch=$4
    # Use the existing platform authority, not a second marker/version table.
    pins=$(ddnsto_asus_package "$channel") || return 2
    set -f
    set -- $pins
    [ "$#" = 5 ] && [ "$2" = 4.2.8 ] || return 2
    version=$2 marker=$3
    case "$channel:$arch" in
        armsoft:armv7l) binary=ddnsto ;;
        armsoft:*) return 2 ;;
        *:armv7l) binary=ddnsto_arm ;;
        *:aarch64) binary=ddnsto_aarch64 ;;
        *) return 2 ;;
    esac
    # Absolute, unambiguous paths only. Ownership/ancestor permissions are the
    # caller storage adapter contract; reject symlinks as an extra guard.
    for path in "$archive" "$dest"; do
        case "$path" in /*) ;; *) return 2 ;; esac
        case "$path" in /|*/|*//*|*/./*|*/../*|*/.|*/..|*[!a-zA-Z0-9_./+-]*) return 2 ;; esac
        while [ "$path" != / ]; do
            [ ! -L "$path" ] || return 2
            path=${path%/*}; path=${path:-/}
        done
    done
    [ -f "$archive" ] || return 2
    bytes=$(wc -c < "$archive") || return 1
    [ "$bytes" -gt 0 ] && [ "$bytes" -le 12582912 ] || return 1
    LC_ALL=C; export LC_ALL
    unset TAR_OPTIONS GZIP
    umask 077
    mkdir "$dest" || return 1
    cd "$dest" || { rmdir "$dest"; return 1; }
    trap 'rm -f ddnsto Module_ddnsto.asp icon-ddnsto.png .names .types .valid .version; rmdir "$dest"' 0
    trap 'exit 1' 1 2 3 15
    _ddnsto_asus_package_capture 16384 .names -tzf "$archive" || return 1
    _ddnsto_asus_package_capture 16384 .types -tvzf "$archive" || return 1
    # GNU and BusyBox verbose listings have mode, owner/group, size, date,
    # time, name. Reject every other grammar rather than guessing a name.
    LC_ALL=C awk -v channel="$channel" '
        BEGIN {
            split("ddnsto/ ddnsto/webs/ ddnsto/res/ ddnsto/bin/ ddnsto/scripts/", dirs, " ")
            for (i in dirs) want[dirs[i]] = "d"
            split("webs/Module_ddnsto.asp res/icon-ddnsto.png .valid version install.sh uninstall.sh scripts/ddnsto_config.sh scripts/ddnsto_status.sh", files, " ")
            for (i in files) want["ddnsto/" files[i]] = "-"
            if (channel == "armsoft") {
                want["ddnsto/bin/ddnsto"] = "-"
                want["ddnsto/res/ddnsto_check.html"] = "-"
            } else {
                want["ddnsto/bin/ddnsto_arm"] = "-"
                want["ddnsto/bin/ddnsto_aarch64"] = "-"
            }
        }
        NR == FNR {
            if (!($0 in want) || seen[$0]++) bad = 1
            names[FNR] = $0
            count++
            next
        }
        {
            if (NF != 6 || $6 != names[FNR] || substr($1, 1, 1) != want[$6] ||
                length($1) != 10 || $3 !~ /^[0-9]+$/) bad = 1
            ceiling = ($6 ~ /^ddnsto\/bin\/ddnsto/) ? 12582912 : 65536
            if (want[$6] == "d") { if ($3 != 0) bad = 1 }
            else if ($3 < 1 || $3 > ceiling) bad = 1
            total += $3
            types++
        }
        END {
            for (name in want) if (seen[name] != 1) bad = 1
            if (count != 15 || types != count || total > 27262976) bad = 1
            exit bad
        }
    ' .names .types || return 1
    _ddnsto_asus_package_member ddnsto/.valid .valid 64 || return 1
    _ddnsto_asus_package_member ddnsto/version .version 64 || return 1
    printf '%s\n' "$marker" | cmp -s .valid - || return 1
    printf '%s\n' "$version" | cmp -s .version - || return 1
    _ddnsto_asus_package_member "ddnsto/bin/$binary" ddnsto 12582912 || return 1
    _ddnsto_asus_package_member ddnsto/webs/Module_ddnsto.asp Module_ddnsto.asp 65536 || return 1
    _ddnsto_asus_package_member ddnsto/res/icon-ddnsto.png icon-ddnsto.png 65536 || return 1
    if _ddnsto_asus_package_has_od; then
        header=$(_ddnsto_asus_package_od -An -v -tu1 -N20 ddnsto) || return 1
        set -- $header
        [ "$#" = 20 ] || return 1
        [ "$1 $2 $3 $4 $6 $7" = '127 69 76 70 1 1' ] || return 1
        class=$5
        shift 16
        case "$1 $2" in '2 0'|'3 0') ;; *) return 1 ;; esac
        case "$arch:$class:$3:$4" in armv7l:1:40:0|aarch64:2:183:0) ;; *) return 1 ;; esac
    fi
    chmod 700 ddnsto || return 1
    rm -f .names .types .valid .version || return 1
    trap - 0
)

# Controlled ASUS lifecycle. Source after asus-storage.sh; caller owns the
# transaction lock and verified payload. Never execute the native plugin scripts.
# Software-center execution trust is inherited: writable firmware dispatchers
# can still execute arbitrary code. These bridges do not secure the whole router.
# All publication uses a same-filesystem source with the EXACT leaf basename,
# and destination '.' in a pinned physical directory. No mv -T requirement.
# Never execute original root scripts, even during recovery.

_ddnsto_asus_plugin_files() {
    printf '%s\n' bin/ddnsto scripts/ddnsto_config.sh scripts/ddnsto_status.sh \
        scripts/uninstall_ddnsto.sh init.d/S70ddnsto.sh webs/Module_ddnsto.asp res/icon-ddnsto.png
}

_ddnsto_asus_metadata_keys() {
    printf '%s\n' ddnsto_token ddnsto_enable ddnsto_version ddnsto_client_version \
        softcenter_module_ddnsto_version softcenter_module_ddnsto_install \
        softcenter_module_ddnsto_name softcenter_module_ddnsto_title \
        softcenter_module_ddnsto_description
}

# Called in a subshell. Each operation stays relative to the pinned physical
# directory; a changed ancestor either fails validation or cannot redirect it.
_ddnsto_asus_plugin_cd() {
    case "$1" in bin|scripts|init.d|webs|res) ;; *) return 1 ;; esac
    cd -P /jffs || return 1
    [ ! -L .koolshare ] && cd -P .koolshare || return 1
    [ "$(pwd -P)" = /jffs/.koolshare ] || return 1
    [ ! -L "$1" ] && cd -P "$1" || return 1
    [ "$(pwd -P)" = "/jffs/.koolshare/$1" ]
}

# Destination is always the pinned cwd, never a separately resolved leaf path.
# mv appends the source basename once; rename replaces a leaf symlink instead
# of traversing it. Verify firmware semantics in private state before stop.
_ddnsto_asus_publish() { mv -f "$1" .; }

_ddnsto_asus_probe_mv() (
    probe="$ASUS_ATTEMPT/mv-probe"
    mkdir "$probe" "$probe/source" "$probe/dest" "$probe/outside" || return 1
    printf probe > "$probe/source/leaf"
    ln -s "$probe/outside" "$probe/dest/leaf" || return 1
    cd -P "$probe/dest" || return 1
    _ddnsto_asus_publish "$probe/source/leaf" || return 1
    [ ! -L leaf ] && [ -f leaf ] && [ "$(cat leaf)" = probe ] || return 1
    [ ! -e "$probe/outside/leaf" ] || return 1
    mkdir "$probe/dest/directory" || return 1
    printf probe > "$probe/source/directory"
    if _ddnsto_asus_publish "$probe/source/directory" 2>/dev/null; then return 1; fi
    [ ! -e "$probe/dest/directory/directory" ]
)

ddnsto_asus_backup_plugin() (
    umask 077
    ddnsto_asus_private_dir "$ASUS_ATTEMPT" || return 1
    mkdir "$ASUS_ATTEMPT/backup" "$ASUS_ATTEMPT/changed" || return 1
    mkdir "$ASUS_ATTEMPT/backup/files" "$ASUS_ATTEMPT/backup/config" || return 1
    _ddnsto_asus_probe_mv || return 1
    for key in $(_ddnsto_asus_metadata_keys); do
        ddnsto_asus_get "$key" > "$ASUS_ATTEMPT/backup/config/$key" || return 1
    done
    for entry in $(_ddnsto_asus_plugin_files); do
        (
            _ddnsto_asus_plugin_cd "${entry%/*}" || exit 1
            leaf=${entry##*/}
            if [ -e "$leaf" ] || [ -L "$leaf" ]; then
                [ -L "$leaf" ] || [ -f "$leaf" ] || exit 1
                cp -pP "$leaf" "$ASUS_ATTEMPT/backup/files/$leaf" || exit 1
                [ -L "$ASUS_ATTEMPT/backup/files/$leaf" ] ||
                    ddnsto_asus_safe_file "$ASUS_ATTEMPT/backup/files/$leaf" || exit 1
            fi
        ) || return 1
    done
    if [ -L "$ASUS_STATE/current" ]; then
        previous=$(readlink -f "$ASUS_STATE/current") || return 1
        case "$previous" in "$ASUS_STATE"/*/runtime) ;; *) return 1 ;; esac
        ddnsto_asus_safe_file "$previous/ddnsto" &&
            ddnsto_asus_safe_file "$previous/service.sh" || return 1
        cp -pP "$ASUS_STATE/current" "$ASUS_ATTEMPT/backup/current" || return 1
    elif [ -e "$ASUS_STATE/current" ]; then return 1
    fi
    # Rollback may run ONLY reviewed bytes. Native originals remain complete in
    # backup even when they cannot be trusted to execute. Fail before stop if an
    # enabled legacy binary cannot be matched to this reviewed package.
    if [ ! -L "$ASUS_ATTEMPT/backup/current" ] &&
        [ "$(cat "$ASUS_ATTEMPT/backup/config/ddnsto_enable")" = 1 ]; then
        old="$ASUS_ATTEMPT/backup/files/ddnsto"
        ddnsto_asus_safe_file "$old" && cmp -s "$old" "$ASUS_ATTEMPT/payload/ddnsto" || {
            printf '%s\n' 'ASUS: enabled native binary is not reviewed recovery material' >&2
            return 1
        }
    fi
    # Prepare recovery before the first stop, including failures before install.
    _ddnsto_asus_prepare_runtime || return 1
    : > "$ASUS_ATTEMPT/backup/complete"
)

_ddnsto_asus_runtime() {
    cat <<'ASUS_RUNTIME'
#!/bin/sh
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
unset ENV BASH_ENV CDPATH
umask 077
service_binary=/jffs/.ddnsto-installer/current/ddnsto

asus_service_get() { /usr/bin/dbus get "$1"; }

# pidof is only an enumerator. Root ownership, executable and process birth
# time are checked independently, immediately before each signal/probe.
asus_service_identity() (
    case "$1" in ''|*[!0-9]*|0|1) exit 1 ;; esac
    target=$(readlink "/proc/$1/exe") || exit 1
    case "$target" in
        /.koolshare/bin/ddnsto|/jffs/.koolshare/bin/ddnsto)
            [ "${2:-}" = legacy ] || exit 1 ;;
        *) wanted=$(readlink -f "$service_binary") || exit 1
            [ "$target" = "$wanted" ] || exit 1 ;;
    esac
    role=$(awk '
        $1=="Uid:" {u++; if (NF!=5 || $2!=0 || $3!=0 || $4!=0 || $5!=0) bad=1}
        $1=="PPid:" {p++; parent=$2}
        END {if (u!=1 || p!=1 || bad || parent !~ /^[0-9]+$/) exit 1; print parent}
    ' "/proc/$1/status") || exit 1
    birth=$(sed 's/^.*) //' "/proc/$1/stat" | awk 'NF>=20 && $20 ~ /^[0-9]+$/ {print $20}')
    [ -n "$birth" ] || exit 1
    printf '%s:%s:%s\n' "$target" "$role" "$birth"
)

asus_service_main() {
    main=
    for pid in $(pidof ddnsto 2>/dev/null); do
        ident=$(asus_service_identity "$pid") || return 1
        case "$ident" in *:1:*)
            [ -z "$main" ] || return 1
            main=$pid; main_identity=$ident ;;
        esac
    done
    [ -n "$main" ]
}

asus_service_running() {
    asus_service_main || return 1
    stable_pid=$main stable_identity=$main_identity
    for probe in 2 3; do
        sleep 1
        asus_service_main || return 1
        [ "$main" = "$stable_pid" ] && [ "$main_identity" = "$stable_identity" ] || return 1
    done
}

asus_service_stop() {
    # Include the legacy executable only for installer migration, never for UI.
    mains= children=
    for pid in $(pidof ddnsto 2>/dev/null); do
        ident=$(asus_service_identity "$pid" "${1:-}") || continue
        case "$ident" in *:1:*) mains="$mains $pid" ;; *) children="$children $pid" ;; esac
    done
    # Stop the supervisor first so it cannot respawn the WebDAV child. Recheck
    # identity at signal time (children may have become reparented meanwhile).
    for pid in $mains $children; do
        ident=$(asus_service_identity "$pid" "${1:-}") || continue
        [ "$(asus_service_identity "$pid" "${1:-}")" = "$ident" ] || return 1
        kill -TERM "$pid" 2>/dev/null || {
            [ "$(asus_service_identity "$pid" "${1:-}")" != "$ident" ] || return 1
        }
    done
    for probe in 1 2 3 4 5; do
        remaining=0
        # Unknown or inaccessible ddnsto PIDs are never signalled, but prevent
        # replacement/startup. Otherwise migration could launch duplicates.
        for pid in $(pidof ddnsto 2>/dev/null); do remaining=1; done
        [ "$remaining" = 0 ] && return 0
        sleep 1
    done
    # No broad killall or forced kill. A resistant process blocks replacement.
    return 1
}

asus_service_start() {
    [ "$(asus_service_get ddnsto_enable)" = 1 ] || return 0
    asus_service_main && return 0
    [ -z "$(pidof ddnsto 2>/dev/null)" ] || return 1
    token=$(asus_service_get ddnsto_token) || return 1
    case "$token" in ''|*[!a-zA-Z0-9_-]*) return 1 ;; esac
    enabled=$(asus_service_get ddnsto_feat_enabled) || return 1
    user=$(asus_service_get ddnsto_feat_username) || return 1
    pass=$(asus_service_get ddnsto_feat_password) || return 1
    port=$(asus_service_get ddnsto_feat_port) || return 1
    disk=$(asus_service_get ddnsto_feat_disk_path_selected) || return 1
    set -- -u "$token" -d
    if [ "$enabled" = 1 ] && [ -n "$user" ] && [ -n "$pass" ] && [ -n "$port" ]; then
        case "$port" in *[!0-9]*|'') return 1 ;; esac
        [ "${#port}" -le 5 ] && [ "$port" -gt 0 ] && [ "$port" -le 65535 ] || return 1
        set -- "$@" -n "$user" -k "$pass" -p "$port" -s "${disk:-/}"
    fi
    "$service_binary" "$@" >/dev/null 2>&1
}

asus_service_json() {
    # Escape every control byte representable in shell strings, without eval.
    LC_ALL=C awk 'BEGIN {printf "\""; for(i=1;i<32;i++) ctrl[sprintf("%c",i)]=i}
        {if(NR>1) printf "\\n"; for(i=1;i<=length($0);i++) {
            c=substr($0,i,1)
            if(c=="\\" || c=="\"") printf "\\%s",c
            else if(c in ctrl) printf "\\u%04x",ctrl[c]
            else printf "%s",c
        }} END {printf "\""}'
}

asus_service_response() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#1}" -le 16 ] || return 1
    curl --noproxy '*' --connect-timeout 2 --max-time 5 -fsS \
        -H 'Content-Type: application/json' --data-binary "$2" \
        "http://127.0.0.1:3030/_resp/$1" >/dev/null
}

asus_service_router_id() (
    # config.go prints "%s %s\n", VERSION, RouterId for -w and exits before
    # connecting. identity/routerid.go derives ASUS IDs as 12 lowercase hex
    # digits. Never run the writable software-center binary or vendor scripts.
    query=/jffs/.ddnsto-installer/router-query.lock
    mkdir -m 700 "$query" 2>/dev/null || exit 1
    child=
    cleanup_query() {
        if [ -n "$child" ]; then
            kill -KILL "$child" 2>/dev/null || :
            wait "$child" 2>/dev/null || :
        fi
        rm -f "$query/output"
        rmdir "$query" 2>/dev/null || :
    }
    trap cleanup_query 0
    trap 'exit 1' 1 2 3 15
    # -f is in 512-byte or 1024-byte units across supported shells. Either
    # cap is <=1 KiB. Reject >128 bytes as well; no output reaches shell eval.
    (ulimit -c 0 && ulimit -f 1 && exec "$service_binary" -w) > "$query/output" 2>/dev/null &
    child=$!
    for probe in 1 2 3; do
        sleep 1
        kill -0 "$child" 2>/dev/null || break
    done
    # This PID is our directly spawned query, never a daemon discovered by name.
    if kill -0 "$child" 2>/dev/null; then exit 1; fi
    wait "$child" 2>/dev/null; result=$?
    child=
    [ "$result" = 0 ] || exit 1
    [ "$(wc -c < "$query/output")" -le 128 ] || exit 1
    LC_ALL=C awk '
        NR==1 && NF==2 && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+$/ &&
            length($2)==12 && $2 ~ /^[0-9a-f]+$/ { id=$2; valid=1 }
        END { if(NR!=1 || !valid) exit 1; print id }
    ' "$query/output"
)

asus_service_plugin_cd() {
    case "$1" in bin|scripts|init.d|webs|res) ;; *) return 1 ;; esac
    cd -P /jffs || return 1
    [ ! -L .koolshare ] && cd -P .koolshare || return 1
    [ "$(pwd -P)" = /jffs/.koolshare ] || return 1
    [ ! -L "$1" ] && cd -P "$1" || return 1
    [ "$(pwd -P)" = "/jffs/.koolshare/$1" ]
}

asus_service_owned_leaf() {
    case "$1" in Module_ddnsto.asp|icon-ddnsto.png)
        [ ! -L "./$1" ] && [ -f "./$1" ] &&
            cmp -s "./$1" "/jffs/.ddnsto-installer/current/$1" ;;
        *) [ -L "./$1" ] &&
            [ "$(readlink "./$1")" = "/jffs/.ddnsto-installer/current/$1" ] ;;
    esac
}

asus_service_uninstall() {
    # Explicit software-center uninstall only. Keep protected runtime and all
    # original backups; never call a vendor hook or enumerate wildcard paths.
    owned='bin/ddnsto scripts/ddnsto_config.sh scripts/ddnsto_status.sh scripts/uninstall_ddnsto.sh init.d/S70ddnsto.sh webs/Module_ddnsto.asp res/icon-ddnsto.png'
    for entry in $owned; do
        (asus_service_plugin_cd "${entry%/*}" &&
            asus_service_owned_leaf "${entry##*/}") || {
            printf '%s\n' 'ASUS: uninstall refused: plugin file ownership changed' >&2
            return 1
        }
    done
    asus_service_stop || return 1
    for entry in $owned; do
        (
            asus_service_plugin_cd "${entry%/*}" || exit 1
            leaf=${entry##*/}
            asus_service_owned_leaf "$leaf" || exit 1
            rm -f "./$leaf"
        ) || return 1
    done
    for key in ddnsto_token ddnsto_enable ddnsto_version ddnsto_client_version \
        ddnsto_feat_enabled ddnsto_feat_username ddnsto_feat_password \
        ddnsto_feat_port ddnsto_feat_disk_path_selected \
        softcenter_module_ddnsto_version softcenter_module_ddnsto_install \
        softcenter_module_ddnsto_name softcenter_module_ddnsto_title \
        softcenter_module_ddnsto_description; do
        /usr/bin/dbus remove "$key" || return 1
    done
}

asus_service_status() {
    request=$1
    case "$request" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#request}" -le 16 ] || return 1
    state=0 feat=0 pidtext=
    if asus_service_main; then
        state=1; pidtext=$main
        for pid in $(pidof ddnsto 2>/dev/null); do
            ident=$(asus_service_identity "$pid") || continue
            case "$ident" in *:"$main":*) feat=1 ;; esac
        done
    fi
    version=$(asus_service_get ddnsto_version | asus_service_json) || return 1
    username=$(asus_service_get ddnsto_feat_username | asus_service_json) || return 1
    port=$(asus_service_get ddnsto_feat_port | asus_service_json) || return 1
    router_id=$(asus_service_router_id) || router_id=
    asus_service_response "$request" "{\"version\":$version,\"status\":$state,\"router_id\":\"$router_id\",\"pid\":\"$pidtext\",\"feat\":{\"status\":\"$feat\",\"username\":$username,\"port\":$port,\"disk_path\":\"/webdav/\"}}"
}

# UI/autostart shares the installer lock. The trusted installer already owns
# it and uses explicit internal operations; status is read-only.
case "${1:-}" in
    start|stop|config|uninstall)
        mkdir -m 700 /jffs/.ddnsto-installer/install.lock 2>/dev/null || exit 16
        trap 'rmdir /jffs/.ddnsto-installer/install.lock 2>/dev/null || :' 0
        trap 'exit 1' 1 2 3 15 ;;
esac
case "${1:-}" in
    library) ;; # private installer/test source use; performs no action
    start|installer-start) asus_service_start ;;
    stop) asus_service_stop ;;
    migrate-stop) asus_service_stop legacy ;;
    running) asus_service_running ;;
    status) asus_service_status "${2:-}" ;;
    uninstall) asus_service_uninstall ;;
    config)
        case "${2:-}" in ''|*[!0-9]*) exit 2 ;; esac
        [ "${#2}" -le 16 ] || exit 2
        result=0
        asus_service_stop && asus_service_start || result=1
        asus_service_response "$2" "$2" || exit 1
        exit "$result" ;;
    *) exit 2 ;;
esac
ASUS_RUNTIME
}

_ddnsto_asus_prepare_runtime() (
    umask 077
    mkdir "$ASUS_ATTEMPT/runtime" || return 1
    ddnsto_asus_safe_file "$ASUS_ATTEMPT/payload/ddnsto" || return 1
    cp "$ASUS_ATTEMPT/payload/ddnsto" "$ASUS_ATTEMPT/runtime/ddnsto" || return 1
    chmod 700 "$ASUS_ATTEMPT/runtime/ddnsto" || return 1
    _ddnsto_asus_runtime > "$ASUS_ATTEMPT/runtime/service.sh" || return 1
    chmod 700 "$ASUS_ATTEMPT/runtime/service.sh" || return 1
    pins=$(ddnsto_asus_package "$ASUS_CHANNEL") || return 1
    printf '%s\n' "$pins" > "$ASUS_ATTEMPT/runtime/source-pin" || return 1
    digest=$(ddnsto_asus_hash "$ASUS_ATTEMPT/runtime/ddnsto") || return 1
    printf '%s\n' "$digest" > "$ASUS_ATTEMPT/runtime/binary.sha256" || return 1
)

# Read-only fast path, called after main's storage preflight and snapshot.
# No execution or sourcing of an installed hook; no new files or directories.
ddnsto_asus_reusable() (
    [ "$(ddnsto_asus_get ddnsto_version)" = 4.2.8 ] || return 1
    [ -L "$ASUS_STATE/current" ] || return 1
    runtime=$(readlink -f "$ASUS_STATE/current") || return 1
    case "$runtime" in "$ASUS_STATE"/*/runtime) ;; *) return 1 ;; esac
    for name in ddnsto service.sh source-pin binary.sha256 \
        ddnsto_config.sh ddnsto_status.sh uninstall_ddnsto.sh S70ddnsto.sh \
        Module_ddnsto.asp icon-ddnsto.png; do
        ddnsto_asus_safe_file "$runtime/$name" || return 1
    done
    [ -x "$runtime/ddnsto" ] || return 1
    pins=$(ddnsto_asus_package "$ASUS_CHANNEL") || return 1
    printf '%s\n' "$pins" | cmp -s "$runtime/source-pin" - || return 1
    digest=$(ddnsto_asus_hash "$runtime/ddnsto") || return 1
    printf '%s\n' "$digest" | cmp -s "$runtime/binary.sha256" - || return 1
    _ddnsto_asus_runtime | cmp -s "$runtime/service.sh" - || return 1
    for kind in config status uninstall init; do
        case "$kind" in config) leaf=ddnsto_config.sh ;; status) leaf=ddnsto_status.sh ;;
            uninstall) leaf=uninstall_ddnsto.sh ;; init) leaf=S70ddnsto.sh ;; esac
        _ddnsto_asus_bridge "$kind" | cmp -s "$runtime/$leaf" - || return 1
    done
    for entry in $(_ddnsto_asus_plugin_files); do
        (
            _ddnsto_asus_plugin_cd "${entry%/*}" || exit 1
            leaf=${entry##*/}
            case "$leaf" in Module_ddnsto.asp|icon-ddnsto.png)
                [ ! -L "$leaf" ] && [ -f "$leaf" ] && cmp -s "$leaf" "$runtime/$leaf" ;;
                *) [ -L "$leaf" ] && [ "$(readlink "$leaf")" = "$ASUS_STATE/current/$leaf" ] ;;
            esac
        ) || return 1
    done
)

_ddnsto_asus_bridge() {
    printf '%s\n' '#!/bin/sh' 'PATH=/usr/sbin:/usr/bin:/sbin:/bin' 'export PATH' \
        'unset ENV BASH_ENV CDPATH'
    case "$1" in
        config) printf '%s\n' 'case "${1:-}" in start|stop) action=$1; shift ;; *) action=config ;; esac' \
            'exec /bin/sh /jffs/.ddnsto-installer/current/service.sh "$action" "$@"' ;;
        status) printf '%s\n' 'exec /bin/sh /jffs/.ddnsto-installer/current/service.sh status "$@"' ;;
        uninstall) printf '%s\n' 'exec /bin/sh /jffs/.ddnsto-installer/current/service.sh uninstall' ;;
        init) printf '%s\n' 'case "${1:-start}" in start|stop) ;; *) exit 2 ;; esac' \
            'exec /bin/sh /jffs/.ddnsto-installer/current/service.sh "${1:-start}"' ;;
    esac
}

ddnsto_asus_install_plugin() (
    umask 077
    [ -f "$ASUS_ATTEMPT/backup/complete" ] || return 1
    ddnsto_asus_safe_file "$ASUS_ATTEMPT/runtime/ddnsto" &&
        ddnsto_asus_safe_file "$ASUS_ATTEMPT/runtime/service.sh" || return 1
    for name in Module_ddnsto.asp icon-ddnsto.png; do
        ddnsto_asus_safe_file "$ASUS_ATTEMPT/payload/$name" || return 1
        cp "$ASUS_ATTEMPT/payload/$name" "$ASUS_ATTEMPT/runtime/$name" || return 1
        chmod 644 "$ASUS_ATTEMPT/runtime/$name" || return 1
    done
    _ddnsto_asus_bridge config > "$ASUS_ATTEMPT/runtime/ddnsto_config.sh" || return 1
    _ddnsto_asus_bridge status > "$ASUS_ATTEMPT/runtime/ddnsto_status.sh" || return 1
    _ddnsto_asus_bridge init > "$ASUS_ATTEMPT/runtime/S70ddnsto.sh" || return 1
    _ddnsto_asus_bridge uninstall > "$ASUS_ATTEMPT/runtime/uninstall_ddnsto.sh" || return 1
    chmod 755 "$ASUS_ATTEMPT/runtime/ddnsto_config.sh" \
        "$ASUS_ATTEMPT/runtime/ddnsto_status.sh" "$ASUS_ATTEMPT/runtime/S70ddnsto.sh" \
        "$ASUS_ATTEMPT/runtime/uninstall_ddnsto.sh" || return 1
    mkdir "$ASUS_ATTEMPT/publish" || return 1
    ln -s "$ASUS_ATTEMPT/runtime" "$ASUS_ATTEMPT/publish/current" || return 1
    : > "$ASUS_ATTEMPT/changed/current"
    (cd -P "$ASUS_STATE" && _ddnsto_asus_publish "$ASUS_ATTEMPT/publish/current") || return 1
    for entry in $(_ddnsto_asus_plugin_files); do
        (
            _ddnsto_asus_plugin_cd "${entry%/*}" || exit 1
            leaf=${entry##*/}
            # Static UI files must remain readable by the firmware HTTP user.
            # Copy them to the anchored destination; protected runtime stays 0700.
            case "$leaf" in Module_ddnsto.asp|icon-ddnsto.png)
                cp "$ASUS_ATTEMPT/runtime/$leaf" "$ASUS_ATTEMPT/publish/$leaf" || exit 1
                chmod 644 "$ASUS_ATTEMPT/publish/$leaf" || exit 1 ;;
                *) ln -s "$ASUS_STATE/current/$leaf" "$ASUS_ATTEMPT/publish/$leaf" || exit 1 ;;
            esac
            : > "$ASUS_ATTEMPT/changed/$leaf"
            _ddnsto_asus_publish "$ASUS_ATTEMPT/publish/$leaf"
        ) || return 1
    done
    for key in ddnsto_version ddnsto_client_version softcenter_module_ddnsto_version \
        softcenter_module_ddnsto_install softcenter_module_ddnsto_name \
        softcenter_module_ddnsto_title softcenter_module_ddnsto_description; do
        case "$key" in
            *_version) value=4.2.8 ;; *_install) value=1 ;;
            *_name) value=ddnsto ;; *_title) value=DDNSTO ;;
            *_description) value='DDNSTO remote access' ;;
        esac
        : > "$ASUS_ATTEMPT/changed/$key"
        ddnsto_asus_set "$key" "$value" || return 1
    done
)

# Always emit a fresh protected runner, including before initial installation.
_ddnsto_asus_service_call() (
    umask 077
    ddnsto_asus_private_dir "$ASUS_ATTEMPT" || return 1
    runner=$(ddnsto_asus_mktemp "$ASUS_ATTEMPT") || return 1
    _ddnsto_asus_runtime > "$runner/service.sh" || return 1
    /bin/sh "$runner/service.sh" "$1"
)
ddnsto_asus_stop() { _ddnsto_asus_service_call migrate-stop; }
ddnsto_asus_start() { _ddnsto_asus_service_call installer-start; }
ddnsto_asus_running() { _ddnsto_asus_service_call running; }

ddnsto_asus_restore_plugin() (
    umask 077
    [ -f "$ASUS_ATTEMPT/backup/complete" ] || return 1
    ddnsto_asus_stop || return 1
    restore=$(ddnsto_asus_mktemp "$ASUS_ATTEMPT") || return 1
    for entry in $(_ddnsto_asus_plugin_files); do
        (
            leaf=${entry##*/}
            [ -f "$ASUS_ATTEMPT/changed/$leaf" ] || exit 0
            _ddnsto_asus_plugin_cd "${entry%/*}" || exit 1
            saved="$ASUS_ATTEMPT/backup/files/$leaf"
            if [ -e "$saved" ] || [ -L "$saved" ]; then
                cp -pP "$saved" "$restore/$leaf" || exit 1
                _ddnsto_asus_publish "$restore/$leaf" || exit 1
            else
                rm -f "./$leaf" || exit 1
            fi
        ) || return 1
    done
    recovery_conflict=0
    for key in $(_ddnsto_asus_metadata_keys); do
        [ -f "$ASUS_ATTEMPT/changed/$key" ] || continue
        case "$key" in ddnsto_token|ddnsto_enable)
            # Main journals the intended literal value BEFORE setting dbus.
            # Never overwrite account edits made outside our transaction.
            expected=$(cat "$ASUS_ATTEMPT/changed/$key") || return 1
            live=$(ddnsto_asus_get "$key") || return 1
            if [ "$live" != "$expected" ]; then
                recovery_conflict=1
                continue
            fi ;;
        esac
        value=$(cat "$ASUS_ATTEMPT/backup/config/$key") || return 1
        ddnsto_asus_set "$key" "$value" || return 1
    done
    if [ -f "$ASUS_ATTEMPT/changed/current" ]; then
        if [ -L "$ASUS_ATTEMPT/backup/current" ]; then
            cp -pP "$ASUS_ATTEMPT/backup/current" "$restore/current" || return 1
            (cd -P "$ASUS_STATE" && _ddnsto_asus_publish "$restore/current") || return 1
        elif [ "$(cat "$ASUS_ATTEMPT/backup/config/ddnsto_enable")" != 1 ]; then
            rm -f "$ASUS_STATE/current" || return 1
        fi
        # For native rollback the reviewed runtime remains available, while
        # original plugin files are restored byte-for-byte (never executed).
    fi
    if [ "$recovery_conflict" = 1 ]; then
        printf '%s\n' 'ASUS: recovery refused: concurrent account/enable change; external values preserved' >&2
        return 1
    fi
    if [ "$(cat "$ASUS_ATTEMPT/backup/config/ddnsto_enable")" = 1 ]; then
        if [ ! -L "$ASUS_STATE/current" ]; then
            ln -s "$ASUS_ATTEMPT/runtime" "$restore/current" || return 1
            (cd -P "$ASUS_STATE" && _ddnsto_asus_publish "$restore/current") || return 1
        fi
        ddnsto_asus_start && ddnsto_asus_running || return 1
    fi
)

# Controlled transaction. OS/package/service boundaries live in ASUS adapters.
# No vendor install.sh, uninstall.sh, base.sh or dbus export is executed.
ddnsto_asus_identity() {
    if [ "$#" = 2 ]; then
        asus_existing_token=$1 asus_version=$2
    else
        asus_existing_token=$(ddnsto_asus_get ddnsto_token) || return 2
        asus_version=$(ddnsto_asus_get ddnsto_version) || return 2
    fi
    [ -z "$asus_existing_token" ] || [ "$asus_existing_token" = "$TOKEN" ] || {
        ddnsto_flow_error E_ACCOUNT '插件属于其他账号，未执行换绑' '请使用原账号重新复制命令'; return 2;
    }
    if [ -n "$asus_version" ]; then
        asus_order=$(ddnsto_version_order "$asus_version" 4.2.8) || asus_order=unknown
        case "$asus_order" in -1|0) ;; *)
            ddnsto_flow_error E_VERSION '插件版本更新或无法识别，未覆盖现有版本' '请使用对应版本安装器；不会降级'; return 2 ;;
        esac
        [ -n "$asus_existing_token" ] || {
            ddnsto_flow_error E_ACCOUNT '已安装插件缺少账号信息，未修改配置' '请先在软件中心检查 Token'; return 2;
        }
    fi
}

ddnsto_asus_checkpoint() {
    [ -z "${ASUS_CANCEL:-}" ] || [ ! -f "$ASUS_CANCEL" ] || {
        ddnsto_flow_error E_CANCELLED '安装已取消，正在完成必要恢复' '请等待当前命令结束后检查状态'; return 143;
    }
}

ddnsto_asus_snapshot_config() {
    mkdir "$ASUS_ATTEMPT/config" || return 12
    for key in ddnsto_token ddnsto_enable ddnsto_version ddnsto_client_version \
        ddnsto_feat_enabled ddnsto_feat_username ddnsto_feat_password \
        ddnsto_feat_port ddnsto_feat_disk_path_selected; do
        ddnsto_asus_get "$key" > "$ASUS_ATTEMPT/config/$key" || return 12
    done
}

ddnsto_asus_config_unchanged() {
    for key in ddnsto_token ddnsto_enable ddnsto_version ddnsto_client_version \
        ddnsto_feat_enabled ddnsto_feat_username ddnsto_feat_password \
        ddnsto_feat_port ddnsto_feat_disk_path_selected; do
        ddnsto_asus_get "$key" > "$ASUS_ATTEMPT/compare" || return 12
        cmp -s "$ASUS_ATTEMPT/config/$key" "$ASUS_ATTEMPT/compare" || return 2
    done
}

ddnsto_asus_ensure_locked() (
    umask 077
    ddnsto_asus_preflight || exit $?
    case "$TOKEN" in ''|*[!a-zA-Z0-9_-]*)
        ddnsto_flow_error E_TOKEN 'Token 格式无效' '请从控制台重新复制'; exit 2 ;;
    esac
    ddnsto_asus_busy || { ddnsto_flow_error E_BUSY '软件中心正在安装其他插件' '请等待软件中心任务结束'; exit 16; }
    ddnsto_asus_identity || exit $?
    ASUS_ATTEMPT=$(ddnsto_asus_mktemp "$ASUS_STATE") || exit 12
    # Keep the private evidence/backup on both success and failure. Never clean
    # arbitrary /tmp/ddnsto* paths; no credentials reach the diagnostic stream.
    ddnsto_asus_snapshot_config || exit $?
    ddnsto_asus_identity "$(cat "$ASUS_ATTEMPT/config/ddnsto_token")" "$(cat "$ASUS_ATTEMPT/config/ddnsto_version")" || exit $?
    ddnsto_asus_checkpoint || exit $?
    if [ "$asus_version" = 4.2.8 ] && [ "$(cat "$ASUS_ATTEMPT/config/ddnsto_enable")" = 1 ] &&
        ddnsto_asus_reusable && ddnsto_asus_running; then
        ddnsto_asus_config_unchanged && ddnsto_asus_checkpoint || exit 2
        ddnsto_flow_note installed
        ddnsto_flow_note starting
        ddnsto_flow_note started
        exit 0
    fi
    ddnsto_asus_fetch "$ASUS_ATTEMPT/package.tar.gz" || {
        ddnsto_flow_error E_DOWNLOAD '插件下载或校验失败，现有服务未停止' '请检查 HTTPS 下载后重试'; exit 11;
    }
    ddnsto_asus_extract "$ASUS_ATTEMPT/package.tar.gz" "$ASUS_ATTEMPT/payload" "$ASUS_CHANNEL" "$ASUS_ARCH" || {
        ddnsto_flow_error E_PACKAGE '插件包结构或平台标记不符合审核记录' '请联系发布者检查安装包，未执行包内脚本'; exit 11;
    }
    ddnsto_asus_checkpoint || exit $?
    ddnsto_asus_busy && ddnsto_asus_config_unchanged || {
        ddnsto_flow_error E_CONFIG '下载期间软件中心或配置发生变化' '请稍后重新执行，未覆盖修改'; exit 2;
    }
    ddnsto_asus_backup_plugin || {
        ddnsto_flow_error E_BACKUP '无法安全备份现有插件' '请检查存储和插件文件，未停止服务'; exit 12;
    }
    changed=0
    finish_asus() {
        result=$?
        trap - EXIT HUP INT TERM
        if [ "$result" != 0 ] && [ "$changed" = 1 ]; then
            if ! ddnsto_asus_restore_plugin; then
                ddnsto_flow_error E_RECOVERY '安装失败且恢复未完成，已保留私有备份' "请检查 $ASUS_ATTEMPT" || :
            fi
        fi
        exit "$result"
    }
    trap finish_asus EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    ddnsto_asus_checkpoint || exit $?
    ddnsto_flow_note installing
    changed=1
    ddnsto_asus_stop || { ddnsto_flow_error E_STOP '未确认旧进程停止，未覆盖文件' '请检查客户端进程'; exit 13; }
    ddnsto_asus_install_plugin || {
        ddnsto_flow_error E_PACKAGE '插件文件安装失败，正在尝试恢复' "备份位于 $ASUS_ATTEMPT"; exit 11;
    }
    ddnsto_asus_checkpoint || exit $?
    # Only initialize an empty account. Existing feature settings are untouched.
    [ "$(ddnsto_asus_get ddnsto_token)" = "$asus_existing_token" ] || {
        ddnsto_flow_error E_ACCOUNT '安装期间账号发生变化，不覆盖新配置' '请检查软件中心账号后重试'; exit 2;
    }
    if [ -z "$asus_existing_token" ]; then
        printf '%s' "$TOKEN" > "$ASUS_ATTEMPT/changed/ddnsto_token" || exit 12
        ddnsto_asus_set ddnsto_token "$TOKEN" || exit 12
    fi
    printf '1' > "$ASUS_ATTEMPT/changed/ddnsto_enable" || exit 12
    ddnsto_asus_set ddnsto_enable 1 || exit 12
    [ "$(ddnsto_asus_get ddnsto_token)" = "$TOKEN" ] || {
        ddnsto_flow_error E_ACCOUNT '启动前账号发生变化，不覆盖新配置' '请停止并发修改后重试'; exit 2;
    }
    ddnsto_flow_note installed
    ddnsto_flow_note starting
    ddnsto_asus_start && ddnsto_asus_running || {
        ddnsto_flow_error E_START '插件安装后未确认稳定启动，正在尝试恢复' "请检查私有备份 $ASUS_ATTEMPT"; exit 13;
    }
    ddnsto_asus_checkpoint || exit $?
    [ "$(ddnsto_asus_get ddnsto_token)" = "$TOKEN" ] || {
        ddnsto_flow_error E_ACCOUNT '启动期间账号发生变化，不能确认安装成功' '请停止并发修改后检查软件中心配置'; exit 2;
    }
    changed=0
    ddnsto_flow_note started
)

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

installer_privileged_program() {
cat <<'ZSETUP_PRIVATE_ROOT_PROGRAM'
set -eu
status() { printf '%s\n' "$*" >&2; }
installer_storage_error() { printf 'Installer storage: %s\n' "$*" >&2; }
installer_valid_directory() {
    case "$1" in
        /*) ;;
        *) installer_storage_error 'directory must be absolute'; return 2 ;;
    esac
    case "$1" in
        /|*/../*|*/..|*/./*|*/.|*//*|*'
'*|*'	'*) installer_storage_error 'directory must be a normalized non-root path'; return 2 ;;
    esac
}
installer_layout() {
    is_app=$1
    case "$is_app" in ''|*[!a-z0-9_-]*) return 2 ;; esac
    INSTALLER_SCOPE=${installer_scope:-$2}
    case "$INSTALLER_SCOPE" in user|system) ;; *) installer_storage_error 'scope must be user or system'; return 2 ;; esac
    if [ "$INSTALLER_SCOPE" = user ]; then
        : "${HOME:?HOME is required for user installation}"
        installer_valid_directory "$HOME" || return $?
        INSTALLER_PREFIX=${installer_prefix:-$HOME/.local/lib/linkease/$is_app}
        INSTALLER_COMMAND="$HOME/.local/bin/$is_app"
    else
        INSTALLER_PREFIX=${installer_prefix:-/opt/linkease/$is_app}
        INSTALLER_COMMAND="$INSTALLER_PREFIX/current/bin/$is_app"
    fi
    INSTALLER_PREFIX=${INSTALLER_PREFIX%/}
    installer_valid_directory "$INSTALLER_PREFIX"
}
installer_space_budget() {
    [ "$#" = 4 ] || return 2
    is_sum=0
    for is_size in "$@"; do
        case "$is_size" in ''|*[!0-9]*) installer_storage_error 'artifact size budget is unknown or invalid'; return 2 ;; esac
        [ "${#is_size}" -le 10 ] && [ "$is_size" -le 1900000000 ] || return 2
        case "$is_size" in 0) ;; 0*) return 2 ;; esac
        is_sum=$((is_sum + is_size))
        [ "$is_sum" -le 1900000000 ] || return 2
    done
    INSTALLER_REQUIRED_BYTES=$((is_sum + (is_sum + 9) / 10 + 8388608))
}
installer_storage_check() {
    is_path=$1; is_needed=$2; is_exec=$3; is_write=$4
    case "$is_needed" in ''|*[!0-9]*) return 2 ;; esac
    [ "${#is_needed}" -le 10 ] && [ "$is_needed" -le 2147483647 ] || return 2
    case "$is_exec:$is_write" in 0:0|0:1|1:0|1:1) ;; *) return 2 ;; esac
    is_memory=$("$ZSETUP_BIN" storage "$is_path" get memory_backed) || {
        installer_storage_error 'storage probe unavailable; a Rust zsetup with storage support is required'; return 12;
    }
    case "$is_memory" in
        false) ;;
        true) installer_storage_error "memory filesystem at $is_path; choose a persistent directory"; return 12 ;;
        *) installer_storage_error "cannot establish persistent backing at $is_path; choose a verified directory"; return 12 ;;
    esac
    is_readonly=$("$ZSETUP_BIN" storage "$is_path" get read_only) || return 12
    [ "$is_readonly" = false ] || { installer_storage_error "read-only or unknown mount at $is_path"; return 12; }
    if [ "$is_exec" = 1 ]; then
        is_noexec=$("$ZSETUP_BIN" storage "$is_path" get noexec) || return 12
        [ "$is_noexec" = false ] || { installer_storage_error "execution is unavailable at $is_path"; return 12; }
    fi
    if [ "$is_write" = 1 ]; then
        is_writable=$("$ZSETUP_BIN" storage "$is_path" get writable) || return 12
        [ "$is_writable" = true ] || { installer_storage_error "write permission is required at $is_path"; return 12; }
    fi
    is_available=$("$ZSETUP_BIN" storage "$is_path" get available_bytes) || return 12
    case "$is_available" in ''|*[!0-9]*) return 12 ;; esac
    [ "$is_available" -ge "$is_needed" ] || {
        installer_storage_error "insufficient space at $is_path: need $is_needed bytes, available $is_available; choose another directory"; return 12;
    }
    is_inodes=$("$ZSETUP_BIN" storage "$is_path" get available_inodes) || return 12
    case "$is_inodes" in
        unknown) installer_storage_error "inode availability is unknown at $is_path" ;;
        ''|*[!0-9]*) return 12 ;;
        *) [ "$is_inodes" -gt 0 ] || { installer_storage_error "no free inodes at $is_path"; return 12; } ;;
    esac
}
installer_storage_select() {
    INSTALLER_STORAGE_PATH=$1
    is_select_needed=$2; is_select_exec=$3; is_select_write=$4
    while :; do
        if installer_storage_check "$INSTALLER_STORAGE_PATH" "$is_select_needed" "$is_select_exec" "$is_select_write"; then
            return 0
        fi
        [ -t 0 ] || return 12
        printf 'Enter another persistent absolute directory (empty cancels): ' >&2
        IFS= read -r INSTALLER_STORAGE_PATH || return 12
        [ -n "$INSTALLER_STORAGE_PATH" ] || return 12
        installer_valid_directory "$INSTALLER_STORAGE_PATH" || return 2
    done
}
installer_preflight() {
    installer_layout "$1" "$2" || return $?
    installer_storage_select "$INSTALLER_PREFIX" "$3" 1 "$4" || return $?
    INSTALLER_PREFIX=$INSTALLER_STORAGE_PATH
    INSTALLER_WORK_ROOT=${installer_work_dir:-${ZSETUP_WORK_DIR:-$INSTALLER_PREFIX/.staging}}
    installer_valid_directory "$INSTALLER_WORK_ROOT" || return $?
    installer_storage_select "$INSTALLER_WORK_ROOT" "$3" 1 "$4" || return $?
    INSTALLER_WORK_ROOT=$INSTALLER_STORAGE_PATH
    printf 'Install plan: application=%s scope=%s prefix=%s staging=%s peak-extra-bytes=%s\n' \
        "$1" "$INSTALLER_SCOPE" "$INSTALLER_PREFIX" "$INSTALLER_WORK_ROOT" "$3" >&2
}
installer_policy() {
    INSTALLER_DOWNLOAD_BYTES=0; INSTALLER_EXPANDED_BYTES=0; INSTALLER_FILE_COUNT=0
    INSTALLER_RESERVE=8388608
    case "$1" in
        fastnet|fastpve|linkspace|ks-cli|kspeeder) INSTALLER_MAX_DOWNLOAD=33554432; INSTALLER_MAX_EXPANDED=0; INSTALLER_MAX_FILES=1 ;;
        ddnsto) INSTALLER_MAX_DOWNLOAD=33554432; INSTALLER_MAX_EXPANDED=67108864; INSTALLER_MAX_FILES=16 ;;
        linkease) INSTALLER_MAX_DOWNLOAD=134217728; INSTALLER_MAX_EXPANDED=268435456; INSTALLER_MAX_FILES=128 ;;
        *) return 2 ;;
    esac
    ib_commit_budget=$INSTALLER_MAX_EXPANDED
    [ "$ib_commit_budget" != 0 ] || ib_commit_budget=$INSTALLER_MAX_DOWNLOAD
    installer_space_budget "$INSTALLER_MAX_DOWNLOAD" "$INSTALLER_MAX_EXPANDED" "$ib_commit_budget" 0
    printf '%s\n' 'Artifact size metadata is incomplete; using measured safety ceilings, not a guaranteed space estimate.' >&2
}
installer_file_size() {
    [ -f "$1" ] && [ ! -L "$1" ] || return 11
    set -- $(wc -c < "$1")
    case "$1" in ''|*[!0-9]*) return 11 ;; esac
    INSTALLER_FILE_SIZE=$1
}
installer_download() {
    ib_relative=$1; ib_output=$2; ib_sha=${3:-}; ib_fresh=${4:-0}; ib_expected_size=${5:-}
    case "${ib_relative##*/}" in
        version.txt|ks-cli-version.txt|VERSION|VERSION_LITE|SHA256SUMS) ib_metadata=1; ib_limit=16384 ;;
        *) ib_metadata=0; ib_limit=$((INSTALLER_MAX_DOWNLOAD - INSTALLER_DOWNLOAD_BYTES)); [ "$ib_limit" -gt 0 ] || return 11 ;;
    esac
    if [ "$ib_metadata" = 0 ] && [ -n "${ZSETUP_PRIVILEGED_STAGE:-}" ] && [ -n "$ib_sha" ]; then
        ib_prepared="$ZSETUP_PRIVILEGED_STAGE/${ib_relative##*/}"
        if [ -f "$ib_prepared" ] && [ ! -L "$ib_prepared" ]; then
            installer_exec_native "$ZSETUP_BIN" capture -o "$ib_output" --max-bytes "$ib_limit" --min-free-bytes "$INSTALLER_RESERVE" --timeout 30s -- cat "$ib_prepared" || return $?
        fi
    fi
    set -- "$ZSETUP_BIN" download -o "$ib_output" --max-bytes "$ib_limit" --min-free-bytes "$INSTALLER_RESERVE"
    [ -z "$ib_sha" ] || set -- "$@" --sha256 "$ib_sha"
    [ -z "${ib_expected_size:-}" ] || set -- "$@" --size "$ib_expected_size"
    [ "$ib_fresh" = 0 ] || set -- "$@" --no-cache
    [ -z "${ZSETUP_CA_FILE:-}" ] || set -- "$@" --ca-file "$ZSETUP_CA_FILE"
    for ib_base in $ZSETUP_SOURCE_BASES; do set -- "$@" "${ib_base%/}/$INSTALLER_REMOTE_APP/$ib_relative"; done
    [ -z "${ZSETUP_SOURCE_FALLBACK:-}" ] || set -- "$@" --fallback-url "${ZSETUP_SOURCE_FALLBACK%/}/$INSTALLER_REMOTE_APP/$ib_relative"
    installer_exec_native "$@" || return $?
    if [ "$ib_metadata" = 0 ]; then
        installer_file_size "$ib_output" || return $?
        INSTALLER_DOWNLOAD_BYTES=$((INSTALLER_DOWNLOAD_BYTES + INSTALLER_FILE_SIZE))
        [ "$INSTALLER_DOWNLOAD_BYTES" -le "$INSTALLER_MAX_DOWNLOAD" ] || return 11
    fi
}
installer_extract_member() {
    ib_output=$1; shift
    ib_remaining=$((INSTALLER_MAX_EXPANDED - INSTALLER_EXPANDED_BYTES))
    [ "$ib_remaining" -gt 0 ] && [ "$INSTALLER_FILE_COUNT" -lt "$INSTALLER_MAX_FILES" ] || return 11
    installer_exec_native "$ZSETUP_BIN" capture -o "$ib_output" --max-bytes "$ib_remaining" --min-free-bytes "$INSTALLER_RESERVE" -- "$@" || return $?
    installer_file_size "$ib_output" || return $?
    [ "$INSTALLER_FILE_SIZE" -gt 0 ] || return 11
    INSTALLER_EXPANDED_BYTES=$((INSTALLER_EXPANDED_BYTES + INSTALLER_FILE_SIZE))
    INSTALLER_FILE_COUNT=$((INSTALLER_FILE_COUNT + 1))
}
installer_exec_native() {
    if [ "${INSTALLER_TRANSACTION_ACTIVE:-0}" = 1 ]; then installer_owned_native "$@"; else "$@"; fi
}
installer_transaction_begin() {
    umask 077
    INSTALLER_CHILD=
    INSTALLER_SPAWNING=0
    INSTALLER_SIGNAL=0
    INSTALLER_LOCK_HELD=0
    INSTALLER_TRANSACTION_ACTIVE=0
    transaction_dir=
    [ ! -L "$INSTALLER_WORK_ROOT" ] || return 12
    mkdir -p "$INSTALLER_WORK_ROOT" || return 12
    [ "$("$ZSETUP_BIN" storage "$INSTALLER_WORK_ROOT" get private_directory)" = true ] || {
        printf 'Installer: staging must be a private directory owned by the current user: %s\n' "$INSTALLER_WORK_ROOT" >&2
        return 12
    }
    INSTALLER_LOCK="$INSTALLER_WORK_ROOT/.install-lock"
    if ! mkdir "$INSTALLER_LOCK" 2>/dev/null; then
        printf 'Installer: active or interrupted transaction at %s; inspect/recover it before retrying.\n' "$INSTALLER_LOCK" >&2
        return 2
    fi
    INSTALLER_LOCK_HELD=1
    trap 'installer_transaction_exit $?' EXIT
    trap 'installer_transaction_signal 129' HUP
    trap 'installer_transaction_signal 130' INT
    trap 'installer_transaction_signal 143' TERM
    printf '%s\n' "$$" > "$INSTALLER_LOCK/owner"
    transaction_dir=$(mktemp -d "$INSTALLER_WORK_ROOT/.transaction.XXXXXX") || return 12
    printf '%s\n' "$$" > "$transaction_dir/.owner"
    INSTALLER_TRANSACTION_ACTIVE=1
}
installer_transaction_signal() {
    INSTALLER_SIGNAL=$1
    [ "$INSTALLER_SPAWNING" = 1 ] || exit "$INSTALLER_SIGNAL"
}
installer_owned_native() {
    [ "$1" = "$ZSETUP_BIN" ] || return 2
    [ "$INSTALLER_SIGNAL" = 0 ] || return "$INSTALLER_SIGNAL"
    INSTALLER_SPAWNING=1
    if [ "${INSTALLER_BRIDGE_OPEN:-0}" = 1 ]; then
        "$@" <&0 3>&- 4>&- &
    else
        "$@" <&0 &
    fi
    INSTALLER_CHILD=$!
    INSTALLER_SPAWNING=0
    [ "$INSTALLER_SIGNAL" = 0 ] || exit "$INSTALLER_SIGNAL"
    it_status=0
    wait "$INSTALLER_CHILD" || it_status=$?
    INSTALLER_CHILD=
    return "$it_status"
}
installer_transaction_cleanup() {
    if [ -n "$INSTALLER_CHILD" ]; then
        kill -TERM "$INSTALLER_CHILD" 2>/dev/null || true
        wait "$INSTALLER_CHILD" 2>/dev/null || true
        INSTALLER_CHILD=
    fi
    if [ -n "${INSTALLER_CLEANUP_HOOK:-}" ]; then
        INSTALLER_SIGNAL=0
        "$INSTALLER_CLEANUP_HOOK" || {
            printf 'Installer: recovery incomplete; staging and lease retained at %s\n' "$INSTALLER_WORK_ROOT" >&2
            return 12
        }
    fi
    if [ -n "$transaction_dir" ]; then
        case "$transaction_dir" in "$INSTALLER_WORK_ROOT"/.transaction.*) ;; *) return 12 ;; esac
        [ ! -L "$transaction_dir" ] && [ ! -L "$transaction_dir/.owner" ] && [ -f "$transaction_dir/.owner" ] || return 12
        set -- $(wc -c < "$transaction_dir/.owner")
        [ "$1" -le 16 ] || return 12
        it_owner=
        IFS= read -r it_owner < "$transaction_dir/.owner" || return 12
        [ "$it_owner" = "$$" ] || return 12
        rm -rf "$transaction_dir" || return 12
        transaction_dir=
    fi
    if [ "$INSTALLER_LOCK_HELD" = 1 ]; then
        rm -f "$INSTALLER_LOCK/owner" || return 12
        rmdir "$INSTALLER_LOCK" || return 12
        INSTALLER_LOCK_HELD=0
    fi
    INSTALLER_TRANSACTION_ACTIVE=0
}
installer_transaction_exit() {
    it_exit=$1
    INSTALLER_EXIT_CODE=$it_exit
    trap - EXIT
    trap '' HUP INT TERM
    installer_transaction_cleanup || { [ "$it_exit" != 0 ] || it_exit=12; }
    exit "$it_exit"
}
installer_transaction_finish() {
    INSTALLER_EXIT_CODE=0
    installer_transaction_cleanup || return $?
    trap - EXIT HUP INT TERM
}
installer_dispatch() {
    il_app=$1; shift
    installer_scope=${ZSETUP_INSTALL_SCOPE:-}
    installer_prefix=${ZSETUP_INSTALL_PREFIX:-}
    installer_work_dir=
    il_seen_scope=0; il_seen_prefix=0; il_seen_work=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --installer-scope|--installer-prefix|--installer-work-dir)
                [ "$#" -ge 2 ] && [ -n "$2" ] || return 2
                case "$1" in
                    --installer-scope) [ "$il_seen_scope" = 0 ] || return 2; installer_scope=$2; il_seen_scope=1 ;;
                    --installer-prefix) [ "$il_seen_prefix" = 0 ] || return 2; installer_prefix=$2; il_seen_prefix=1 ;;
                    *) [ "$il_seen_work" = 0 ] || return 2; installer_work_dir=$2; il_seen_work=1 ;;
                esac
                shift 2 ;;
            --) shift; break ;;
            --installer-*) printf 'Unknown installer option: %s\n' "$1" >&2; return 2 ;;
            *) break ;;
        esac
    done
    il_function=$(IFS=-; set -- $il_app; IFS=_; printf '%s' "$*")
    "${il_function}_install" "$@"
}
installer_require_root() {
    if [ "$("$ZSETUP_BIN" storage / get effective_uid)" != 0 ]; then
        printf '%s\n' 'Installer: this operation installs a system service and requires root.' \
            'Run the downloaded installer explicitly with sudo (or from a root shell); unattended installation never requests a password.' >&2
        return 2
    fi
}
installer_service_prepare() {
    SERVICE_APP=$1
    installer_layout "$1" system || return $?
    [ "$INSTALLER_SCOPE" = system ] || { printf 'Installer: %s requires system scope; user services are not supported.\n' "$1" >&2; return 2; }
    installer_require_root || return $?
    installer_policy "$1" || return $?
    installer_preflight "$1" system "$INSTALLER_REQUIRED_BYTES" 1 || return $?
    for service_protected_path in "$INSTALLER_PREFIX" "$INSTALLER_WORK_ROOT"; do
        [ "$("$ZSETUP_BIN" storage "$service_protected_path" get system_protected)" = true ] || {
            printf 'Installer: system payload/staging ancestors must be root-owned, without symlinks or group/other write access: %s\n' "$service_protected_path" >&2; return 12;
        }
    done
    case "$1" in
        ddnsto) SERVICE_NAME=com.linkease.ddnstoshell.service; SERVICE_CONFIG=/etc/ddnsto/ddnsto-config.json ;;
        linkease) SERVICE_NAME=com.linkease.linkeasedaemon.service; SERVICE_CONFIG= ;;
        *) return 2 ;;
    esac
    SERVICE_UNIT="/etc/systemd/system/$SERVICE_NAME"
    SERVICE_BACKEND=systemd
    if [ ! -d /run/systemd/system ] || ! command -v systemctl >/dev/null 2>&1; then
        printf '%s\n' 'Installer: migration of non-systemd service supervision is pending; retain the legacy installer for this system.' >&2
        return 2
    fi
    [ "$("$ZSETUP_BIN" storage "$SERVICE_UNIT" get system_protected)" = true ] || return 12
    if [ -n "$SERVICE_CONFIG" ]; then
        [ "$("$ZSETUP_BIN" storage "$SERVICE_CONFIG" get system_protected)" = true ] || return 12
    fi
    SERVICE_OLD=
    SERVICE_CHANGED=0; SERVICE_NEW_VERSION=0; SERVICE_CANDIDATE=; SERVICE_GOOD=0
    SERVICE_HAD_UNIT=0; SERVICE_WAS_ACTIVE=0; SERVICE_WAS_ENABLED=0; SERVICE_HAD_CONFIG=0; SERVICE_CONFIG_TOUCHED=0
    SERVICE_DEST_LOCK_HELD=0
    SERVICE_COMMAND="${HOME:?HOME is required}/.local/bin/$SERVICE_APP"
    SERVICE_ALIAS_USER=
    case "${SUDO_UID:-0}" in ''|*[!0-9]*) return 2 ;; esac
    if [ "${SUDO_UID:-0}" != 0 ]; then
        command -v getent >/dev/null 2>&1 && command -v runuser >/dev/null 2>&1 || {
            printf '%s\n' 'Installer: getent and runuser are required to create the sudo caller command without root writes into its HOME.' >&2; return 2;
        }
        SERVICE_ALIAS_USER=pending
    elif [ "$("$ZSETUP_BIN" storage "${SERVICE_COMMAND%/*}" get system_protected)" != true ]; then
        printf '%s\n' 'Installer: invoke sudo with its root HOME; do not preserve a user-writable HOME for root writes.' >&2; return 2;
    fi
    if [ -e "$INSTALLER_PREFIX/.managed" ] || [ -L "$INSTALLER_PREFIX/.managed" ]; then
        [ "$("$ZSETUP_BIN" storage "$INSTALLER_PREFIX/.managed" get system_protected)" = true ] || return 12
        installer_file_size "$INSTALLER_PREFIX/.managed" || return 2
        [ "$INSTALLER_FILE_SIZE" -le 65 ] || return 2
        IFS= read -r service_owner < "$INSTALLER_PREFIX/.managed" || return 2
        [ "$service_owner" = "$SERVICE_APP" ] || return 2
        [ "$("$ZSETUP_BIN" storage "$INSTALLER_PREFIX" get system_protected)" = true ] || return 12
    else
        for service_entry in "$INSTALLER_PREFIX"/* "$INSTALLER_PREFIX"/.[!.]* "$INSTALLER_PREFIX"/..?*; do
            [ ! -e "$service_entry" ] && [ ! -L "$service_entry" ] || { printf 'Installer: unowned installation at %s\n' "$INSTALLER_PREFIX" >&2; return 2; }
        done
        for service_legacy in "/usr/bin/$1" "/usr/local/bin/$1" "/usr/sbin/$1" "$SERVICE_UNIT" "/etc/init.d/$SERVICE_NAME" "/etc/init.d/${SERVICE_NAME%.service}"; do
            [ ! -e "$service_legacy" ] && [ ! -L "$service_legacy" ] || { printf 'Installer: existing installation requires explicit migration: %s\n' "$service_legacy" >&2; return 2; }
        done
    fi
    for service_path in "$INSTALLER_PREFIX/versions" "$INSTALLER_PREFIX/.managed"; do [ ! -L "$service_path" ] || return 2; done
    installer_service_read_current || return $?
    umask 022
    mkdir -p "$INSTALLER_PREFIX" "$INSTALLER_PREFIX/versions" || return 12
    [ "$("$ZSETUP_BIN" storage "$INSTALLER_PREFIX/versions" get system_protected)" = true ] || return 12
    if [ ! -e "$INSTALLER_PREFIX/.managed" ]; then
        (set -C; printf '%s\n' "$SERVICE_APP" > "$INSTALLER_PREFIX/.managed") || return 2
    fi
    installer_transaction_begin || return $?
    INSTALLER_CLEANUP_HOOK=installer_service_cleanup
    if command -v "${SERVICE_APP}_service_lock" >/dev/null 2>&1; then
        "${SERVICE_APP}_service_lock" || return $?
    fi
    if ! mkdir "$INSTALLER_PREFIX/.service-lock" 2>/dev/null; then
        printf 'Installer: active or interrupted destination transaction at %s/.service-lock\n' "$INSTALLER_PREFIX" >&2; return 2
    fi
    SERVICE_DEST_LOCK_HELD=1
    printf '%s\n' "$$" > "$INSTALLER_PREFIX/.service-lock/owner"
    installer_service_read_current || return $?
    if [ "$SERVICE_ALIAS_USER" = pending ]; then
        installer_exec_native "$ZSETUP_BIN" capture -o "$transaction_dir/passwd" --max-bytes 4096 --timeout 5s -- getent passwd "$SUDO_UID" || return 2
        IFS=: read -r service_user service_pass service_uid service_gid service_gecos service_home service_shell < "$transaction_dir/passwd" || return 2
        [ "$service_uid" = "$SUDO_UID" ] && [ "$service_uid" != 0 ] && [ -n "$service_user" ] || return 2
        installer_valid_directory "$service_home" || return 2
        SERVICE_ALIAS_USER=$service_user
        SERVICE_COMMAND="$service_home/.local/bin/$SERVICE_APP"
    fi
    installer_exec_native "$ZSETUP_BIN" capture -o "$transaction_dir/fragment" --max-bytes 4096 --timeout 5s -- systemctl show --property=FragmentPath --value "$SERVICE_NAME" || return $?
    service_fragment=
    IFS= read -r service_fragment < "$transaction_dir/fragment" || service_fragment=
    [ -z "$service_fragment" ] || { [ "$service_fragment" = "$SERVICE_UNIT" ] && [ "$SERVICE_HAD_UNIT" = 1 ]; } || {
        printf 'Installer: existing service belongs to another installation: %s\n' "$service_fragment" >&2; return 2;
    }
    if [ "$SERVICE_HAD_UNIT" = 1 ]; then
        cp -p "$SERVICE_UNIT" "$transaction_dir/old-unit" || return 12
        if installer_service_manager is-active; then SERVICE_WAS_ACTIVE=1; fi
        if installer_service_manager is-enabled; then SERVICE_WAS_ENABLED=1; fi
    fi
    if [ -n "$SERVICE_CONFIG" ] && [ -e "$SERVICE_CONFIG" ]; then
        [ "$("$ZSETUP_BIN" storage "$SERVICE_CONFIG" get system_protected)" = true ] || return 12
        installer_file_size "$SERVICE_CONFIG" || return 2
        [ "$INSTALLER_FILE_SIZE" -le 16384 ] || return 11
        cp -p "$SERVICE_CONFIG" "$transaction_dir/old-config" || return 12
        SERVICE_HAD_CONFIG=1
    fi
    if [ -z "$SERVICE_ALIAS_USER" ] && { [ -e "$SERVICE_COMMAND" ] || [ -L "$SERVICE_COMMAND" ]; }; then
        [ -L "$SERVICE_COMMAND" ] && [ "$(readlink "$SERVICE_COMMAND")" = "$INSTALLER_PREFIX/current/bin/$SERVICE_APP" ] || return 2
    fi
}
installer_service_read_current() {
    SERVICE_OLD=; SERVICE_HAD_UNIT=0
    if [ -L "$INSTALLER_PREFIX/current" ]; then
        SERVICE_OLD=$(readlink "$INSTALLER_PREFIX/current") || return 2
        case "$SERVICE_OLD" in versions/*) ;; *) return 2 ;; esac
        service_old_version=${SERVICE_OLD#versions/}
        installer_service_version "$service_old_version" || return 2
        [ -x "$INSTALLER_PREFIX/$SERVICE_OLD/bin/$SERVICE_APP" ] || return 2
        [ "$("$ZSETUP_BIN" storage "$INSTALLER_PREFIX/$SERVICE_OLD/bin/$SERVICE_APP" get system_protected)" = true ] || return 12
    elif [ -e "$INSTALLER_PREFIX/current" ]; then return 2
    fi
    if [ -e "$SERVICE_UNIT" ] || [ -L "$SERVICE_UNIT" ]; then
        [ -n "$SERVICE_OLD" ] || return 2
        installer_service_definition "$INSTALLER_PREFIX/$SERVICE_OLD/bin/$SERVICE_APP" || return 2
        SERVICE_HAD_UNIT=1
    fi
}
installer_service_alias() {
    set -- /bin/sh -c 'set -eu
umask 077
directory=$1; application=$2; target=$3
command_path="$directory/$application"
if [ -e "$command_path" ] || [ -L "$command_path" ]; then
    [ -L "$command_path" ] && [ "$(readlink "$command_path")" = "$target" ] || exit 2
fi
mkdir -p "$directory"
candidate="$directory/.$application.$$"
trap '\''rm -f "$candidate"'\'' EXIT
ln -s "$target" "$candidate"
mv -f "$candidate" "$command_path"
' installer-alias "${SERVICE_COMMAND%/*}" "$SERVICE_APP" "$INSTALLER_PREFIX/current/bin/$SERVICE_APP"
    if [ -n "$SERVICE_ALIAS_USER" ]; then
        installer_exec_native "$ZSETUP_BIN" run -- runuser -u "$SERVICE_ALIAS_USER" -- "$@"
    else
        installer_exec_native "$ZSETUP_BIN" run -- "$@"
    fi
}
installer_service_version() {
    case "$1" in ''|*[!0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._+-]*|.*|-*|+*|_*) return 2 ;; esac
    [ "${#1}" -le 64 ]
}
installer_service_manager() {
    service_action=$1
    if [ "$SERVICE_BACKEND" = systemd ]; then
        case "$service_action" in
            is-active|is-enabled) installer_exec_native "$ZSETUP_BIN" run -- systemctl "$service_action" --quiet "$SERVICE_NAME" ;;
            reload) installer_exec_native "$ZSETUP_BIN" run -- systemctl daemon-reload ;;
            *) installer_exec_native "$ZSETUP_BIN" run -- systemctl "$service_action" "$SERVICE_NAME" ;;
        esac
    else
        case "$service_action" in
            reload|enable|disable) return 0 ;;
            is-active) service_action=status ;;
        esac
        installer_exec_native "$ZSETUP_BIN" run -- "$SERVICE_UNIT" "$service_action"
    fi
}
installer_service_definition() {
    installer_file_size "$SERVICE_UNIT" || return 2
    [ "$INSTALLER_FILE_SIZE" -le 16384 ] || return 11
    [ "$("$ZSETUP_BIN" storage "$SERVICE_UNIT" get system_protected)" = true ] || return 12
    service_expected=$1
    installer_service_escape_exec "$service_expected"
    service_expected_escaped=$service_escaped
    installer_service_escape_exec "${service_expected%/*}/.service-run"
    service_expected_wrapper=$service_escaped
    service_found=0
    while IFS= read -r service_line || [ -n "$service_line" ]; do
        case "$SERVICE_BACKEND:$service_line" in
            "systemd:ExecStart=$service_expected \"run\""|"systemd:ExecStart=\"$service_expected_escaped\" \"run\"") service_found=$((service_found + 1)) ;;
            "systemd:ExecStart=/bin/sh \"$service_expected_wrapper\"") service_found=$((service_found + 1)) ;;
            sysv:*"$service_expected"*) service_found=$((service_found + 1)) ;;
        esac
    done < "$SERVICE_UNIT"
    [ "$service_found" = 1 ]
}
installer_service_replace() {
    service_replaced=
    service_rest=$1; service_needle=$2; service_replacement=$3
    while :; do
        case "$service_rest" in
            *"$service_needle"*) service_replaced="$service_replaced${service_rest%%"$service_needle"*}$service_replacement"; service_rest=${service_rest#*"$service_needle"} ;;
            *) service_replaced="$service_replaced$service_rest"; break ;;
        esac
    done
}
installer_service_escape_exec() {
    service_escaped=$1
    installer_service_replace "$service_escaped" '\' '\\'; service_escaped=$service_replaced
    installer_service_replace "$service_escaped" '"' '\"'; service_escaped=$service_replaced
    installer_service_replace "$service_escaped" '%' '%%'; service_escaped=$service_replaced
    installer_service_replace "$service_escaped" '$' '$$'; service_escaped=$service_replaced
}
installer_service_quote_unit() {
    [ "$SERVICE_BACKEND" = systemd ] || return 0
    installer_service_escape_exec "${SERVICE_EXEC%/*}/.service-run"
    service_escaped_exec=$service_escaped
    installer_service_replace "$SERVICE_EXEC" '%' '%%'
    service_condition=$service_replaced
    service_exec_count=0
    while IFS= read -r service_line || [ -n "$service_line" ]; do
        case "$service_line" in
            ExecStart=*) printf 'ExecStart=/bin/sh "%s"\n' "$service_escaped_exec"; service_exec_count=$((service_exec_count + 1)) ;;
            ConditionFileIsExecutable=*) printf 'ConditionFileIsExecutable=%s\n' "$service_condition" ;;
            *) printf '%s\n' "$service_line" ;;
        esac
    done < "$SERVICE_UNIT" > "$transaction_dir/new-unit"
    [ "$service_exec_count" = 1 ] || return 11
    installer_exec_native "$ZSETUP_BIN" capture -o "$SERVICE_UNIT" --max-bytes 16384 --min-free-bytes "$INSTALLER_RESERVE" -- cat "$transaction_dir/new-unit"
}
installer_service_cached() {
    SERVICE_VERSION=$1; SERVICE_DIGEST=$2
    installer_service_version "$SERVICE_VERSION" || return 2
    SERVICE_VERSION_DIR="$INSTALLER_PREFIX/versions/$SERVICE_VERSION"
    SERVICE_EXEC="$SERVICE_VERSION_DIR/bin/$SERVICE_APP"
    SERVICE_CACHED=0
    [ ! -L "$SERVICE_VERSION_DIR" ] || return 2
    if [ -e "$SERVICE_VERSION_DIR" ]; then
        [ "$("$ZSETUP_BIN" storage "$SERVICE_VERSION_DIR/.arch" get system_protected)" = true ] || return 12
        installer_file_size "$SERVICE_VERSION_DIR/.arch" || return 2
        [ "$INSTALLER_FILE_SIZE" -le 32 ] || return 2
        IFS= read -r service_cached_arch < "$SERVICE_VERSION_DIR/.arch" || return 2
        [ "$service_cached_arch" = "$arch" ] || {
            printf '%s\n' 'Installer: cached payload architecture differs; use a new protected prefix or explicit migration.' >&2
            return 2
        }
        installer_file_size "$SERVICE_VERSION_DIR/.artifact-sha256" || return 2
        [ "$INSTALLER_FILE_SIZE" -le 160 ] || return 2
        IFS= read -r service_digest < "$SERVICE_VERSION_DIR/.artifact-sha256" || return 2
        [ "$service_digest" = "$SERVICE_DIGEST" ] || { printf 'Installer: immutable version has a different digest.\n' >&2; return 11; }
        [ -x "$SERVICE_EXEC" ] && [ ! -L "$SERVICE_EXEC" ] || return 11
        [ -x "$SERVICE_VERSION_DIR/bin/.service-run" ] && [ ! -L "$SERVICE_VERSION_DIR/bin/.service-run" ] || return 11
        for service_cached_file in "$SERVICE_EXEC" "$SERVICE_VERSION_DIR/.artifact-sha256"; do
            [ "$("$ZSETUP_BIN" storage "$service_cached_file" get system_protected)" = true ] || return 12
        done
        installer_file_size "$SERVICE_VERSION_DIR/.files" || return 11
        [ "$INSTALLER_FILE_SIZE" -le 16384 ] || return 11
        [ "$("$ZSETUP_BIN" storage "$SERVICE_VERSION_DIR/.files" get system_protected)" = true ] || return 12
        service_cached_count=0; service_cached_bytes=0
        while IFS= read -r service_cached_relative; do
            case "$service_cached_relative" in ''|/*|*[!0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._+/-]*|../*|*/../*|*/..|./*|*/./*|*/.|*//* ) return 11 ;; esac
            service_cached_file="$SERVICE_VERSION_DIR/bin/$service_cached_relative"
            installer_file_size "$service_cached_file" || return 11
            service_cached_bytes=$((service_cached_bytes + INSTALLER_FILE_SIZE))
            service_cached_count=$((service_cached_count + 1))
            [ "$service_cached_count" -le "$INSTALLER_MAX_FILES" ] && [ "$service_cached_bytes" -le "$INSTALLER_MAX_EXPANDED" ] || return 11
            [ "$("$ZSETUP_BIN" storage "$service_cached_file" get system_protected)" = true ] || return 12
        done < "$SERVICE_VERSION_DIR/.files"
        [ "$service_cached_count" -gt 0 ] || return 11
        SERVICE_CACHED=1
        status '      Using verified cached installed version'
    fi
}
installer_service_copy() {
    service_relative=$1
    service_destination="$SERVICE_CANDIDATE/bin/$service_relative"
    mkdir -p "${service_destination%/*}" || return 12
    chmod 0755 "${service_destination%/*}"
    installer_exec_native "$ZSETUP_BIN" capture -o "$service_destination" --max-bytes "$INSTALLER_MAX_EXPANDED" --min-free-bytes "$INSTALLER_RESERVE" -- cat "$transaction_dir/products/$service_relative" || return $?
    chmod 0755 "$service_destination" || return 12
    printf '%s\n' "$service_relative" >> "$SERVICE_CANDIDATE/.files"
}
installer_service_stage() {
    SERVICE_CANDIDATE="$INSTALLER_PREFIX/versions/.candidate.$$"
    mkdir "$SERVICE_CANDIDATE" || return 12
    mkdir "$SERVICE_CANDIDATE/bin" || return 12
    chmod 0755 "$SERVICE_CANDIDATE" "$SERVICE_CANDIDATE/bin"
    : > "$SERVICE_CANDIDATE/.files"
    installer_service_replace "$SERVICE_EXEC" "'" "'\\''"
    printf '#!/bin/sh\nexec '\''%s'\'' run\n' "$service_replaced" > "$SERVICE_CANDIDATE/bin/.service-run"
    chmod 0755 "$SERVICE_CANDIDATE/bin/.service-run"
    printf '%s\n' .service-run >> "$SERVICE_CANDIDATE/.files"
}
installer_service_commit_version() {
    printf '%s\n' "$SERVICE_DIGEST" > "$SERVICE_CANDIDATE/.artifact-sha256"
    printf '%s\n' "$arch" > "$SERVICE_CANDIDATE/.arch"
    chmod 0644 "$SERVICE_CANDIDATE/.artifact-sha256" "$SERVICE_CANDIDATE/.files" "$SERVICE_CANDIDATE/.arch" || return 12
    [ ! -e "$SERVICE_VERSION_DIR" ] && [ ! -L "$SERVICE_VERSION_DIR" ] || return 2
    mv "$SERVICE_CANDIDATE" "$SERVICE_VERSION_DIR" || return 12
    SERVICE_CANDIDATE=; SERVICE_NEW_VERSION=1
}
installer_service_activate() {
    installer_storage_check "$INSTALLER_PREFIX" "$INSTALLER_RESERVE" 1 1 || return $?
    [ "$("$ZSETUP_BIN" storage "$SERVICE_VERSION_DIR/bin" get system_protected)" = true ] || return 12
    if [ "$SERVICE_HAD_UNIT" = 1 ]; then installer_service_manager stop || return $?; fi
    SERVICE_CHANGED=1
    ln -s "versions/$SERVICE_VERSION" "$INSTALLER_PREFIX/.current.$$" || return 12
    mv -fT "$INSTALLER_PREFIX/.current.$$" "$INSTALLER_PREFIX/current" || return 12
    SERVICE_CONFIG_TOUCHED=1
    "${SERVICE_APP}_register" || return $?
    installer_service_definition "$SERVICE_EXEC" || { printf 'Installer: product returned success without the expected service definition.\n' >&2; return 11; }
    installer_service_quote_unit || return $?
    installer_service_manager reload || return $?
    installer_service_manager enable || return $?
    installer_service_manager start || return $?
    installer_service_manager is-active || return $?
    sleep 1
    installer_service_manager is-active || return $?
    if command -v "${SERVICE_APP}_service_health" >/dev/null 2>&1; then
        "${SERVICE_APP}_service_health" || return $?
    fi
    installer_service_alias || return $?
    if [ -n "$SERVICE_OLD" ] && [ "$SERVICE_OLD" != "versions/$SERVICE_VERSION" ]; then
        ln -s "$SERVICE_OLD" "$INSTALLER_PREFIX/.previous.$$" || return 12
        mv -fT "$INSTALLER_PREFIX/.previous.$$" "$INSTALLER_PREFIX/previous" || return 12
    fi
    SERVICE_GOOD=1; SERVICE_CHANGED=0; SERVICE_NEW_VERSION=0
    service_previous=$(readlink "$INSTALLER_PREFIX/previous" 2>/dev/null || true)
    for service_version_dir in "$INSTALLER_PREFIX"/versions/*; do
        [ -d "$service_version_dir" ] && [ ! -L "$service_version_dir" ] || continue
        service_target="versions/${service_version_dir##*/}"
        [ "$service_target" != "versions/$SERVICE_VERSION" ] && [ "$service_target" != "$service_previous" ] || continue
        [ -f "$service_version_dir/.artifact-sha256" ] && [ ! -L "$service_version_dir/.artifact-sha256" ] || continue
        rm -rf "$service_version_dir" || return 12
    done
    status "Installed $SERVICE_APP: $SERVICE_COMMAND (system service; $SERVICE_EXEC)"
}
installer_service_cleanup() {
    if [ "$SERVICE_CHANGED" = 1 ]; then
        printf 'Installer: restoring the previous installation and service.\n' >&2
        installer_service_manager stop || true
        if [ "$SERVICE_HAD_UNIT" = 1 ]; then
            cp -p "$transaction_dir/old-unit" "$SERVICE_UNIT" || return 1
        else
            installer_service_manager disable || return 1
            rm -f "$SERVICE_UNIT" || return 1
        fi
        if [ "$SERVICE_CONFIG_TOUCHED" = 1 ] && [ -n "$SERVICE_CONFIG" ]; then
            if [ "$SERVICE_HAD_CONFIG" = 1 ]; then cp -p "$transaction_dir/old-config" "$SERVICE_CONFIG" || return 1
            else rm -f "$SERVICE_CONFIG" || return 1; fi
        fi
        if [ -n "$SERVICE_OLD" ]; then
            ln -s "$SERVICE_OLD" "$INSTALLER_PREFIX/.restore.$$" || return 1
            mv -fT "$INSTALLER_PREFIX/.restore.$$" "$INSTALLER_PREFIX/current" || return 1
        else rm -f "$INSTALLER_PREFIX/current" || return 1; fi
        installer_service_manager reload || return 1
        if [ "$SERVICE_HAD_UNIT" = 1 ]; then
            if [ "$SERVICE_WAS_ENABLED" = 1 ]; then installer_service_manager enable || return 1
            else installer_service_manager disable || return 1; fi
        fi
        if [ "$SERVICE_WAS_ACTIVE" = 1 ]; then
            installer_service_manager start || return 1
            installer_service_manager is-active || return 1
        fi
        SERVICE_CHANGED=0
    fi
    [ -z "$SERVICE_CANDIDATE" ] || rm -rf "$SERVICE_CANDIDATE" || return 1
    if [ "$SERVICE_NEW_VERSION" = 1 ]; then rm -rf "$SERVICE_VERSION_DIR" || return 1; fi
    rm -f "$INSTALLER_PREFIX/.current.$$" "$INSTALLER_PREFIX/.previous.$$" "$INSTALLER_PREFIX/.restore.$$"
    if [ "$SERVICE_DEST_LOCK_HELD" = 1 ]; then
        rm -f "$INSTALLER_PREFIX/.service-lock/owner" || return 1
        rmdir "$INSTALLER_PREFIX/.service-lock" || return 1
        SERVICE_DEST_LOCK_HELD=0
    fi
}
ddnsto_usage() {
    printf '%s\n' 'Usage: ddnsto-install.sh [--plan] [--action ensure|install|update|status|start|stop|restart|repair|configure|uninstall|download] [--platform auto|linux|openwrt|macos|windows|synology|asus|qnap|unraid] [--method auto|native|docker] [--token TOKEN | --token-file FILE] [--force-version lite|standard] [--verify-status]' \
        '默认 ensure：必须提供 Token，自动安装/升级/启用启动，不降级，不切换账号；仅验证本地稳定运行，不判断设备在线。' \
        '群晖 DSM 7 支持自动安装/升级/启动，需管理员 sudo；其他 NAS/Docker 暂不支持默认自动安装。以下选项用于高级操作。' \
        '华硕软件中心自动识别 rogsoft/armsoft/mtksoft/ipq32soft/ipq64soft/qcasoft；安装后在软件中心管理。' \
        '--plan: read-only local preflight; no downloads, token, or service changes.' \
        'Platform is a constraint, not an override. QNAP/Unraid are unavailable; Windows requires install.ps1.' \
        'Synology: DSM 7 default ensure installs/starts a verified SPK; DS220j / DSM 7.1 tested, ARM64 limited to DS220j. DSM 6 and explicit download/install use manual handoff.' \
        'Docker: explicit selection only; no automatic native/container migration.' \
        'Linux: protected systemd install/update and owned-service lifecycle.' \
        'OpenWrt: package install/update and offline procd lifecycle; update preserves UCI identity and enabled state.' \
        'Shared options precede business options: --installer-prefix PATH --installer-work-dir PATH --installer-scope system.' \
        'Explicit install on OpenWrt: token optional; automatic Lite selection below 900 MB.' \
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
    ACTION=ensure
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
    case "$REQUESTED_PLATFORM" in auto|linux|openwrt|macos|windows|synology|asus|qnap|unraid) ;; *) ddnsto_error 'unknown platform'; return 2 ;; esac
    case "$REQUESTED_METHOD" in auto|native|docker) ;; *) ddnsto_error 'unknown installation method'; return 2 ;; esac
    [ "$REQUESTED_METHOD" = docker ] || [ -z "$DEVICE_NAME$NETWORK" ] || { ddnsto_error 'device-name/network require explicit Docker'; return 2; }
    case "$NETWORK" in ''|bridge|host) ;; *) ddnsto_error 'network must be bridge or host'; return 2 ;; esac
    if [ -n "$OUTPUT_DIR" ]; then
        case "$ACTION" in install|download) ;; *) ddnsto_error 'output-dir only applies to Synology downloads'; return 2 ;; esac
    fi
    case "$FORCE_VERSION" in ''|lite|standard) ;; *) ddnsto_error 'version must be lite or standard'; return 2 ;; esac
    case "$ACTION" in
        ensure|install|update) ;;
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
        token_bytes=$(wc -c < "$TOKEN_FILE") || return 2
        [ "$token_bytes" -le 16384 ] || { ddnsto_error 'token file exceeds 16 KiB'; return 2; }
        TOKEN=$(cat "$TOKEN_FILE"; printf '.')
        TOKEN=${TOKEN%.}
        TOKEN=${TOKEN%"
"}
        [ -n "$TOKEN" ] || { ddnsto_error 'empty token file'; return 2; }
    fi
    case "$TOKEN" in *"
"*|*"$(printf '\r')"*) ddnsto_error 'token must be one line'; return 2 ;; esac
}
ddnsto_appliance_platform() {
    appliance_root=${1:-}
    if [ -f "$appliance_root/etc/synoinfo.conf" ] || [ -d "$appliance_root/usr/syno" ]; then
        printf '%s\n' synology
    elif [ -f "$appliance_root/etc/config/uLinux.conf" ]; then
        printf '%s\n' qnap
    elif [ -f "$appliance_root/etc/unraid-version" ]; then
        printf '%s\n' unraid
    elif [ -x "$appliance_root/bin/nvram" ] && { [ -d "$appliance_root/koolshare" ] || [ -f "$appliance_root/www/Advanced_System_Content.asp" ]; }; then
        printf '%s\n' asus
    fi
}
ddnsto_detect_platform() {
    detected_platform=$(ddnsto_appliance_platform)
    if [ -z "$detected_platform" ]; then
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
        ensure|install|update|download) return 0 ;;
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
    ddnsto_local_platform || return $?
    if [ "$detected_platform" = synology ]; then ddnsto_synology_download; return $?; fi
    if [ "$detected_platform" = asus ]; then
        ddnsto_asus_facts || return $?
        printf '%s\n' 'facts_source=local-preflight' 'platform=asus' "channel=$ASUS_CHANNEL" "arch=$ASUS_ARCH" 'client_version=4.2.8' 'native_status=requires-plugin-preflight' 'installation_performed=false'
        return 0
    fi
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
            [ "${DDNSTO_VERSION:-4.2.8}" = 4.2.8 ] || { ddnsto_error 'no pinned artifact for requested version'; return 2; }
            [ "$FORCE_VERSION" != lite ] && [ "$VERIFY_STATUS" = 0 ] || { ddnsto_error 'OpenWrt options are not supported on Linux'; return 2; }
            native_status=requires-service-preflight
            client_version=${DDNSTO_VERSION:-4.2.8} ;;
        openwrt:*)
            native_status=requires-package-preflight
            client_version=standard-4.2.8-or-lite-4.2.8 ;;
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
ddnsto_managed_native() {
    bootstrap_arch || return 2
    fetch_bootstrap_metadata https '' '' || return 2
    if [ -n "${ZSETUP_BIN:-}" ]; then
        if is_expected_zsetup "$ZSETUP_BIN"; then return 0; fi
    elif find_existing_zsetup; then
        ZSETUP_BIN=$ACTIVE_ZSETUP
        return 0
    fi
    ddnsto_error 'offline management requires the verified pinned zsetup in the installer cache, PATH or ZSETUP_BIN; restore it using the installer before retrying'
    return 2
}
ddnsto_privilege_args() {
    case "${ACTION:-install}" in ensure|install|update) ;; *) return 2 ;; esac
    DDNSTO_ROOT_ACTION=${ACTION:-install}
    DDNSTO_ROOT_TOKEN=$TOKEN
    [ "$DDNSTO_ROOT_ACTION" != update ] || [ -z "$TOKEN" ]
}
ddnsto_managed_rewrite_unit() {
    [ "$SERVICE_HAD_UNIT" = 1 ] || { ddnsto_error 'update requires an owned service'; return 2; }
    installer_service_quote_unit
}
ddnsto_service_health() {
    if [ "${DDNSTO_ENSURE_ACTIVE:-0}" = 1 ]; then
        ddnsto_ensure_linux_running || return 13
    fi
    [ "${version_num:-}" = 4.2.8 ] || return 0
    managed_health_attempt=0
    while [ "$managed_health_attempt" -lt 5 ]; do
        if ddnsto_managed_health_probe; then return 0; fi
        managed_health_attempt=$((managed_health_attempt + 1))
        sleep 1
    done
    ddnsto_error 'local client health failed; rolling back (cloud status unverified)'
    return 13
}
ddnsto_managed_health_probe() (
    managed_info=${SERVICE_CONFIG%/*}/.ddnsto_http_addr.json
    [ -f "$managed_info" ] && [ ! -L "$managed_info" ] || exit 13
    [ "$("$ZSETUP_BIN" storage "$managed_info" get system_protected)" = true ] || exit 13
    installer_file_size "$managed_info" || exit 13
    [ "$INSTALLER_FILE_SIZE" -le 1024 ] || exit 13
    info=$(cat "$managed_info") || exit 13
    case "$info" in '{"addr":"127.0.0.1:'*'","pid":'*',"startedAt":"'*'"}') ;; *) exit 13 ;; esac
    port=${info#*127.0.0.1:}; port=${port%%\"*}
    pid=${info#*\"pid\":}; pid=${pid%%,*}
    case "$port:$pid" in *[!0-9:]*|:*|*:) exit 13 ;; esac
    [ "${#port}" -le 5 ] && [ "$port" -gt 0 ] && [ "$port" -le 65535 ] || exit 13
    [ "${#pid}" -le 10 ] && [ "$pid" -gt 0 ] || exit 13
    [ "$(readlink "/proc/$pid/exe")" = "$SERVICE_EXEC" ] || exit 13
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy
    no_proxy='*'; NO_PROXY='*'; export no_proxy NO_PROXY
    if command -v curl >/dev/null 2>&1; then
        set -- curl -q --noproxy '*' -fsS --connect-timeout 1 --max-time 2 "http://127.0.0.1:$port/healthz"
    elif command -v wget >/dev/null 2>&1; then
        WGETRC=/dev/null; export WGETRC
        set -- wget -q -T 2 -O - "http://127.0.0.1:$port/healthz"
    else exit 13; fi
    installer_exec_native "$ZSETUP_BIN" capture -o "$transaction_dir/client-health" --max-bytes 16 --timeout 3s -- "$@" >/dev/null 2>&1 || exit 13
    [ "$(cat "$transaction_dir/client-health")" = ok ] || exit 13
)
ddnsto_managed_owned() {
    installer_layout ddnsto system || return $?
    [ "$INSTALLER_SCOPE" = system ] || return 2
    SERVICE_APP=ddnsto
    SERVICE_NAME=com.linkease.ddnstoshell.service
    SERVICE_UNIT=/etc/systemd/system/$SERVICE_NAME
    SERVICE_BACKEND=systemd
    SERVICE_CONFIG=/etc/ddnsto/ddnsto-config.json
    for managed_path in "$INSTALLER_PREFIX" "$INSTALLER_PREFIX/.managed" "$SERVICE_UNIT"; do
        [ "$("$ZSETUP_BIN" storage "$managed_path" get system_protected)" = true ] || return 12
    done
    [ -f "$INSTALLER_PREFIX/.managed" ] && [ ! -L "$INSTALLER_PREFIX/.managed" ] || {
        ddnsto_error 'managed installation required; legacy migration is not automatic'; return 2;
    }
    installer_file_size "$INSTALLER_PREFIX/.managed" || return 2
    [ "$INSTALLER_FILE_SIZE" = 7 ] || return 2
    IFS= read -r managed_owner < "$INSTALLER_PREFIX/.managed" || return 2
    [ "$managed_owner" = ddnsto ] || return 2
    if [ "${1:-}" = locked ]; then
        [ "${SERVICE_DEST_LOCK_HELD:-0}" = 1 ] || return 2
        ddnsto_managed_lock_owner "$INSTALLER_PREFIX/.service-lock" || return 2
    else
        [ ! -e "$INSTALLER_PREFIX/.service-lock" ] && [ ! -L "$INSTALLER_PREFIX/.service-lock" ] || {
            ddnsto_error 'active or interrupted service transaction requires recovery'; return 2;
        }
    fi
    installer_service_read_current || return $?
    [ -n "$SERVICE_OLD" ] || return 2
    [ "$SERVICE_HAD_UNIT" = 1 ] || [ "${ACTION:-}" = repair ] || return 2
    ddnsto_managed_receipt "$SERVICE_OLD" || return $?
    SERVICE_EXEC="$INSTALLER_PREFIX/$SERVICE_OLD/bin/ddnsto"
    version_num=${SERVICE_OLD#versions/}
}
ddnsto_service_lock() {
    DDNSTO_GLOBAL_HELD=0; DDNSTO_UNINSTALL_BACKUP=; DDNSTO_UNINSTALL_MOVED=0
    INSTALLER_CLEANUP_HOOK=ddnsto_managed_cleanup
    DDNSTO_GLOBAL_LOCK=/etc/zsetup/install-locks/ddnsto
    [ "$("$ZSETUP_BIN" storage "$DDNSTO_GLOBAL_LOCK" get system_protected)" = true ] || return 12
    umask 022
    mkdir -p /etc/zsetup/install-locks || return 12
    [ "$("$ZSETUP_BIN" storage /etc/zsetup/install-locks get system_protected)" = true ] || return 12
    umask 077
    mkdir "$DDNSTO_GLOBAL_LOCK" 2>/dev/null || {
        ddnsto_error 'active or interrupted machine-wide DDNSTO transaction requires recovery'; return 2;
    }
    DDNSTO_GLOBAL_HELD=1
    printf '%s\n' "$$" > "$DDNSTO_GLOBAL_LOCK/owner" || return 12
    [ ! -e /etc/ddnsto-docker ] && [ ! -L /etc/ddnsto-docker ] || {
        ddnsto_error 'Docker state conflicts with native installation'; return 2;
    }
    if [ -n "${SERVICE_OLD:-}" ]; then
        ddnsto_managed_owned || return $?
        ddnsto_managed_effective || {
            ddnsto_error 'effective systemd service is not exclusively owned'; return 2;
        }
    fi
    if command -v ddnsto_ensure_linux_locked >/dev/null 2>&1; then
        ddnsto_ensure_linux_locked || return $?
    fi
}
ddnsto_managed_lock_owner() {
    [ -d "$1" ] && [ ! -L "$1" ] || return 2
    [ "$("$ZSETUP_BIN" storage "$1/owner" get system_protected)" = true ] || return 12
    installer_file_size "$1/owner" || return 2
    [ "$INSTALLER_FILE_SIZE" -le 16 ] || return 2
    [ "$(cat "$1/owner")" = "$$" ]
}
ddnsto_managed_receipt() (
    case "$1" in versions/*) ;; *) exit 2 ;; esac
    v=${1#versions/}; installer_service_version "$v" || exit 2
    dir="$INSTALLER_PREFIX/$1"
    for f in "$dir" "$dir/bin" "$dir/.files" "$dir/.arch" "$dir/.artifact-sha256" "$dir/bin/ddnsto" "$dir/bin/.service-run"; do
        [ "$("$ZSETUP_BIN" storage "$f" get system_protected)" = true ] || exit 12
        [ ! -L "$f" ] || exit 2
    done
    [ -d "$dir" ] && [ -d "$dir/bin" ] || exit 2
    for f in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        case "${f##*/}" in bin|.files|.arch|.artifact-sha256) ;; *) exit 2 ;; esac
    done
    for f in "$dir/bin"/* "$dir/bin"/.[!.]* "$dir/bin"/..?*; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        case "${f##*/}" in ddnsto|.service-run) ;; *) exit 2 ;; esac
    done
    for f in .files .arch .artifact-sha256; do
        installer_file_size "$dir/$f" || exit 2
        [ "$INSTALLER_FILE_SIZE" -le 160 ] || exit 2
    done
    [ "$(cat "$dir/.files")" = "$(printf '.service-run\nddnsto')" ] || exit 2
    case "$(cat "$dir/.arch")" in x86_64|aarch64|armv7) ;; *) exit 2 ;; esac
    sha=$(cat "$dir/.artifact-sha256")
    [ "${#sha}" = 64 ] || exit 2
    case "$sha" in *[!a-f0-9]*) exit 2 ;; esac
    for f in ddnsto .service-run; do
        installer_file_size "$dir/bin/$f" || exit 2
        [ "$INSTALLER_FILE_SIZE" -gt 0 ] && [ "$INSTALLER_FILE_SIZE" -le 67108864 ] && [ -x "$dir/bin/$f" ] || exit 2
    done
    installer_file_size "$dir/bin/.service-run" || exit 2
    [ "$INSTALLER_FILE_SIZE" -le 4096 ] || exit 2
    installer_service_replace "$dir/bin/ddnsto" "'" "'\\''"
    [ "$(cat "$dir/bin/.service-run")" = "$(printf '#!/bin/sh\nexec '\''%s'\'' run\n' "$service_replaced")" ] || exit 2
)
ddnsto_managed_property() {
    installer_exec_native "$ZSETUP_BIN" run -- systemctl show "--property=$1" --value "$SERVICE_NAME"
}
ddnsto_managed_effective() {
    managed_fragment=$(ddnsto_managed_property FragmentPath) || return 2
    managed_load=$(ddnsto_managed_property LoadState) || return 2
    managed_reload=$(ddnsto_managed_property NeedDaemonReload) || return 2
    [ "$managed_reload" = no ] || return 2
    for managed_property in DropInPaths ExecCondition ExecStartPre ExecStartPost ExecStop ExecStopPost ExecReload RootDirectory RootImage Environment User Group WorkingDirectory BindPaths BindReadOnlyPaths; do
        managed_value=$(ddnsto_managed_property "$managed_property") || return 2
        [ -z "$managed_value" ] || return 2
    done
    managed_env=$(ddnsto_managed_property EnvironmentFiles) || return 2
    if [ -n "$managed_env" ]; then
        managed_optional=/etc/sysconfig/com.linkease.ddnstoshell
        [ "$managed_env" = "$managed_optional (ignore_errors=yes)" ] || return 2
        [ "$("$ZSETUP_BIN" storage "$managed_optional" get system_protected)" = true ] || return 12
        [ ! -e "$managed_optional" ] && [ ! -L "$managed_optional" ] || return 2
    fi
    managed_exec=$(ddnsto_managed_property ExecStart) || return 2
    if [ "$SERVICE_HAD_UNIT" = 0 ]; then
        [ "$ACTION" = repair ] && [ "$managed_load" = not-found ] && [ -z "$managed_fragment" ] && [ -z "$managed_exec" ] || return 2
        [ ! -e "$SERVICE_UNIT" ] && [ ! -L "$SERVICE_UNIT" ] || return 2
    else
        [ "$managed_load" = loaded ] && [ "$managed_fragment" = "$SERVICE_UNIT" ] || return 2
        case "$managed_exec" in
            "{ path=/bin/sh ; argv[]=/bin/sh ${SERVICE_EXEC%/*}/.service-run ; ignore_errors=no ; "*' }') ;;
            *) return 2 ;;
        esac
        [ -z "${managed_exec#*\}}" ] || return 2
    fi
    managed_state=$(ddnsto_managed_property ActiveState) || return 2
    case "$managed_state" in active) [ "$SERVICE_HAD_UNIT" = 1 ] || return 2 ;; inactive|failed) ;; *) return 2 ;; esac
    managed_enabled=$(ddnsto_managed_property UnitFileState) || return 2
    case "$managed_enabled" in enabled|disabled) ;; '') [ "$SERVICE_HAD_UNIT" = 0 ] || return 2 ;; *) return 2 ;; esac
}
ddnsto_managed_cleanup() {
    if [ "$SERVICE_CHANGED" = 1 ]; then
        installer_service_manager stop || return 1
        managed_stopped=$(ddnsto_managed_property ActiveState) || return 1
        case "$managed_stopped" in inactive|failed) ;; *) return 1 ;; esac
    fi
    if [ "${DDNSTO_UNINSTALL_MOVED:-0}" = 1 ]; then
        for managed_entry in versions current previous .managed; do
            if [ -e "$DDNSTO_UNINSTALL_BACKUP/$managed_entry" ] || [ -L "$DDNSTO_UNINSTALL_BACKUP/$managed_entry" ]; then
                [ ! -e "$INSTALLER_PREFIX/$managed_entry" ] && [ ! -L "$INSTALLER_PREFIX/$managed_entry" ] || return 1
                mv "$DDNSTO_UNINSTALL_BACKUP/$managed_entry" "$INSTALLER_PREFIX/$managed_entry" || return 1
            fi
        done
        DDNSTO_UNINSTALL_MOVED=0
    fi
    installer_service_cleanup || return 1
    if [ "${DDNSTO_GLOBAL_HELD:-0}" = 1 ]; then
        ddnsto_managed_lock_owner "$DDNSTO_GLOBAL_LOCK" || return 1
        rm -f "$DDNSTO_GLOBAL_LOCK/owner" || return 1
        rmdir "$DDNSTO_GLOBAL_LOCK" || return 1
        DDNSTO_GLOBAL_HELD=0
    fi
}
ddnsto_managed_uninstall_inventory() {
    for managed_entry in "$INSTALLER_PREFIX"/* "$INSTALLER_PREFIX"/.[!.]* "$INSTALLER_PREFIX"/..?*; do
        [ -e "$managed_entry" ] || [ -L "$managed_entry" ] || continue
        case "${managed_entry##*/}" in versions|current|previous|.managed|.staging|.service-lock) ;; *) return 2 ;; esac
    done
    [ -d "$INSTALLER_PREFIX/versions" ] && [ ! -L "$INSTALLER_PREFIX/versions" ] || return 2
    for managed_entry in "$INSTALLER_PREFIX/versions"/* "$INSTALLER_PREFIX/versions"/.[!.]* "$INSTALLER_PREFIX/versions"/..?*; do
        [ -e "$managed_entry" ] || [ -L "$managed_entry" ] || continue
        ddnsto_managed_receipt "versions/${managed_entry##*/}" || return 2
    done
    if [ -e "$INSTALLER_PREFIX/previous" ] || [ -L "$INSTALLER_PREFIX/previous" ]; then
        [ -L "$INSTALLER_PREFIX/previous" ] || return 2
        ddnsto_managed_receipt "$(readlink "$INSTALLER_PREFIX/previous")" || return 2
    fi
}
ddnsto_managed_write() (
    SERVICE_CHANGED=0; SERVICE_NEW_VERSION=0; SERVICE_CANDIDATE=; SERVICE_GOOD=0
    SERVICE_DEST_LOCK_HELD=0; SERVICE_CONFIG_TOUCHED=0; SERVICE_HAD_CONFIG=0
    SERVICE_WAS_ACTIVE=0; SERVICE_WAS_ENABLED=0; DDNSTO_GLOBAL_HELD=0
    INSTALLER_CLEANUP_HOOK=
    [ "$("$ZSETUP_BIN" storage / get effective_uid)" = 0 ] || {
        ddnsto_error 'local writes require a root shell: run sudo -i, then rerun the installer in that shell'; exit 2;
    }
    ddnsto_managed_owned || exit $?
    INSTALLER_WORK_ROOT="$INSTALLER_PREFIX/.staging"
    INSTALLER_RESERVE=8388608
    [ "$("$ZSETUP_BIN" storage "$INSTALLER_WORK_ROOT" get system_protected)" = true ] || exit 12
    installer_transaction_begin || exit $?
    INSTALLER_CLEANUP_HOOK=ddnsto_managed_cleanup
    ddnsto_service_lock || exit $?
    mkdir "$INSTALLER_PREFIX/.service-lock" 2>/dev/null || exit 2
    SERVICE_DEST_LOCK_HELD=1
    printf '%s\n' "$$" > "$INSTALLER_PREFIX/.service-lock/owner" || exit 12
    ddnsto_managed_owned locked || exit $?
    ddnsto_managed_effective || { ddnsto_error 'effective systemd service is not exclusively owned'; exit 2; }
    [ "$managed_state" != active ] || SERVICE_WAS_ACTIVE=1
    [ "$managed_enabled" != enabled ] || SERVICE_WAS_ENABLED=1
    [ "$SERVICE_HAD_UNIT" != 1 ] || cp -p "$SERVICE_UNIT" "$transaction_dir/old-unit" || exit 12
    [ "$("$ZSETUP_BIN" storage "$SERVICE_CONFIG" get system_protected)" = true ] || exit 12
    installer_file_size "$SERVICE_CONFIG" || exit 2
    [ "$INSTALLER_FILE_SIZE" -le 16384 ] || exit 11
    cp -p "$SERVICE_CONFIG" "$transaction_dir/old-config" || exit 12
    SERVICE_HAD_CONFIG=1
    if [ "$ACTION" = configure ]; then
        [ -n "${TOKEN:-}" ] && command -v jq >/dev/null 2>&1 || { ddnsto_error 'configure requires a nonempty Token and jq'; exit 2; }
        installer_exec_native "$ZSETUP_BIN" capture -o "$transaction_dir/new-config" --max-bytes 16384 --min-free-bytes "$INSTALLER_RESERVE" -- jq -e -s --arg token "$TOKEN" 'if length == 1 and (.[0] | type == "object" and (.token | type == "string")) then .[0] | .token = $token else error("unsupported configuration") end' "$SERVICE_CONFIG" >/dev/null 2>&1 || { ddnsto_error 'configuration must contain one JSON object with a token string'; exit 2; }
        chmod 0600 "$transaction_dir/new-config" || exit 12
    fi
    if [ "$ACTION" = uninstall ]; then
        ddnsto_managed_uninstall_inventory || { ddnsto_error 'unknown uninstall inventory; no changes made'; exit 2; }
        DDNSTO_UNINSTALL_BACKUP=$(mktemp -d "$INSTALLER_PREFIX/.uninstalled.XXXXXX") || exit 12
        cp -p "$transaction_dir/old-unit" "$DDNSTO_UNINSTALL_BACKUP/unit" || exit 12
        cp -p "$transaction_dir/old-config" "$DDNSTO_UNINSTALL_BACKUP/config" || exit 12
        printf 'active=%s\nenabled=%s\n' "$SERVICE_WAS_ACTIVE" "$SERVICE_WAS_ENABLED" > "$DDNSTO_UNINSTALL_BACKUP/state" || exit 12
    fi
    ddnsto_managed_effective || exit 2
    SERVICE_CHANGED=1
    SERVICE_CONFIG_TOUCHED=1
    if [ "$SERVICE_HAD_UNIT" = 1 ] && [ "$ACTION" != start ]; then
        installer_service_manager stop || exit $?
        managed_stopped=$(ddnsto_managed_property ActiveState) || exit 2
        case "$managed_stopped" in inactive|failed) ;; *) exit 13 ;; esac
    fi
    case "$ACTION" in
        stop) installer_service_manager disable || exit $? ;;
        uninstall)
            installer_service_manager disable || exit $?
            rm -f "$SERVICE_UNIT" || exit 12
            installer_service_manager reload || exit $?
            [ "$(ddnsto_managed_property LoadState)" = not-found ] || exit 13
            [ -z "$(ddnsto_managed_property FragmentPath)" ] || exit 13
            DDNSTO_UNINSTALL_MOVED=1
            for managed_entry in versions current previous .managed; do
                [ -e "$INSTALLER_PREFIX/$managed_entry" ] || [ -L "$INSTALLER_PREFIX/$managed_entry" ] || continue
                mv "$INSTALLER_PREFIX/$managed_entry" "$DDNSTO_UNINSTALL_BACKUP/$managed_entry" || exit 12
            done
            cp -p "$transaction_dir/old-config" "$SERVICE_CONFIG" || exit 12
            ;;
        *)
            if [ "$ACTION" = configure ]; then
                installer_exec_native "$ZSETUP_BIN" capture -o "$SERVICE_CONFIG" --max-bytes 16384 --min-free-bytes "$INSTALLER_RESERVE" -- cat "$transaction_dir/new-config" || exit $?
                chmod 0600 "$SERVICE_CONFIG" || exit 12
            fi
            if [ "$SERVICE_HAD_UNIT" = 0 ]; then
                installer_service_escape_exec "${SERVICE_EXEC%/*}/.service-run"
                printf '[Unit]\nDescription=DdnstoShell Service\nAfter=network.target\n[Service]\nType=simple\nExecStart=/bin/sh "%s"\nRestart=always\nRestartSec=5\nLimitNOFILE=1048576\n[Install]\nWantedBy=multi-user.target\n' "$service_escaped" > "$transaction_dir/new-unit" || exit 12
                installer_exec_native "$ZSETUP_BIN" capture -o "$SERVICE_UNIT" --max-bytes 16384 --min-free-bytes "$INSTALLER_RESERVE" -- cat "$transaction_dir/new-unit" || exit $?
                chmod 0644 "$SERVICE_UNIT" || exit 12
                installer_service_manager reload || exit $?
            fi
            installer_service_manager enable || exit $?
            installer_service_manager start || exit $?
            installer_service_manager is-active || exit $?
            ddnsto_service_health || exit $?
            ;;
    esac
    SERVICE_CHANGED=0; SERVICE_GOOD=1; DDNSTO_UNINSTALL_MOVED=0
    installer_transaction_finish || exit $?
    printf 'operation=%s cloud_status=unverified\n' "$ACTION"
    [ "$ACTION" != uninstall ] || printf 'config=retained backup=%s user_aliases=retained\n' "$DDNSTO_UNINSTALL_BACKUP"
)
ddnsto_managed_action() {
    [ "$detected_platform" = linux ] || { ddnsto_error 'protected OpenWrt local lifecycle is not yet ported'; return 2; }
    case "$ACTION" in
        status) ;;
        start|stop|restart|repair|configure|uninstall) ddnsto_managed_write; return $? ;;
        *) return 2 ;;
    esac
    installer_layout ddnsto system || return $?
    [ "$INSTALLER_SCOPE" = system ] || return 2
    if [ ! -e "$INSTALLER_PREFIX" ] && [ ! -L "$INSTALLER_PREFIX" ]; then
        printf '%s\n' 'local_service=not-installed cloud_status=unverified'
        return 0
    fi
    ddnsto_managed_owned || return $?
    ddnsto_managed_effective || return $?
    case "$managed_state" in active) managed_state=running ;; inactive) managed_state=stopped ;; failed|activating|deactivating|reloading) ;; *) return 2 ;; esac
    printf 'local_service=%s cloud_status=unverified\n' "$managed_state"
}
ddnsto_error() { printf 'DDNSTO: %s\n' "$*" >&2; }
ddnsto_download() { installer_download "$@"; }
ddnsto_verified_download() {
    verified_relative=$1
    verified_output=$2
    verified_sha=$3
    verified_marker="$verified_output.verified"
    installer_package_immutable "$verified_marker" "$verified_sha" || return $?
    ddnsto_download "$verified_relative" "$verified_output" "$verified_sha" || return $?
    verified_size=$(wc -c < "$verified_output" | tr -d '[:space:]')
    printf '%s:%s\n' "$verified_sha" "$verified_size" > "$transaction_dir/verified"
    mv -f "$transaction_dir/verified" "$verified_marker"
}
ddnsto_checksum() {
    "$ZSETUP_BIN" metadata sha256 "$1" "$2" || {
        ddnsto_error "invalid, missing or duplicate SHA256 for $2"; return 11;
    }
}
ddnsto_package_restore() {
    if [ "${deprecated_config:-0}" = 1 ] && [ -f "$transaction_dir/deprecated-config" ]; then
        [ "$("$ZSETUP_BIN" storage "$config_path" get system_protected)" = true ] || return 1
        installer_exec_native "$ZSETUP_BIN" run -- cp -p "$transaction_dir/deprecated-config" "$config_path" || return 1
    fi
}
ddnsto_register() {
    if [ "${ACTION:-install}" = update ]; then
        SERVICE_CONFIG_TOUCHED=0
        ddnsto_managed_rewrite_unit
        return $?
    fi
    if [ "$SERVICE_HAD_UNIT" = 1 ]; then
        ddnsto_error 'already installed; use update to preserve identity or configure to change Token'
        return 2
    fi
    installer_exec_native "$ZSETUP_BIN" run -- "$SERVICE_EXEC" -u "$TOKEN" -daemon
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
    version_num=$(ddnsto_pinned_version "$SELECTED_VERSION") || return $?
    version_folder=$SELECTED_VERSION
    [ "$pkg_ext" != apk ] || version_folder="$version_folder-apk"
    relative_folder="openwrt/$version_folder/$version_num"
    status "      DDNSTO $version_num ($SELECTED_VERSION; Lite below 900 MB)"
    status '[3/4] Downloading and verifying DDNSTO packages...'
    installer_package_cache "$version_num-$version_folder" "$arch" || return $?
    package_cache=$PACKAGE_CACHE
    main_package="ddnsto_$package_arch.$pkg_ext"
    ui_package="luci-app-ddnsto.$pkg_ext"
    language_package="luci-i18n-ddnsto-zh-cn.$pkg_ext"
    for package in "$main_package" "$ui_package" "$language_package"; do
        case "$package" in ddnsto_*) product_path="$relative_folder/$package" ;; *) product_path="openwrt/$package" ;; esac
        digest=$(ddnsto_pinned_sha "$product_path") || return $?
        ddnsto_verified_download "$product_path" "$package_cache/$package" "$digest" || return $?
    done
    status '[4/4] Installing DDNSTO packages...'
    ddnsto_openwrt_apply
}
ddnsto_openwrt_apply_packages() {
    if [ "$package_manager" = opkg ]; then
        if [ -f /www/luci-static/resources/luci.js ] && [ ! -f /usr/lib/lua/luci/cbi.lua ]; then
            installer_package_command update update && installer_package_command install install luci-compat || status 'DDNSTO: luci-compat installation failed'
        fi
        ddnsto_has_runtime=0
        if installer_package_command query "$transaction_dir/pm-query" list-installed luci-lua-runtime; then
            while IFS= read -r ddnsto_query_line; do
                case "$ddnsto_query_line" in 'luci-lua-runtime '*) ddnsto_has_runtime=1 ;; esac
            done < "$transaction_dir/pm-query"
        fi
        if [ "$ddnsto_has_runtime" = 0 ]; then
            installer_package_command update update && installer_package_command install install luci-lua-runtime || status 'DDNSTO: luci-lua-runtime installation failed'
        fi
        for package in "$main_package" "$ui_package" "$language_package"; do installer_package_command install install --force-reinstall "$package_cache/$package" || return $?; done
    else
        if [ -f /www/luci-static/resources/luci.js ] && [ ! -f /usr/lib/lua/luci/cbi.lua ]; then
            installer_package_command update update && installer_package_command add add luci-compat || status 'DDNSTO: luci-compat installation failed'
        fi
        if ! installer_package_command query "$transaction_dir/pm-query" info -e luci-lua-runtime >/dev/null 2>&1; then
            installer_package_command update update && installer_package_command add add luci-lua-runtime || status 'DDNSTO: luci-lua-runtime installation failed'
        fi
        for package in "$main_package" "$ui_package" "$language_package"; do installer_package_command add add --allow-untrusted "$package_cache/$package" || return $?; done
    fi
    installer_exec_native "$ZSETUP_BIN" run -- "${DDNSTO_OPENWRT_BIN_PATH:-/usr/sbin/ddnstod}" -v || return $?
}
ddnsto_linux_metadata() {
    case "$arch" in x86_64|aarch64) ;; *) ddnsto_error "unsupported Linux architecture: $arch"; return 2 ;; esac
    [ "$FORCE_VERSION" != lite ] || { ddnsto_error 'Linux only supports standard'; return 2; }
    [ "$VERIFY_STATUS" = 0 ] || { ddnsto_error '--verify-status is for OpenWrt'; return 2; }
    if [ -z "$TOKEN" ] && [ "${ACTION:-install}" != update ]; then
        if [ -t 0 ]; then
            printf 'DDNSTO token: ' >&2
            IFS= read -r TOKEN
        else
            ddnsto_error 'Linux needs --token TOKEN for noninteractive installation'; return 2
        fi
    fi
    [ -n "$TOKEN" ] || [ "${ACTION:-install}" = update ] || { ddnsto_error 'empty token'; return 2; }
    version_num=${DDNSTO_VERSION:-4.2.8}
    case "$version_num" in ''|*[!0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._+-]*) ddnsto_error 'invalid DDNSTO_VERSION'; return 2 ;; esac
    status "[2/4] Checking DDNSTO standard $version_num ($arch)..."
    archive_name="ddnsto-standard-$version_num.tar.gz"
    if [ "$version_num" = 4.2.8 ]; then
        digest=$(ddnsto_pinned_sha "linux-binary/$archive_name") || return $?
        return 0
    fi
    ddnsto_download linux-binary/SHA256SUMS "$transaction_dir/sums" '' 1 || return $?
    digest=$(ddnsto_checksum "$transaction_dir/sums" "$archive_name") || return $?
}
ddnsto_linux() {
    ddnsto_linux_metadata || return $?
    installer_service_cached "$version_num" "$digest" || return $?
    if [ "$SERVICE_CACHED" = 0 ]; then
        archive_path="$transaction_dir/product.tar.gz"
        status '[3/4] Downloading DDNSTO with bounded staging...'
        ddnsto_download "linux-binary/$archive_name" "$archive_path" "$digest" || return $?
        mkdir -p "$transaction_dir/products"
        installer_extract_member "$transaction_dir/products/ddnsto" tar -xOzf "$archive_path" "ddnsto-standard-$version_num/ddnsto.$arch" || return $?
        chmod 0755 "$transaction_dir/products/ddnsto"
        installer_exec_native "$ZSETUP_BIN" run -- "$transaction_dir/products/ddnsto" -v || return $?
        installer_service_stage || return $?
        installer_service_copy ddnsto || return $?
        installer_service_commit_version || return $?
    else
        installer_exec_native "$ZSETUP_BIN" run -- "$SERVICE_EXEC" -v || return $?
    fi
    status '[4/4] Installing and checking the DDNSTO system service...'
    installer_service_activate || return $?
    status 'DDNSTO installation completed'
}
ddnsto_install() {
    ddnsto_parse_args "$@" || return $?
    if [ "$PLAN_ONLY" = 1 ]; then ddnsto_plan; return $?; fi
    : "${ZSETUP_BIN:?zsetup is required}"
    os=${ZSETUP_OS:-$("$ZSETUP_BIN" context get os)}
    package_manager=${ZSETUP_PACKAGE_MANAGER:-$("$ZSETUP_BIN" context get package_manager)}
    arch=${ZSETUP_ARCH:-$("$ZSETUP_BIN" context get arch)}
    ddnsto_detect_platform || return $?
    ddnsto_validate_platform_options || return $?
    [ "$REQUESTED_METHOD" != docker ] || { ddnsto_error 'Docker requires the public entry'; return 2; }
    case "$detected_platform" in linux|openwrt) business_platform=$detected_platform ;; *) ddnsto_error 'native installation unavailable for this device'; return 2 ;; esac
    case "$ACTION" in
        status|start|stop|restart|repair|configure|uninstall) ddnsto_managed_action; return $? ;;
    esac
    : "${ZSETUP_SOURCE_BASES:?source group is required}"
    INSTALLER_REMOTE_APP=ddnsto
    if [ "$ACTION" = ensure ]; then
        ddnsto_ensure_preflight || return $?
        DDNSTO_ENSURE_ACTIVE=1
        ENSURE_TOKEN=$TOKEN
        ip_uid=$("$ZSETUP_BIN" storage / get effective_uid) || return 12
        if [ "$ip_uid" != 0 ]; then
            if [ "$business_platform" = linux ]; then
                ddnsto_ensure_authorize || return $?
                installer_privilege_install ddnsto "$@" || return $?
                ddnsto_flow_note installed
                ddnsto_flow_note started
                return 0
            fi
            ddnsto_flow_error E_PERMISSION '管理路由器服务需要 root 权限' '请以 root 登录设备后粘贴同一条命令'; return 2
        fi
        if [ "$business_platform" = linux ]; then ddnsto_ensure_linux
        else ddnsto_ensure_openwrt; fi
        return $?
    fi
    if [ "$business_platform" = linux ]; then
        [ -z "${DDNSTO_BIN_PATH:-}" ] || { ddnsto_error 'DDNSTO_BIN_PATH is retired; use --installer-prefix for the protected installation root'; return 2; }
        [ ! -e "${DDNSTO_DOCKER_STATE_DIR:-/etc/ddnsto-docker}" ] && [ ! -L "${DDNSTO_DOCKER_STATE_DIR:-/etc/ddnsto-docker}" ] || { ddnsto_error 'Docker state conflicts with native installation'; return 2; }
        if [ "$ACTION" = update ]; then ddnsto_managed_owned || return $?; fi
        ip_uid=$("$ZSETUP_BIN" storage / get effective_uid) || return 12
        if [ "$ip_uid" != 0 ]; then installer_privilege_install ddnsto "$@"; return $?; fi
        installer_service_prepare ddnsto || return $?
        if [ "$ACTION" = install ] && { [ -n "$SERVICE_OLD" ] || [ "$SERVICE_HAD_UNIT" = 1 ]; }; then
            ddnsto_error 'already installed; use update to preserve identity or configure to change Token'
            return 2
        fi
        if [ "$ACTION" = update ]; then
            [ -n "$SERVICE_OLD" ] && [ "$SERVICE_HAD_UNIT" = 1 ] && [ "$SERVICE_HAD_CONFIG" = 1 ] || { ddnsto_error 'update requires a complete managed installation'; return 2; }
        fi
        ddnsto_linux || return $?
        installer_transaction_finish
        return $?
    fi
    case "$ACTION" in install|update) ;; *) return 2 ;; esac
    ddnsto_openwrt_preflight || return $?
    installer_package_prepare ddnsto || return $?
    ddnsto_openwrt_preflight || return $?
    INSTALLER_PACKAGE_CLEANUP=ddnsto_package_restore
    ddnsto_openwrt || return $?
    PACKAGE_PHASE=complete
    installer_transaction_finish
}
ddnsto_pinned_version() {
    case "$1" in
        standard|lite) printf '%s\n' 4.2.8 ;;
        *) printf '%s\n' 'DDNSTO: unknown pinned variant' >&2; return 11 ;;
    esac
}
ddnsto_pinned_sha() {
    case "$1" in
        linux-binary/ddnsto-standard-4.2.8.tar.gz) printf '%s\n' 3bf7ada14448b5aa04afa171e497f85d0b8bb4adcf2209991e52ef5826d4e975 ;;
        openwrt/lite-apk/4.2.8/ddnsto_aarch64.apk) printf '%s\n' aaf16937cad6373849ad1d1f15d64b9a085a55d4f44778c2458997fb2af0b65d ;;
        openwrt/lite-apk/4.2.8/ddnsto_arm.apk) printf '%s\n' 2834dfe9fe683d6dfffed8b73a71a7d84867789fbd8537fe3e21f8ea7e4e8c6b ;;
        openwrt/lite-apk/4.2.8/ddnsto_mipsel.apk) printf '%s\n' 91cfe44983494d3efea407fe5bd4ee5c76e227e821cd5729684ef92f46d3043e ;;
        openwrt/lite-apk/4.2.8/ddnsto_x86_64.apk) printf '%s\n' b725dab7fd7387527c03015f37cfa1e5424e13d550cc0d2fba3a7067627cef96 ;;
        openwrt/lite/4.2.8/ddnsto_aarch64.ipk) printf '%s\n' f400d53e82b4ad83da42e05b8561e3a92afbaca21f228fb994d2a5ed659474a7 ;;
        openwrt/lite/4.2.8/ddnsto_arm.ipk) printf '%s\n' c9ab02d44f753eb1129570687ec1fd31246f654444fc77dc219a7dd91fb7417e ;;
        openwrt/lite/4.2.8/ddnsto_mipsel.ipk) printf '%s\n' 3e331d2f59f891f33b2f3c00a8cecd429a266c5a52810966f78051aef267c1fb ;;
        openwrt/lite/4.2.8/ddnsto_x86_64.ipk) printf '%s\n' ed4bd946f54840a61312e4121cc6887e874baea00506711c2ce3e69f4f8411ac ;;
        openwrt/luci-app-ddnsto.apk) printf '%s\n' edd733e46d476b688da2dc046f6d87eee5365c72b1be34c82c6b9f5ef4b87a18 ;;
        openwrt/luci-app-ddnsto.ipk) printf '%s\n' 702828cdfc1cf2e33dc1b2894ec69a49f1739dfd3ece8948da0d093c6348d123 ;;
        openwrt/luci-i18n-ddnsto-zh-cn.apk) printf '%s\n' dbb3b6d2176f1c223e82ca46e6be4fda50ff30f449c9302be3382eb6162d8e2d ;;
        openwrt/luci-i18n-ddnsto-zh-cn.ipk) printf '%s\n' fff0850c893a75eb597d9e60cada9350caf5bc22219628a8c212f79f82e90679 ;;
        openwrt/standard-apk/4.2.8/ddnsto_aarch64.apk) printf '%s\n' 67e3e784a38a05aa8d3c8693caa8fd20d8316ca950268b956f688df6a1f11d8f ;;
        openwrt/standard-apk/4.2.8/ddnsto_arm.apk) printf '%s\n' 4d5c656af9560ba2a039f7305968ad086788204dcc678e8bc6bbbe345a481bf9 ;;
        openwrt/standard-apk/4.2.8/ddnsto_mipsel.apk) printf '%s\n' 8ef767b45b7546e2b4e979ac0fc426d663e34988c816e465a6c0b8b54a62d9b8 ;;
        openwrt/standard-apk/4.2.8/ddnsto_x86_64.apk) printf '%s\n' 6740fea1fbc6f58de41d5024af0d4c6d523599947c50b70889c15646f0a482c0 ;;
        openwrt/standard/4.2.8/ddnsto_aarch64.ipk) printf '%s\n' 5f291b4c28daefe4298f33d8dae9860945091bdb4af357d58b1c4553e41828cf ;;
        openwrt/standard/4.2.8/ddnsto_arm.ipk) printf '%s\n' acc8df1f81049cde0695357347aeeeecec1f99046e5e91fed1cfdde5cbedc3c6 ;;
        openwrt/standard/4.2.8/ddnsto_mipsel.ipk) printf '%s\n' 0afd87b8a17db1616b73e64625badd7eae714cf1bcdb963cc46038b8288a0553 ;;
        openwrt/standard/4.2.8/ddnsto_x86_64.ipk) printf '%s\n' d2965019064df274cea7a04433aabeb767a4b49502f724d61aa26adf641eda63 ;;
        *) printf '%s\n' "DDNSTO: no pinned artifact for $1; use a reviewed newer installer" >&2; return 11 ;;
    esac
}
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
    unset DOCKER_CONTEXT
    engine=$(timeout 5 docker --host "$endpoint" info --format '{{.OSType}}|{{.Architecture}}|{{.OperatingSystem}}' 2>/dev/null) || { echo engine-unreachable; return; }
    case "$engine" in
        *'Docker Desktop'*) echo desktop-engine-unverified ;;
        linux\|*\|*) echo local-linux-engine ;;
        *) echo unsupported-engine ;;
    esac
)
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
    ddnsto_docker_fresh_inputs || exit $?
    ddnsto_docker_cli pull --platform linux/amd64 "$ddocker_image" >/dev/null 2>&1 || { ddnsto_docker_error 'pinned image pull failed'; exit 11; }
    ddocker_image_id=$(ddnsto_docker_cli image inspect --format '{{.Id}}' "$ddocker_image" 2>/dev/null) || exit 11
    case "$ddocker_image_id" in sha256:*) ;; *) exit 11 ;; esac
    [ "${#ddocker_image_id}" = 71 ] || exit 11
    case "${ddocker_image_id#sha256:}" in *[!a-f0-9]*) exit 11 ;; esac
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
ddnsto_synology_select() {
    synology_error() { printf 'DDNSTO: %s\n' "$1" >&2; }
    version_file=${DDNSTO_DSM_VERSION_FILE:-/etc.defaults/VERSION}
    [ -f "$version_file" ] && [ -r "$version_file" ] || {
        synology_error 'cannot read DSM VERSION'; return 2;
    }
    [ "$(grep -c '^[[:space:]]*majorversion[[:space:]]*=' "$version_file")" = 1 ] &&
        [ "$(grep -c '^[[:space:]]*buildnumber[[:space:]]*=' "$version_file")" = 1 ] || {
        synology_error 'DSM VERSION requires exactly one majorversion and buildnumber'; return 2;
    }
    major=$(sed -n '/^[[:space:]]*majorversion[[:space:]]*=/ {
        s/^[[:space:]]*majorversion[[:space:]]*=[[:space:]]*//
        s/[[:space:]]*$//
        s/^"\(.*\)"$/\1/
        p
    }' "$version_file") || return 2
    build=$(sed -n '/^[[:space:]]*buildnumber[[:space:]]*=/ {
        s/^[[:space:]]*buildnumber[[:space:]]*=[[:space:]]*//
        s/[[:space:]]*$//
        s/^"\(.*\)"$/\1/
        p
    }' "$version_file") || return 2
    case "$major" in 6|7) ;; *) synology_error 'unsupported or ambiguous DSM major version'; return 2 ;; esac
    case "$build" in ''|*[!0-9]*) synology_error 'invalid or ambiguous DSM build number'; return 2 ;; esac
    [ "${#build}" -le 9 ] || { synology_error 'invalid DSM build number'; return 2; }
    case "$major" in 6) minimum=5940 ;; 7) minimum=41890 ;; esac
    [ "$build" -ge "$minimum" ] || { synology_error 'DSM build is below the supported minimum'; return 2; }
    arch=$(uname -m) || return 2
    case "$arch" in
        x86_64) family=x86 ;;
        armv7|armv7l) family=arm ;;
        aarch64)
            model=$(cat "${DDNSTO_DSM_MODEL_FILE:-/proc/sys/kernel/syno_hw_version}" 2>/dev/null) || return 2
            [ "$major:$model" = 7:DS220j ] || { synology_error 'ARM64 model compatibility is unverified'; return 2; }
            family=arm ;;
        *) synology_error 'Synology SPK supports only x86_64 and armv7'; return 2 ;;
    esac
    case "$family:$major" in
        arm:6) digest=b83750595c95db591be99eb06749a7a657597426d13e4b699bce4c0ad16c3e60 ;;
        arm:7) digest=7286134081b518e5e339b60be7f51bc270979cbd4708998121f61e1d08470ad9 ;;
        x86:6) digest=9f3409198a7794212931e044c095a3133489c1241320f2fb45acea0c08011f03 ;;
        x86:7) digest=2842ea8b3b191528ccd8bf0f0600c99de540a56812531fe8b3fa4aacdde3fb87 ;;
    esac
    filename="ddnsto_${family}-dsm${major}.spk"
    relative="synology/4.2.8-7/$filename"
}
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
    ddnsto_synology_select || exit $?
    handoff() {
        printf '%s\n' 'platform=synology' 'package_version=4.2.8-7' \
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
ddnsto_synology_entry() (
    if [ "${PLAN_ONLY:-0}" = 1 ]; then ddnsto_synology_download "$@"; exit $?; fi
    if [ "${ZSETUP_INSTALLER_MODE:-0}" != 1 ]; then
        ddnsto_bootstrap_zsetup || exit $?
        ZSETUP_BIN=$ACTIVE_ZSETUP
    fi
    ZSETUP_SOURCE_BASES=${ZSETUP_SOURCE_BASES:-$DIRECT_PRIMARY_BASES}
    ZSETUP_SOURCE_FALLBACK=${ZSETUP_SOURCE_FALLBACK-$DIRECT_FALLBACK_BASE}
    ddnsto_download() (
        relative=$1; output=$2; digest=$3
        set -- "$ZSETUP_BIN" download -o "$output" --sha256 "$digest" \
            --max-bytes 33554432 --min-free-bytes 8388608
        [ -z "${ZSETUP_CA_FILE:-}" ] || set -- "$@" --ca-file "$ZSETUP_CA_FILE"
        for base in $ZSETUP_SOURCE_BASES; do set -- "$@" "${base%/}/ddnsto/$relative"; done
        [ -z "$ZSETUP_SOURCE_FALLBACK" ] || set -- "$@" --fallback-url "${ZSETUP_SOURCE_FALLBACK%/}/ddnsto/$relative"
        native_child=
        trap '[ -z "$native_child" ] || { kill -TERM "$native_child" 2>/dev/null || true; wait "$native_child" 2>/dev/null || true; }' EXIT
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM
        "$@" &
        native_child=$!
        result=0; wait "$native_child" || result=$?
        native_child=
        exit "$result"
    )
    ddnsto_synology_download "$@"
)
ddnsto_docker_locked() (
    ddnsto_machine_locked ddnsto_docker_lifecycle
)
ddnsto_machine_locked() (
    [ "$(id -u)" = 0 ] || { printf '%s\n' 'DDNSTO: changes require an explicit root shell' >&2; exit 2; }
    ddnsto_bootstrap_safe_ancestors /etc || exit 12
    for directory in /etc/zsetup /etc/zsetup/install-locks; do
        [ -e "$directory" ] || mkdir -m 755 "$directory" || exit 12
        ddnsto_bootstrap_safe_ancestors "$directory" || exit 12
    done
    docker_lock=/etc/zsetup/install-locks/ddnsto
    mkdir -m 700 "$docker_lock" 2>/dev/null || { printf '%s\n' 'DDNSTO: another installation or recovery lease exists' >&2; exit 16; }
    trap 'result=$?; trap - EXIT HUP INT TERM; rmdir "$docker_lock" || result=16; exit "$result"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    ( "$@" )
)
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
    case "${ACTION:-}" in start|stop|restart|configure|repair|uninstall) ;; *) ddnsto_ow_error 'unsupported lifecycle action'; return 2 ;; esac
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
    elif [ "$ACTION" != stop ]; then
        ow_token=$(uci -c "$ow_work/config" -t "$ow_work/delta" -q get 'ddnsto.@ddnsto[0].token' 2>/dev/null)
        [ -n "$ow_token" ] || { ddnsto_ow_error 'existing token required; use configure first'; return 2; }
        unset ow_token
    fi
    ow_enable=1
    [ "$ACTION" != stop ] || ow_enable=0
    uci -c "$ow_work/config" -t "$ow_work/delta" -q set "ddnsto.@ddnsto[0].enabled=$ow_enable" >/dev/null 2>&1 || return 2
    uci -c "$ow_work/config" -t "$ow_work/delta" -q commit ddnsto >/dev/null 2>&1 || return 2
    ow_dirty=1
    mv -f "$ow_work/config/ddnsto" "$config" || return 2
    if [ "$ACTION" = stop ]; then
        "$service_path" disable >/dev/null 2>&1 && "$service_path" stop >/dev/null 2>&1 &&
            ddnsto_ow_wait_service stopped || return 13
        ow_dirty=0
        printf 'operation=stop local_service=stopped cloud_status=unverified\n'
        return 0
    fi
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
ddnsto_openwrt_paths() {
    binary=${DDNSTO_OPENWRT_BIN_PATH:-/usr/sbin/ddnstod}
    config=${DDNSTO_CONFIG_PATH:-/etc/config/ddnsto}
    service_path=${DDNSTO_SERVICE_PATH:-/etc/init.d/ddnsto}
}
ddnsto_openwrt_protected() {
    for ow_target in "$binary" "$config" "$service_path"; do
        ddnsto_ow_safe_path "$ow_target" || return 2
        ddnsto_bootstrap_safe_ancestors "${ow_target%/*}" || return 12
        [ -f "$ow_target" ] && [ "$(stat -c %u "$ow_target")" = "$(id -u)" ] || return 2
        ow_mode=$(stat -c %a "$ow_target") || return 12
        [ "$((0$ow_mode & 0022))" = 0 ] || return 12
        ddnsto_ow_owned "$ow_target" || return 2
    done
    ow_bytes=$(wc -c < "$config") || return 12
    [ "$ow_bytes" -le 16384 ] || return 11
}
ddnsto_openwrt_preflight() {
    ddnsto_openwrt_paths
    DDNSTO_OW_RETAINED=0
    if [ "${ACTION:-install}" = update ]; then
        ddnsto_openwrt_protected || return 2
        if command -v ddnsto_ensure_ow_locked >/dev/null 2>&1; then
            ddnsto_ensure_ow_locked || return $?
        fi
        return 0
    fi
    ow_packages=$(ddnsto_ow_packages) || return 2
    if ddnsto_ow_has_package ddnsto; then
        ddnsto_error 'DDNSTO package already registered; use update or configure'; return 2
    fi
    if [ -e "$config" ] || [ -L "$config" ]; then
        ddnsto_openwrt_retained_state_valid && [ -z "$TOKEN" ] || {
            ddnsto_error 'existing OpenWrt configuration: use update or configure; automatic rebinding refused'; return 2;
        }
        [ ! -e "$binary" ] && [ ! -L "$binary" ] && [ ! -e "$service_path" ] && [ ! -L "$service_path" ] || return 2
        ddnsto_bootstrap_safe_ancestors "${config%/*}" || return 12
        [ "$(stat -c %u "$config")" = "$(id -u)" ] || return 2
        ow_mode=$(stat -c %a "$config") || return 12
        [ "$((0$ow_mode & 0022))" = 0 ] || return 12
        DDNSTO_OW_RETAINED=1
    fi
}
ddnsto_openwrt_local() {
    ddnsto_openwrt_paths
    case "$ACTION" in status|start|stop|restart|repair|configure|uninstall) ;; *) return 2 ;; esac
    ddnsto_openwrt_protected || { ddnsto_error 'complete protected package-owned OpenWrt installation required'; return 2; }
    if [ "$ACTION" = status ]; then
        ow_status=0
        "$service_path" status >/dev/null 2>&1 || ow_status=$?
        case "$ow_status" in 0) ow_state=running ;; 1|3) ow_state=stopped ;; *) return 13 ;; esac
        printf 'local_service=%s cloud_status=unverified\n' "$ow_state"
        return 0
    fi
    if [ "$ACTION" = configure ] && [ -z "$TOKEN" ]; then
        TOKEN=$(ddnsto_prompt_token) || return $?
    fi
    ddnsto_openwrt_lifecycle
}
ddnsto_openwrt_apply() {
    ddnsto_openwrt_paths
    if [ -e "$config" ] || [ -L "$config" ]; then
        [ "${ACTION:-install}" = update ] || [ "${DDNSTO_OW_RETAINED:-0}" = 1 ] || {
            ddnsto_error 'existing OpenWrt configuration: use update or configure; automatic rebinding refused'; return 2;
        }
        if [ "${DDNSTO_OW_RETAINED:-0}" = 1 ]; then
            ddnsto_openwrt_retained_state_valid || return 2
        else ddnsto_openwrt_protected || return 2; fi
        ddnsto_openwrt_with_retained_config ddnsto_openwrt_apply_packages || return $?
        ddnsto_openwrt_resume_config || return $?
        if [ "${DDNSTO_OW_RETAINED:-0}" = 1 ]; then
            ddnsto_openwrt_retained_state_valid || return 2
            rm -f "${config%/*}/.uninstalled-openwrt-v1" || return 12
        fi
    else
        [ "${ACTION:-install}" = install ] || { ddnsto_error 'update requires existing configuration'; return 2; }
        ow_packages=$(ddnsto_ow_packages) || return 2
        if ddnsto_ow_has_package ddnsto; then return 2; fi
        ddnsto_openwrt_apply_packages || return $?
        if [ -n "$TOKEN" ]; then
            ( ACTION=configure; ddnsto_openwrt_local ) || return $?
        fi
    fi
    if [ "${VERIFY_STATUS:-0}" = 1 ]; then
        ddnsto_ow_wait_service running || return 13
        "$binary" -w >/dev/null 2>&1 || return 13
    fi
    printf 'operation=%s config=retained cloud_status=unverified\n' "$ACTION"
}
ddnsto_flow_note() {
    [ -n "${DDNSTO_FLOW_DIR:-}" ] || return 0
    case "$1" in checking|installing|installed|starting|started) ;; *) return 2 ;; esac
    printf '%s\n' "$1" > "$DDNSTO_FLOW_DIR/state"
    printf 'stage=%s\n' "$1" >> "$DDNSTO_FLOW_DIR/events.log"
}
ddnsto_flow_error() {
    if [ -n "${DDNSTO_FLOW_DIR:-}" ]; then
        printf '%s\n' "$1" "$2" "$3" > "$DDNSTO_FLOW_DIR/reason"
        printf 'error=%s\n' "$1" >> "$DDNSTO_FLOW_DIR/events.log"
    fi
    printf 'DDNSTO [%s]：%s。%s\n' "$1" "$2" "$3" >&2
    return 2
}
ddnsto_version_parts() (
    case "$1" in ''|*[!0-9.]*|.*|*.|*..*) exit 2 ;; esac
    IFS=.; set -- $1
    [ "$#" = 3 ] || exit 2
    for part do
        [ "${#part}" -le 6 ] || exit 2
        case "$part" in 0|[1-9]|[1-9][0-9]*) ;; *) exit 2 ;; esac
    done
    printf '%s %s %s\n' "$1" "$2" "$3"
)
ddnsto_version_order() (
    left=$(ddnsto_version_parts "$1") || exit 2
    right=$(ddnsto_version_parts "$2") || exit 2
    set -- $left $right
    while [ "$#" -gt 3 ]; do
        [ "$1" -le "$4" ] || { printf '1\n'; exit 0; }
        [ "$1" -ge "$4" ] || { printf '%s\n' -1; exit 0; }
        shift
    done
    printf '0\n'
)
ddnsto_ensure_decision() {
    ENSURE_ACTION=install
    [ -n "$1" ] || return 0
    ensure_order=$(ddnsto_version_order "$1" "$2") || {
        ddnsto_flow_error E_VERSION '无法安全判断已安装版本，未执行覆盖' '请检查现有安装来源'; return 2;
    }
    ENSURE_ACTION=start
    [ "$ensure_order" != -1 ] || ENSURE_ACTION=update
}
ddnsto_ensure_preflight() {
    case "$detected_platform" in linux|openwrt|synology|asus) ;; *)
        ddnsto_flow_error E_PLATFORM '此设备暂不支持自动安装' '请使用该设备的手动安装教程'; return 2 ;;
    esac
    [ -n "$TOKEN" ] && [ "${#TOKEN}" -le 16384 ] || {
        ddnsto_flow_error E_TOKEN '缺少有效的账号 Token' '请登录控制台重新复制完整命令'; return 2;
    }
    [ "$REQUESTED_METHOD" != docker ] || {
        ddnsto_flow_error E_METHOD 'Docker 自动安装尚未完成验收' '请使用已验收的原生平台；不会自动切换安装方式'; return 2;
    }
    [ -z "$FORCE_VERSION" ] && [ "$VERIFY_STATUS" = 0 ] || {
        ddnsto_flow_error E_OPTIONS '默认流程不接受手选版本或云端检查选项' '请重新复制默认命令'; return 2;
    }
    [ "${DDNSTO_VERSION:-4.2.8}" = 4.2.8 ] || {
        ddnsto_flow_error E_VERSION '默认流程只使用该审核安装器固定的客户端版本' '请使用推荐版本入口'; return 2;
    }
}
ddnsto_flow_finish() {
    flow_rc=$1
    trap - EXIT
    trap '' HUP INT TERM
    if [ -n "${flow_child:-}" ]; then
        kill -TERM "$flow_child" 2>/dev/null || true
        wait "$flow_child" 2>/dev/null || true
    fi
    flow_state=$(cat "$DDNSTO_FLOW_DIR/state")
    if [ "$flow_rc" = 0 ] && [ "$flow_state" != started ]; then flow_rc=13; fi
    if [ "$flow_rc" = 0 ]; then
        printf '%s\n' 'DDNSTO：安装成功，启动成功。' '仅验证本地运行；设备在线状态请查看客户端运行日志。'
    else
        flow_code=E_EXECUTOR
        flow_reason="平台执行失败（退出码 $flow_rc），未能确认启动成功"
        flow_next='请检查安装状态和服务日志后重试；不要删除配置或强制重装'
        if [ -f "$DDNSTO_FLOW_DIR/reason" ]; then
            { IFS= read -r flow_code; IFS= read -r flow_reason; IFS= read -r flow_next; } < "$DDNSTO_FLOW_DIR/reason"
        fi
        printf 'DDNSTO [%s]：%s\n' "$flow_code" "$flow_reason" >&2
        case "$flow_state" in installed|starting) printf '%s\n' '当前状态：安装成功，启动失败；配置保留，请检查服务日志。' >&2 ;;
            installing) printf '%s\n' '当前状态：安装未完成；恢复已由平台执行器尝试，需检查残留状态。' >&2 ;;
            *) printf '%s\n' '当前状态：未确认安装完成；未自动换绑或卸载。' >&2 ;; esac
        printf '下一步：%s\n' "$flow_next" >&2
    fi
    printf 'exit_code=%s\n' "$flow_rc" >> "$DDNSTO_FLOW_DIR/events.log"
    printf '脱敏诊断记录：%s/events.log\n' "$DDNSTO_FLOW_DIR" >&2
    exit "$flow_rc"
}
ddnsto_ensure_entry() {
    set +x
    umask 077
    if [ "${detected_platform:-}" = asus ]; then
        ddnsto_asus_storage || { ddnsto_flow_error E_STORAGE '华硕受保护存储不可用' '请检查 /jffs 挂载，不要放宽目录权限'; exit 12; }
        DDNSTO_FLOW_DIR=$(ddnsto_asus_mktemp "$ASUS_STATE") || exit 12
    else
        DDNSTO_FLOW_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ddnsto-result.XXXXXX") || exit 12
    fi
    flow_child=
    trap 'ddnsto_flow_finish $?' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    ddnsto_flow_note checking
    printf '%s\n' 'DDNSTO：正在检查并安装，请稍候…' >&2
    ( set -e; ddnsto_ensure_preflight; ddnsto_ensure_execute "$@" ) >/dev/null 2>&1 &
    flow_child=$!
    flow_rc=0; wait "$flow_child" || flow_rc=$?
    flow_child=
    exit "$flow_rc"
}
ddnsto_ensure_execute() {
    if [ "$detected_platform" = asus ]; then ddnsto_asus_ensure; return $?; fi
    if [ "$detected_platform" = synology ]; then ddnsto_synology_ensure; return $?; fi
    ZSETUP_INSTALL_SCOPE=${installer_scope:-system}
    ZSETUP_INSTALL_PREFIX=${installer_prefix:-}
    [ -z "${installer_work_dir:-}" ] || ZSETUP_WORK_DIR=$installer_work_dir
    if [ "${ZSETUP_INSTALLER_MODE:-0}" = 1 ]; then ddnsto_install "$@"
    else bootstrap_and_run "$@"; fi
}
ddnsto_ensure_tty_available() ( : <>/dev/tty ) 2>/dev/null
ddnsto_ensure_authorize() {
    if [ -x /usr/bin/sudo ]; then
        /usr/bin/sudo -n true 2>/dev/null && return 0
        if ddnsto_ensure_tty_available && /usr/bin/sudo -v </dev/tty >/dev/tty 2>&1; then return 0; fi
    fi
    ddnsto_flow_error E_PERMISSION '未取得系统服务所需的管理员权限' '请执行 sudo -i 后重新粘贴命令，或请管理员安装'
}
ddnsto_ensure_protected_config() {
    [ -f "$SERVICE_CONFIG" ] && [ ! -L "$SERVICE_CONFIG" ] || return 2
    [ "$("$ZSETUP_BIN" storage "$SERVICE_CONFIG" get system_protected)" = true ] || return 2
    ensure_config_size=$(wc -c < "$SERVICE_CONFIG") || return 2
    [ "$ensure_config_size" -le 16384 ]
}
ddnsto_ensure_linux_account() {
    ddnsto_ensure_protected_config &&
        DDNSTO_EXPECTED_ACCOUNT="$ENSURE_TOKEN" jq -e -s '
        length == 1 and (.[0] | type == "object" and
        (.token | type == "string" and length > 0) and
        .token == env.DDNSTO_EXPECTED_ACCOUNT)' "$SERVICE_CONFIG" >/dev/null 2>&1 || {
        ddnsto_flow_error E_ACCOUNT '现有安装不属于当前账号，或无法确认配置归属' '请使用原账号管理；不会自动换绑或覆盖配置'; return 2;
    }
}
ddnsto_ensure_jq() {
    command -v jq >/dev/null 2>&1 && return 0
    if command -v apt-get >/dev/null 2>&1; then
        "$ZSETUP_BIN" run -- env DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends install jq >/dev/null 2>&1 || return 2
    elif command -v dnf >/dev/null 2>&1; then
        "$ZSETUP_BIN" run -- dnf -y install jq >/dev/null 2>&1 || return 2
    elif command -v yum >/dev/null 2>&1; then
        "$ZSETUP_BIN" run -- yum -y install jq >/dev/null 2>&1 || return 2
    else return 2; fi
    command -v jq >/dev/null 2>&1
}
ddnsto_ensure_linux_running() {
    ensure_pid=$(ddnsto_managed_property MainPID) || return 13
    case "$ensure_pid" in ''|0|*[!0-9]*) return 13 ;; esac
    ensure_probe=0
    while [ "$ensure_probe" -lt 3 ]; do
        [ "$(ddnsto_managed_property ActiveState)" = active ] || return 13
        [ "$(ddnsto_managed_property MainPID)" = "$ensure_pid" ] || return 13
        ensure_probe=$((ensure_probe + 1))
        [ "$ensure_probe" = 3 ] || sleep 1
    done
}
ddnsto_ensure_linux() {
    case "$arch" in x86_64|aarch64) ;; *)
        ddnsto_flow_error E_ARCH '此 Linux CPU 架构尚未支持自动安装' '请使用对应平台的手动安装包'; return 2 ;; esac
    [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1 || {
        ddnsto_flow_error E_SERVICE_MANAGER '当前系统没有可用的 systemd 服务管理器' '请使用该平台手动安装方式；不会自动切换 Docker'; return 2;
    }
    installer_layout ddnsto system || return $?
    SERVICE_CONFIG=/etc/ddnsto/ddnsto-config.json
    ensure_current=
    if [ -e "$INSTALLER_PREFIX/.managed" ] || [ -L "$INSTALLER_PREFIX/.managed" ]; then
        ddnsto_managed_owned || {
            ddnsto_flow_error E_OWNERSHIP '现有安装不完整或不是可管理的安装' '请先检查安装来源和残留事务'; return 2;
        }
        ddnsto_ensure_jq || {
            ddnsto_flow_error E_DEPENDENCY '无法从现有软件源补齐 jq，不能安全确认账号' '请用系统包管理器安装 jq 后重试'; return 2;
        }
        ddnsto_ensure_linux_account || return $?
        ensure_current=${SERVICE_OLD#versions/}
    elif [ -e "$SERVICE_CONFIG" ] || [ -L "$SERVICE_CONFIG" ]; then
        ddnsto_flow_error E_OWNERSHIP '发现未归属的历史配置' '请先人工确认历史安装；不会自动覆盖'; return 2
    fi
    ddnsto_ensure_decision "$ensure_current" "$(ddnsto_pinned_version standard)" || return $?
    if [ "$ENSURE_ACTION" = start ]; then
        ddnsto_flow_note installed
        ddnsto_flow_note starting
        ( ACTION=start; TOKEN=; ddnsto_managed_write ) || return $?
    else
        ddnsto_flow_note installing
        if [ "$ENSURE_ACTION" = install ]; then
            ddnsto_install --action install --token "$ENSURE_TOKEN" || return $?
        else
            ddnsto_install --action update || return $?
        fi
        ddnsto_flow_note installed
    fi
    ddnsto_ensure_linux_running || return 13
    ddnsto_flow_note started
}
ddnsto_ensure_linux_locked() {
    [ "${DDNSTO_ENSURE_ACTIVE:-0}" = 1 ] || return 0
    if [ -n "${SERVICE_OLD:-}" ]; then
        ddnsto_ensure_linux_account || return $?
        if [ "${ACTION:-}" = update ]; then
            ensure_locked_order=$(ddnsto_version_order "${SERVICE_OLD#versions/}" "$(ddnsto_pinned_version standard)") || return 2
            [ "$ensure_locked_order" != 1 ] || {
                ddnsto_flow_error E_VERSION '已安装版本在执行期间变为更高版本' '请重新执行同一命令；不会降级'; return 2;
            }
        fi
    elif [ -e "$SERVICE_CONFIG" ] || [ -L "$SERVICE_CONFIG" ]; then
        ddnsto_flow_error E_OWNERSHIP '执行期间出现未归属的配置' '请检查并发安装；不会覆盖'; return 2
    fi
}
ddnsto_ensure_ow_account() {
    ddnsto_openwrt_protected || {
        ddnsto_flow_error E_OWNERSHIP '现有路由器安装文件归属不明或权限不安全' '请检查包管理器记录及配置权限；不会覆盖'; return 2;
    }
    ensure_pending=$(uci -c "${config%/*}" -q changes ddnsto 2>/dev/null) && [ -z "$ensure_pending" ] || {
        ddnsto_flow_error E_CONFIG '存在尚未提交的 UCI 修改，无法安全处理' '请在路由器管理界面保存或撤销修改后重试'; return 2;
    }
    [ "$(uci -c "${config%/*}" -q get 'ddnsto.@ddnsto[0]' 2>/dev/null)" = ddnsto ] &&
        ! uci -c "${config%/*}" -q get 'ddnsto.@ddnsto[1]' >/dev/null 2>&1 || {
        ddnsto_flow_error E_CONFIG '配置中缺少唯一的 DDNSTO 服务段' '请人工核对 UCI 配置；不会自动合并或覆盖'; return 2;
    }
    ensure_account=$(uci -c "${config%/*}" -q get 'ddnsto.@ddnsto[0].token' 2>/dev/null) || ensure_account=
    if [ -z "$ensure_account" ] || [ "$ensure_account" != "$ENSURE_TOKEN" ]; then
        unset ensure_account
        ddnsto_flow_error E_ACCOUNT '设备已绑定其他账号，或无法确认账号归属' '请使用原账号管理；不会自动换绑'; return 2
    fi
    unset ensure_account
}
ddnsto_ensure_ow_version() (
    if [ "$package_manager" = opkg ]; then
        listing=$(opkg list-installed 2>/dev/null) || exit 2
        count=0; installed=
        while read -r name dash version rest; do
            [ "$name" = ddnsto ] || continue
            [ "$dash" = - ] || exit 2
            count=$((count + 1)); installed=$version
        done <<EOF
$listing
EOF
        [ "$count" = 1 ] || exit 2
    else
        installed=$(apk info -v ddnsto 2>/dev/null) || exit 2
        case "$installed" in ddnsto-*) installed=${installed#ddnsto-} ;; *) exit 2 ;; esac
    fi
    case "$installed" in
        *~*)
            case "${arch:-}" in
                x86_64) arch_tag=8664 ;; aarch64) arch_tag=aa64 ;;
                armv7) arch_tag=aa32 ;; mipsel) arch_tag=1b0c ;;
                *) exit 2 ;;
            esac
            case "${installed#*~}" in "$arch_tag"-*) ;; *) exit 2 ;; esac
            suffix=${installed#*~}
            suffix=${suffix#"$arch_tag"-}
            installed="${installed%%~*}-$suffix"
            ;;
    esac
    case "$installed" in ''|*[!0-9.r-]*) exit 2 ;; esac
    release=${installed%%-*}
    if [ "$release" != "$installed" ]; then
        revision=${installed#*-}
        revision=${revision#r}
        case "$revision" in ''|*[!0-9]*) exit 2 ;; esac
    fi
    ddnsto_version_parts "$release" >/dev/null || exit 2
    printf '%s\n' "$release"
)
ddnsto_ensure_ow_pid() {
    ensure_procd=$(ubus call service list '{"name":"ddnsto"}' 2>/dev/null) || return 13
    printf '%s\n' "$ensure_procd" | jsonfilter -e '@.ddnsto.instances.*.pid' 2>/dev/null
}
ddnsto_ensure_ow_running() {
    ensure_pid=$(ddnsto_ensure_ow_pid) || return 13
    case "$ensure_pid" in ''|0|*[!0-9]*) return 13 ;; esac
    ensure_probe=0
    while [ "$ensure_probe" -lt 3 ]; do
        "$service_path" status >/dev/null 2>&1 || return 13
        [ "$(ddnsto_ensure_ow_pid)" = "$ensure_pid" ] || return 13
        ensure_probe=$((ensure_probe + 1))
        [ "$ensure_probe" = 3 ] || sleep 1
    done
}
ddnsto_ensure_ow_start() {
    ddnsto_ensure_ow_account || return $?
    ddnsto_flow_note starting
    ( ACTION=start; TOKEN=; ddnsto_openwrt_local ) || return $?
    ddnsto_ensure_ow_running || return 13
}
ddnsto_ensure_openwrt() {
    case "$arch:$package_manager" in
        x86_64:opkg|aarch64:opkg|armv7:opkg|mipsel:opkg|x86_64:apk|aarch64:apk|armv7:apk|mipsel:apk) ;;
        *) ddnsto_flow_error E_ARCH '此路由器架构或包管理器不受支持' '请使用设备厂商支持的安装方式'; return 2 ;;
    esac
    for ensure_tool in uci ubus jsonfilter; do
        command -v "$ensure_tool" >/dev/null 2>&1 || {
            ddnsto_flow_error E_DEPENDENCY '缺少路由器 UCI/procd 状态检查工具' '请恢复固件自带的 uci、ubus、jsonfilter 后重试'; return 2;
        }
    done
    ddnsto_openwrt_paths
    ow_packages=$(ddnsto_ow_packages) || return 2
    ensure_current=
    if ddnsto_ow_has_package ddnsto; then
        ddnsto_ensure_ow_account || return $?
        ensure_current=$(ddnsto_ensure_ow_version) || {
            ddnsto_flow_error E_VERSION '无法识别当前路由器客户端版本' '请检查包管理器记录；不会强制覆盖'; return 2;
        }
    else
        for ensure_path in "$config" "$binary" "$service_path"; do
            [ ! -e "$ensure_path" ] && [ ! -L "$ensure_path" ] || {
                ddnsto_flow_error E_OWNERSHIP '发现未归属的历史安装或配置' '请先确认原安装来源；不会自动覆盖'; return 2;
            }
        done
    fi
    ddnsto_ensure_decision "$ensure_current" "$(ddnsto_pinned_version standard)" || return $?
    if [ "$ENSURE_ACTION" != start ]; then
        ddnsto_flow_note installing
        if [ "$ENSURE_ACTION" = install ]; then
            ddnsto_install --action install --token "$ENSURE_TOKEN" || return $?
        else ddnsto_install --action update || return $?; fi
    fi
    ddnsto_flow_note installed
    ddnsto_machine_locked ddnsto_ensure_ow_start || return $?
    ddnsto_flow_note started
}
ddnsto_ensure_ow_locked() {
    [ "${DDNSTO_ENSURE_ACTIVE:-0}" = 1 ] || return 0
    [ "${ACTION:-}" = update ] || return 0
    ddnsto_ensure_ow_account || return $?
    ensure_current=$(ddnsto_ensure_ow_version) || return 2
    ensure_order=$(ddnsto_version_order "$ensure_current" "$(ddnsto_pinned_version standard)") || return 2
    [ "$ensure_order" != 1 ] || {
        ddnsto_flow_error E_VERSION '执行期间已安装版本变为更高版本' '请重新执行；不会降级'; return 2;
    }
}
ddnsto_synopkg() { /usr/syno/bin/synopkg "$@"; }
ddnsto_synology_storage() {
    syno_storage=/var/lib/ddnsto-installer
    ddnsto_bootstrap_safe_ancestors /var/lib && ddnsto_bootstrap_private_dir "$syno_storage" || {
        ddnsto_flow_error E_STORAGE '群晖安装器缓存目录不安全或不可写' '请检查 /var/lib/ddnsto-installer 权限'; return 12;
    }
}
ddnsto_synology_preflight() {
    [ "$(id -u)" = 0 ] || { ddnsto_flow_error E_PRIVILEGE '群晖套件安装需要管理员权限' '请使用 sudo -i 后重新执行'; return 2; }
    for tool in jq readlink stat; do
        command -v "$tool" >/dev/null 2>&1 || { ddnsto_flow_error E_DEPENDENCY '缺少群晖配置或进程检查工具' '请检查 DSM 的 jq、stat、readlink'; return 2; }
    done
    [ -x /usr/syno/bin/synopkg ] || { ddnsto_flow_error E_DEPENDENCY '找不到 DSM 套件管理器' '请通过套件中心手动安装'; return 2; }
    ddnsto_synology_select || { ddnsto_flow_error E_PLATFORM '此 DSM 版本或架构尚未支持自动安装' '请使用匹配机型的手动套件'; return 2; }
    [ "$major" = 7 ] || { ddnsto_flow_error E_PLATFORM 'DSM 6 暂仅支持手动安装' '请使用套件中心手动安装'; return 2; }
    syno_pkg=/var/packages/ddnsto
    syno_config=$syno_pkg/var/ddnsto-config.json
    ddnsto_synology_storage
}
ddnsto_synology_check_paths() {
    syno_uid=$(id -u ddnsto) || return 2
    for path in "$syno_pkg/INFO" "$syno_pkg/target/bin/ddnsto" "$syno_config"; do
        [ -f "$path" ] || return 2
        resolved=$(readlink -f "$path") || return 2
        while [ "$resolved" != / ]; do
            owner=$(stat -c %u "$resolved") || return 2
            mode=$(stat -c %a "$resolved") || return 2
            case "$owner" in 0|"$syno_uid") ;; *) return 2 ;; esac
            [ "$((0$mode & 0022))" = 0 ] || return 2
            resolved=${resolved%/*}; [ -n "$resolved" ] || resolved=/
        done
    done
}
ddnsto_synology_account() {
    ddnsto_synology_check_paths || { ddnsto_flow_error E_OWNERSHIP '群晖套件文件缺失或权限不安全' '请核对套件来源与配置权限，不要强制覆盖'; return 2; }
    printf '%s' "$TOKEN" | jq -Rse --slurpfile config "$syno_config" '
        . as $expected | ($config | length == 1) and
        ($config[0] | type == "object" and (.token == $expected) and
        (.routeridx | type == "number" and . >= 0 and . <= 99 and floor == .))
    ' >/dev/null 2>&1 || {
        ddnsto_flow_error E_ACCOUNT '套件账号不匹配或设备编号无法安全确认' '请使用原账号检查套件设置，不会自动换绑'; return 2;
    }
}
ddnsto_synology_version() {
    syno_version=$(ddnsto_synopkg version ddnsto) || return 2
    case "$syno_version" in *-*) ;; *) return 2 ;; esac
    syno_release=${syno_version%-*}; syno_revision=${syno_version##*-}
    ddnsto_version_parts "$syno_release" >/dev/null || return 2
    case "$syno_revision" in ''|*[!0-9]*|0*) return 2 ;; esac
    [ "${#syno_revision}" -le 6 ]
}
ddnsto_synology_fetch() (
    ddnsto_synology_storage || exit $?
    WORK_ROOT="$syno_storage/native"
    ddnsto_bootstrap_zsetup || { ddnsto_flow_error E_BOOTSTRAP 'zsetup 下载或校验失败' '请检查 HTTPS 下载和缓存权限'; exit 2; }
    ddnsto_synology_select || exit 2
    "$ACTIVE_ZSETUP" download -o "$1" --sha256 "$digest" --max-bytes 33554432 --min-free-bytes 8388608 \
        "https://fw.koolcenter.com/binary/ddnsto/$relative" \
        "https://fw.d4ctech.com/binary/ddnsto/$relative" \
        --fallback-url "https://fw20.koolcenter.com/binary/ddnsto/$relative"
)
ddnsto_synology_running() {
    binary=$(readlink -f "$syno_pkg/target/bin/ddnsto") || return 13
    pid=$(cat "$syno_pkg/var/ddnsto.pid") || return 13
    case "$pid" in ''|*[!0-9]*) return 13 ;; esac
    [ "$pid" -gt 1 ] || return 13
    for probe in 1 2 3; do
        ddnsto_synopkg status ddnsto | jq -e '.status == "running"' >/dev/null || return 13
        kill -0 "$pid" 2>/dev/null && [ "$(readlink "/proc/$pid/exe")" = "$binary" ] || return 13
        [ "$(cat "$syno_pkg/var/ddnsto.pid")" = "$pid" ] || return 13
        [ "$probe" = 3 ] || sleep 1
    done
}
ddnsto_synology_ensure_locked() (
    umask 077
    ddnsto_synology_preflight || exit $?
    case "$TOKEN" in ''|*[!a-zA-Z0-9_-]*) ddnsto_flow_error E_TOKEN 'Token 格式不适用于群晖套件' '请从控制台重新复制'; exit 2 ;; esac
    need_install=1; existing=0
    if [ -e "$syno_pkg/INFO" ]; then
        existing=1
        ddnsto_synology_account || exit $?
        ddnsto_synology_version || { ddnsto_flow_error E_VERSION '无法识别当前套件版本' '请检查套件中心，不会强制覆盖'; exit 2; }
        order=$(ddnsto_version_order "$syno_release" 4.2.8) || exit 2
        if [ "$order" = 1 ] || { [ "$order" = 0 ] && [ "$syno_revision" -ge 7 ]; }; then need_install=0; fi
    elif [ -e "$syno_config" ] || [ -e "$syno_pkg/target" ] || [ -L "$syno_pkg/target" ]; then
        ddnsto_flow_error E_OWNERSHIP '发现未登记的群晖套件残留' '请在套件中心检查，不会覆盖原配置'; exit 2
    else
        ddnsto_synology_fresh_preflight || exit $?
    fi
    if [ "$need_install" = 1 ]; then
        syno_work=$(mktemp -d "$syno_storage/package.XXXXXX") || exit 12
        [ "$existing" = 0 ] || cp -p "$syno_config" "$syno_work/config.before.json" || exit 12
        ddnsto_synology_fetch "$syno_work/package.spk" || {
            ddnsto_flow_error E_DOWNLOAD '群晖套件下载或校验失败，尚未修改套件' '请检查下载连通性后重试'; exit 11;
        }
        if [ "$existing" = 1 ]; then
            ddnsto_synology_account || exit $?
            cmp -s "$syno_config" "$syno_work/config.before.json" || { ddnsto_flow_error E_CONFIG '下载期间配置已改变' '请重新执行，不会覆盖修改'; exit 2; }
            ddnsto_synology_version || exit 2
            order=$(ddnsto_version_order "$syno_release" 4.2.8) || exit 2
            [ "$order" != 1 ] && { [ "$order" != 0 ] || [ "$syno_revision" -le 7 ]; } || {
                ddnsto_flow_error E_VERSION '下载期间已安装版本变更' '请重新执行，不会降级'; exit 2;
            }
        fi
        ddnsto_flow_note installing
        if [ "$existing" = 0 ]; then
            ddnsto_synology_fresh_install "$syno_work/package.spk" || exit $?
        else
            ddnsto_synopkg install "$syno_work/package.spk" >/dev/null 2>&1 || {
            ddnsto_flow_error E_PACKAGE 'DSM 套件安装失败，未自动卸载或删除配置' "请检查套件中心；私有备份目录：$syno_work"; exit 11;
            }
        fi
        ddnsto_synology_version && [ "$syno_version" = 4.2.8-7 ] || {
            ddnsto_flow_error E_PACKAGE '套件版本未达到预期' '请检查套件中心安装记录'; exit 11;
        }
        if [ "$existing" = 1 ]; then
            cmp -s "$syno_config" "$syno_work/config.before.json" || {
                ddnsto_flow_error E_CONFIG '升级后配置与备份不一致' "停止自动操作，请检查私有备份：$syno_work"; exit 12;
            }
        fi
    fi
    ddnsto_synology_account || exit $?
    ddnsto_flow_note installed
    ddnsto_flow_note starting
    ddnsto_synopkg start ddnsto >/dev/null 2>&1 && ddnsto_synology_running || {
        ddnsto_flow_error E_START '套件已安装，但未确认稳定启动' '请检查套件中心和套件运行日志，配置已保留'; exit 13;
    }
    ddnsto_flow_note started
)
ddnsto_synology_ensure() { ddnsto_machine_locked ddnsto_synology_ensure_locked; }
ddnsto_synowebapi() { /usr/syno/bin/synowebapi --exec "$@"; }
ddnsto_synology_absent_paths() {
    for path do
        if [ -e "$path" ] || [ -L "$path" ]; then
            ddnsto_flow_error E_OWNERSHIP '发现群晖套件或历史配置残留，未执行新装' '请检查套件中心和原配置，不会自动删除或换绑'; return 2
        fi
    done
}
ddnsto_synology_fresh_check() {
    ddnsto_synology_absent_paths "$syno_pkg" /volume*/@appdata/ddnsto \
        /volume*/@appstore/ddnsto /tmp/.ddnsto/ddnsto-config.json
}
ddnsto_synology_fresh_preflight() {
    [ -x /usr/syno/bin/synowebapi ] || {
        ddnsto_flow_error E_DEPENDENCY 'DSM 缺少套件中心本机安装接口' '请通过套件中心手动安装 SPK'; return 2;
    }
    syno_check=$(ddnsto_synowebapi api=SYNO.Core.Package.Installation method=check version=1 'id="ddnsto"' 2>/dev/null) &&
    syno_volume=$(printf '%s' "$syno_check" | jq -er '
        select(.success == true and .data.is_occupied == false) |
        .data | .volume_path as $v | select(.volume_list | any(.mount_point == $v)) |
        $v | select(type == "string")
    ' 2>/dev/null) || {
        ddnsto_flow_error E_STORAGE 'DSM 无法确认可用的默认套件安装卷，或安装器正忙' '请在套件中心设置默认安装卷，等待其他安装完成后重试'; return 2;
    }
    case "$syno_volume" in
        /volume*) volume_number=${syno_volume#/volume} ;;
        *) volume_number=invalid ;;
    esac
    case "$volume_number" in ''|*[!0-9]*)
        ddnsto_flow_error E_STORAGE 'DSM 返回的默认安装卷路径不受支持' '请通过套件中心手动安装'; return 2 ;;
    esac
    ddnsto_bootstrap_safe_ancestors "$syno_volume" || {
        ddnsto_flow_error E_STORAGE '群晖安装卷权限不安全' '请检查默认安装卷权限'; return 2;
    }
    ddnsto_synology_fresh_check
}
ddnsto_synology_fresh_install() (
    ddnsto_synology_fresh_check || exit $?
    extra=$(printf '%s' "$TOKEN" | jq -Rsc '{wizard_ddnsto_token:.,wizard_ddnsto_idx:"0"}|tojson') || exit 2
    package_path=$(printf '%s' "$1" | jq -Rsc .) || exit 2
    result=$(ddnsto_synowebapi api=SYNO.Core.Package.Installation method=install version=1 \
        "path=$package_path" "volume_path=\"$syno_volume\"" "extra_values=$extra" \
        check_codesign=false force=false installrunpackage=false 2>/dev/null) || {
        ddnsto_flow_error E_PACKAGE 'DSM 本机安装接口执行失败' '请检查套件中心安装记录；不会自动卸载或强制重装'; exit 11;
    }
    unset extra
    printf '%s' "$result" | jq -e '.success == true and (.data.has_fail != true)' >/dev/null 2>&1 || {
        code=$(printf '%s' "$result" | jq -r '.error.code | select(type == "number" and floor == .)' 2>/dev/null) || code=
        case "$code" in ''|*[!0-9]*) code=unknown ;; esac
        ddnsto_flow_error E_PACKAGE "DSM 套件安装被拒绝（接口错误码 $code）" '请检查套件中心安装记录；不会自动卸载或强制重装'; exit 11;
    }
)
ddnsto_asus_channel() (
    model=$1 kernel=$2 architecture=$3 source=$4
    model_channel= source_channel=
    case "$kernel" in ''|*[!a-zA-Z0-9._+-]*) return 2 ;; esac
    release=${kernel%%-*}; release=${release%%+*}
    case "$release" in ''|*[!0-9.]*|.*|*.|*..*) return 2 ;; esac
    IFS=.; set -- $release; unset IFS
    [ "$#" -ge 3 ] || return 2
    for component do
        case "$component" in 0|[1-9]*) ;; *) return 2 ;; esac
    done
    case "$architecture" in armv7l|aarch64) ;; *) return 2 ;; esac
    case "$model" in
        TX-AX6000|TUF-AX4200Q|RT-AX57_Go|GS7|ZenWiFi_BT8P|GS7_Air|GS-BE7200X)
            model_channel=mtksoft ;;
        ZenWiFi_BD4) model_channel=ipq32soft ;;
        TUF_6500) model_channel=ipq64soft ;;
        RT-AX89X) model_channel=qcasoft ;;
    esac
    case "${source%/}" in
        '') ;;
        https://rogsoft.ddnsto.com) source_channel=rogsoft ;;
        https://armsoft.ddnsto.com) source_channel=armsoft ;;
        https://mtksoft.ddnsto.com) source_channel=mtksoft ;;
        https://ipq32soft.ddnsto.com) source_channel=ipq32soft ;;
        https://ipq64soft.ddnsto.com) source_channel=ipq64soft ;;
        https://qcasoft.ddnsto.com) source_channel=qcasoft ;;
        *) return 2 ;;
    esac
    if [ -n "$model_channel" ] && [ -n "$source_channel" ]; then
        [ "$model_channel" = "$source_channel" ] || return 2
    fi
    channel=${model_channel:-$source_channel}
    case "$kernel" in
        2.6.*)
            [ "$architecture" = armv7l ] || return 2
            [ -z "$channel" ] || [ "$channel" = armsoft ] || return 2
            channel=armsoft ;;
        4.[1-9]*|5.*|6.*)
            [ -n "$channel" ] && [ "$channel" != armsoft ] || return 2 ;;
        *) return 2 ;;
    esac
    printf '%s\n' "$channel"
)
ddnsto_asus_package() (
    case "$1" in
        rogsoft) marker=hnd size=8104981 sha=671c1c77d7b867f5019af35e8702be665695e30c107138ae150d045e11df1960 ;;
        armsoft) marker=arm384 size=3430887 sha=8e0ff71269b8ba8674427896310d99309d97eae92b007d97cb968eb1d880664d ;;
        mtksoft) marker=mtk size=8105004 sha=8d08921e49bed7bcafed48dc6c6b6795467f77767a97cc8af23f0b463285248a ;;
        ipq32soft) marker=ipq32 size=8105008 sha=56c0298ec811e51cf93390bbfa2f9489752188320aaf96c43d2b19289ba7580d ;;
        ipq64soft) marker=ipq64 size=8105008 sha=4cb863a85d5c5dcd00ff8a3f5a09fa90465b59b48e48cdce12163be62b1f10ce ;;
        qcasoft) marker=qca size=8105006 sha=fa021afaf9424f032ff9e084e76c80fadd7fe74e844060e0d84ac6053db19216 ;;
        *) return 2 ;;
    esac
    printf '%s\n' "https://asusgo.koolcenter.com/$1/ddnsto/ddnsto.tar.gz" 4.2.8 "$marker" "$size" "$sha"
)
_ddnsto_asus_status() { cat /proc/self/status; }
ddnsto_asus_uid() (
    status=$(_ddnsto_asus_status) || return 1
    printf '%s\n' "$status" | LC_ALL=C awk '
        $1 == "Uid:" {
            count++
            if (NF != 5) bad=1
            for (i=2; i<=5; i++) if ($i !~ /^[0-9]+$/) bad=1
            uid=$3
        }
        END { if (count != 1 || bad) exit 1; print uid }
    '
)
ddnsto_asus_has() { [ "$#" = 1 ] && type "$1" >/dev/null 2>&1; }
_ddnsto_asus_ls() { LC_ALL=C ls -nd "$1"; }
_ddnsto_asus_metadata() (
    [ "$#" = 1 ] || return 1
    case "$1" in /*) ;; *) return 1 ;; esac
    case "$1" in *[!a-zA-Z0-9_./-]*|*/|*//*|*/../*|*/..|*/./*|*/.) return 1 ;; esac
    listing=$(_ddnsto_asus_ls "$1") || return 1
    printf '%s\n' "$listing" | LC_ALL=C awk '
        NR == 1 && NF == 9 &&
        $1 ~ /^[-d][r-][w-][xsS-][r-][w-][xsS-][r-][w-][xtT-]$/ &&
        $2 ~ /^[1-9][0-9]*$/ && $3 ~ /^[0-9]+$/ &&
        $4 ~ /^[0-9]+$/ && $5 ~ /^[0-9]+$/ {
            mode=0
            for (i=2; i<=10; i++) {
                c=substr($1,i,1)
                mode=mode*2 + (c != "-" && c != "S" && c != "T")
            }
            if (substr($1,4,1) ~ /[sS]/) mode+=2048
            if (substr($1,7,1) ~ /[sS]/) mode+=1024
            if (substr($1,10,1) ~ /[tT]/) mode+=512
            value=sprintf("%s %o %s %s", $3, mode, $2, substr($1,1,1)); ok=1
        }
        END { if (NR != 1 || !ok) exit 1; print value }
    '
)
ddnsto_asus_fields() (
    fields=$(_ddnsto_asus_metadata "$@") || return 1
    set -- $fields
    printf '%s %s %s\n' "$1" "$2" "$3"
)
_ddnsto_asus_mounts() { cat /proc/mounts; }
_ddnsto_asus_mkdir() { mkdir -m 700 "$1"; }
ddnsto_asus_anchor() (
    [ "$(ddnsto_asus_uid)" = 0 ] || return 1
    mounts=$(_ddnsto_asus_mounts) || return 1
    printf '%s\n' "$mounts" | LC_ALL=C awk '
        function approved_source(source, fs) {
            if (fs == "ext2" || fs == "ext3" || fs == "ext4")
                return source ~ /^\/dev\/[a-zA-Z0-9_-]+(\/[a-zA-Z0-9_-]+)*$/
            if (fs == "jffs2")
                return source ~ /^\/dev\/mtdblock([0-9]+|\/[0-9]+)$/
            if (fs == "ubifs")
                return source ~ /^\/dev\/ubi[0-9]+_[0-9]+$/ ||
                       source ~ /^ubi[0-9]+:[a-zA-Z0-9_][a-zA-Z0-9_.-]*$/
            return 0
        }
        $2 == "/jffs" {
            count++
            if (NF != 6 || !approved_source($1,$3)) bad=1
            n=split($4,opts,","); rw=0
            for (i=1;i<=n;i++) {
                if (opts[i] == "rw") rw++
                if (opts[i] == "ro" || opts[i] == "noexec" || opts[i] == "bind" || opts[i] == "rbind") bad=1
            }
            if (rw != 1) bad=1
        }
        index($2,"/jffs/") == 1 { bad=1 }
        END { if (count != 1 || bad) exit 1 }
    ' || return 1
    fields=$(_ddnsto_asus_metadata /jffs) || return 1
    set -- $fields
    [ "$1" = 0 ] && [ "$4" = d ] || return 1
    case "$2" in 700|750|755) ;; *) return 1 ;; esac
)
ddnsto_asus_storage() {
    ASUS_STATE=
    ddnsto_asus_anchor || return 1
    if ! _ddnsto_asus_metadata /jffs/.ddnsto-installer >/dev/null 2>&1; then
        (umask 077; _ddnsto_asus_mkdir /jffs/.ddnsto-installer) || return 1
    fi
    _ddnsto_asus_private_existing /jffs/.ddnsto-installer || return 1
    ASUS_STATE=/jffs/.ddnsto-installer
}
_ddnsto_asus_private_existing() (
    fields=$(_ddnsto_asus_metadata "$1") || return 1
    set -- $fields
    [ "$1" = 0 ] && [ "$2" = 700 ] && [ "$4" = d ]
)
_ddnsto_asus_descendant() {
    [ "$#" = 1 ] || return 1
    case "$1" in /jffs/*) ;; *) return 1 ;; esac
    case "$1" in *[!a-zA-Z0-9_./-]*|*/|*//*|*/../*|*/..|*/./*|*/.) return 1 ;; esac
}
ddnsto_asus_safe_ancestors() (
    _ddnsto_asus_descendant "$@" || return 1
    ddnsto_asus_anchor || return 1
    rest=${1#/jffs/} parent=/jffs
    while case "$rest" in */*) true;; *) false;; esac; do
        parent=$parent/${rest%%/*}; rest=${rest#*/}
        fields=$(_ddnsto_asus_metadata "$parent") || return 1
        set -- $fields
        [ "$1" = 0 ] && [ "$4" = d ] || return 1
        case "$2" in 7[0145][0145]) ;; *) return 1 ;; esac
    done
)
_ddnsto_asus_private_path() {
    _ddnsto_asus_descendant "$@" || return 1
    case "$1" in /jffs/.ddnsto-installer|/jffs/.ddnsto-installer/*) ;; *) return 1 ;; esac
    ddnsto_asus_safe_ancestors "$1" || return 1
    _ddnsto_asus_private_existing /jffs/.ddnsto-installer
}
ddnsto_asus_private_dir() (
    _ddnsto_asus_private_path "$@" || return 1
    if ! _ddnsto_asus_metadata "$1" >/dev/null 2>&1; then
        (umask 077; _ddnsto_asus_mkdir "$1") || return 1
    fi
    _ddnsto_asus_private_existing "$1"
)
ddnsto_asus_safe_file() (
    _ddnsto_asus_private_path "$@" || return 1
    fields=$(_ddnsto_asus_metadata "$1") || return 1
    set -- $fields
    [ "$1" = 0 ] && [ "$3" = 1 ] && [ "$4" = - ] || return 1
    case "$2" in [4567][0145][0145]) ;; *) return 1 ;; esac
)
_ddnsto_asus_random() { openssl rand -hex 12; }
ddnsto_asus_mktemp() (
    _ddnsto_asus_private_path "$@" || return 1
    _ddnsto_asus_private_existing "$1" || return 1
    parent=$1 attempt=0
    umask 077
    while [ "$attempt" -lt 8 ]; do
        random=$(_ddnsto_asus_random) || return 1
        [ "${#random}" = 24 ] || return 1
        case "$random" in *[!0-9a-f]*) return 1 ;; esac
        path=$parent/tmp.$random
        if _ddnsto_asus_mkdir "$path" 2>/dev/null; then
            _ddnsto_asus_private_existing "$path" || return 1
            printf '%s\n' "$path"
            return 0
        fi
        attempt=$((attempt + 1))
    done
    return 1
)
_ddnsto_asus_openssl_hash() { openssl dgst -sha256 < "$1"; }
_ddnsto_asus_sha256_hash() { sha256sum < "$1"; }
ddnsto_asus_hash() (
    ddnsto_asus_safe_file "$@" || return 1
    if ddnsto_asus_has openssl; then
        output=$(_ddnsto_asus_openssl_hash "$1") || return 1
        backend=openssl
    elif ddnsto_asus_has sha256sum; then
        output=$(_ddnsto_asus_sha256_hash "$1") || return 1
        backend=sha256sum
    else
        return 1
    fi
    printf '%s\n' "$output" | LC_ALL=C awk -v backend="$backend" '
        NR == 1 && NF == 2 {
            if (backend == "openssl" && ($1 == "SHA256(stdin)=" || $1 == "SHA2-256(stdin)=" || $1 == "(stdin)=")) digest=$2
            if (backend == "sha256sum" && $2 == "-") digest=$1
        }
        END {
            if (NR != 1 || length(digest) != 64 || digest ~ /[^0-9a-fA-F]/) exit 1
            print tolower(digest)
        }
    '
)
_ddnsto_asus_package_tar() { tar "$@"; }
_ddnsto_asus_package_od() { od "$@"; }
_ddnsto_asus_package_has_od() { type od >/dev/null 2>&1; }
_ddnsto_asus_package_capture() (
    ceiling=$1 output=$2; shift 2
    (ulimit -c 0 || exit 1
     ulimit -f "$(((ceiling + 511) / 512))" || exit 1
     _ddnsto_asus_package_tar "$@" > "$output" 2>/dev/null) || return 1
    bytes=$(wc -c < "$output") || return 1
    [ "$bytes" -gt 0 ] && [ "$bytes" -le "$ceiling" ]
)
_ddnsto_asus_package_member() (
    member=$1 output=$2 ceiling=$3
    expected=$(awk -v name="$member" '$6 == name {print $3}' .types) || return 1
    _ddnsto_asus_package_capture "$ceiling" "$output" -xOzf "$archive" "$member" || return 1
    [ "$(wc -c < "$output")" -eq "$expected" ]
)
ddnsto_asus_extract() (
    [ "$#" = 4 ] || return 2
    unset IFS # POSIX default splitting, independent of caller overrides.
    archive=$1 dest=$2 channel=$3 arch=$4
    pins=$(ddnsto_asus_package "$channel") || return 2
    set -f
    set -- $pins
    [ "$#" = 5 ] && [ "$2" = 4.2.8 ] || return 2
    version=$2 marker=$3
    case "$channel:$arch" in
        armsoft:armv7l) binary=ddnsto ;;
        armsoft:*) return 2 ;;
        *:armv7l) binary=ddnsto_arm ;;
        *:aarch64) binary=ddnsto_aarch64 ;;
        *) return 2 ;;
    esac
    for path in "$archive" "$dest"; do
        case "$path" in /*) ;; *) return 2 ;; esac
        case "$path" in /|*/|*//*|*/./*|*/../*|*/.|*/..|*[!a-zA-Z0-9_./+-]*) return 2 ;; esac
        while [ "$path" != / ]; do
            [ ! -L "$path" ] || return 2
            path=${path%/*}; path=${path:-/}
        done
    done
    [ -f "$archive" ] || return 2
    bytes=$(wc -c < "$archive") || return 1
    [ "$bytes" -gt 0 ] && [ "$bytes" -le 12582912 ] || return 1
    LC_ALL=C; export LC_ALL
    unset TAR_OPTIONS GZIP
    umask 077
    mkdir "$dest" || return 1
    cd "$dest" || { rmdir "$dest"; return 1; }
    trap 'rm -f ddnsto Module_ddnsto.asp icon-ddnsto.png .names .types .valid .version; rmdir "$dest"' 0
    trap 'exit 1' 1 2 3 15
    _ddnsto_asus_package_capture 16384 .names -tzf "$archive" || return 1
    _ddnsto_asus_package_capture 16384 .types -tvzf "$archive" || return 1
    LC_ALL=C awk -v channel="$channel" '
        BEGIN {
            split("ddnsto/ ddnsto/webs/ ddnsto/res/ ddnsto/bin/ ddnsto/scripts/", dirs, " ")
            for (i in dirs) want[dirs[i]] = "d"
            split("webs/Module_ddnsto.asp res/icon-ddnsto.png .valid version install.sh uninstall.sh scripts/ddnsto_config.sh scripts/ddnsto_status.sh", files, " ")
            for (i in files) want["ddnsto/" files[i]] = "-"
            if (channel == "armsoft") {
                want["ddnsto/bin/ddnsto"] = "-"
                want["ddnsto/res/ddnsto_check.html"] = "-"
            } else {
                want["ddnsto/bin/ddnsto_arm"] = "-"
                want["ddnsto/bin/ddnsto_aarch64"] = "-"
            }
        }
        NR == FNR {
            if (!($0 in want) || seen[$0]++) bad = 1
            names[FNR] = $0
            count++
            next
        }
        {
            if (NF != 6 || $6 != names[FNR] || substr($1, 1, 1) != want[$6] ||
                length($1) != 10 || $3 !~ /^[0-9]+$/) bad = 1
            ceiling = ($6 ~ /^ddnsto\/bin\/ddnsto/) ? 12582912 : 65536
            if (want[$6] == "d") { if ($3 != 0) bad = 1 }
            else if ($3 < 1 || $3 > ceiling) bad = 1
            total += $3
            types++
        }
        END {
            for (name in want) if (seen[name] != 1) bad = 1
            if (count != 15 || types != count || total > 27262976) bad = 1
            exit bad
        }
    ' .names .types || return 1
    _ddnsto_asus_package_member ddnsto/.valid .valid 64 || return 1
    _ddnsto_asus_package_member ddnsto/version .version 64 || return 1
    printf '%s\n' "$marker" | cmp -s .valid - || return 1
    printf '%s\n' "$version" | cmp -s .version - || return 1
    _ddnsto_asus_package_member "ddnsto/bin/$binary" ddnsto 12582912 || return 1
    _ddnsto_asus_package_member ddnsto/webs/Module_ddnsto.asp Module_ddnsto.asp 65536 || return 1
    _ddnsto_asus_package_member ddnsto/res/icon-ddnsto.png icon-ddnsto.png 65536 || return 1
    if _ddnsto_asus_package_has_od; then
        header=$(_ddnsto_asus_package_od -An -v -tu1 -N20 ddnsto) || return 1
        set -- $header
        [ "$#" = 20 ] || return 1
        [ "$1 $2 $3 $4 $6 $7" = '127 69 76 70 1 1' ] || return 1
        class=$5
        shift 16
        case "$1 $2" in '2 0'|'3 0') ;; *) return 1 ;; esac
        case "$arch:$class:$3:$4" in armv7l:1:40:0|aarch64:2:183:0) ;; *) return 1 ;; esac
    fi
    chmod 700 ddnsto || return 1
    rm -f .names .types .valid .version || return 1
    trap - 0
)
_ddnsto_asus_plugin_files() {
    printf '%s\n' bin/ddnsto scripts/ddnsto_config.sh scripts/ddnsto_status.sh \
        scripts/uninstall_ddnsto.sh init.d/S70ddnsto.sh webs/Module_ddnsto.asp res/icon-ddnsto.png
}
_ddnsto_asus_metadata_keys() {
    printf '%s\n' ddnsto_token ddnsto_enable ddnsto_version ddnsto_client_version \
        softcenter_module_ddnsto_version softcenter_module_ddnsto_install \
        softcenter_module_ddnsto_name softcenter_module_ddnsto_title \
        softcenter_module_ddnsto_description
}
_ddnsto_asus_plugin_cd() {
    case "$1" in bin|scripts|init.d|webs|res) ;; *) return 1 ;; esac
    cd -P /jffs || return 1
    [ ! -L .koolshare ] && cd -P .koolshare || return 1
    [ "$(pwd -P)" = /jffs/.koolshare ] || return 1
    [ ! -L "$1" ] && cd -P "$1" || return 1
    [ "$(pwd -P)" = "/jffs/.koolshare/$1" ]
}
_ddnsto_asus_publish() { mv -f "$1" .; }
_ddnsto_asus_probe_mv() (
    probe="$ASUS_ATTEMPT/mv-probe"
    mkdir "$probe" "$probe/source" "$probe/dest" "$probe/outside" || return 1
    printf probe > "$probe/source/leaf"
    ln -s "$probe/outside" "$probe/dest/leaf" || return 1
    cd -P "$probe/dest" || return 1
    _ddnsto_asus_publish "$probe/source/leaf" || return 1
    [ ! -L leaf ] && [ -f leaf ] && [ "$(cat leaf)" = probe ] || return 1
    [ ! -e "$probe/outside/leaf" ] || return 1
    mkdir "$probe/dest/directory" || return 1
    printf probe > "$probe/source/directory"
    if _ddnsto_asus_publish "$probe/source/directory" 2>/dev/null; then return 1; fi
    [ ! -e "$probe/dest/directory/directory" ]
)
ddnsto_asus_backup_plugin() (
    umask 077
    ddnsto_asus_private_dir "$ASUS_ATTEMPT" || return 1
    mkdir "$ASUS_ATTEMPT/backup" "$ASUS_ATTEMPT/changed" || return 1
    mkdir "$ASUS_ATTEMPT/backup/files" "$ASUS_ATTEMPT/backup/config" || return 1
    _ddnsto_asus_probe_mv || return 1
    for key in $(_ddnsto_asus_metadata_keys); do
        ddnsto_asus_get "$key" > "$ASUS_ATTEMPT/backup/config/$key" || return 1
    done
    for entry in $(_ddnsto_asus_plugin_files); do
        (
            _ddnsto_asus_plugin_cd "${entry%/*}" || exit 1
            leaf=${entry##*/}
            if [ -e "$leaf" ] || [ -L "$leaf" ]; then
                [ -L "$leaf" ] || [ -f "$leaf" ] || exit 1
                cp -pP "$leaf" "$ASUS_ATTEMPT/backup/files/$leaf" || exit 1
                [ -L "$ASUS_ATTEMPT/backup/files/$leaf" ] ||
                    ddnsto_asus_safe_file "$ASUS_ATTEMPT/backup/files/$leaf" || exit 1
            fi
        ) || return 1
    done
    if [ -L "$ASUS_STATE/current" ]; then
        previous=$(readlink -f "$ASUS_STATE/current") || return 1
        case "$previous" in "$ASUS_STATE"/*/runtime) ;; *) return 1 ;; esac
        ddnsto_asus_safe_file "$previous/ddnsto" &&
            ddnsto_asus_safe_file "$previous/service.sh" || return 1
        cp -pP "$ASUS_STATE/current" "$ASUS_ATTEMPT/backup/current" || return 1
    elif [ -e "$ASUS_STATE/current" ]; then return 1
    fi
    if [ ! -L "$ASUS_ATTEMPT/backup/current" ] &&
        [ "$(cat "$ASUS_ATTEMPT/backup/config/ddnsto_enable")" = 1 ]; then
        old="$ASUS_ATTEMPT/backup/files/ddnsto"
        ddnsto_asus_safe_file "$old" && cmp -s "$old" "$ASUS_ATTEMPT/payload/ddnsto" || {
            printf '%s\n' 'ASUS: enabled native binary is not reviewed recovery material' >&2
            return 1
        }
    fi
    _ddnsto_asus_prepare_runtime || return 1
    : > "$ASUS_ATTEMPT/backup/complete"
)
_ddnsto_asus_runtime() {
    cat <<'ASUS_RUNTIME'
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
unset ENV BASH_ENV CDPATH
umask 077
service_binary=/jffs/.ddnsto-installer/current/ddnsto
asus_service_get() { /usr/bin/dbus get "$1"; }
asus_service_identity() (
    case "$1" in ''|*[!0-9]*|0|1) exit 1 ;; esac
    target=$(readlink "/proc/$1/exe") || exit 1
    case "$target" in
        /.koolshare/bin/ddnsto|/jffs/.koolshare/bin/ddnsto)
            [ "${2:-}" = legacy ] || exit 1 ;;
        *) wanted=$(readlink -f "$service_binary") || exit 1
            [ "$target" = "$wanted" ] || exit 1 ;;
    esac
    role=$(awk '
        $1=="Uid:" {u++; if (NF!=5 || $2!=0 || $3!=0 || $4!=0 || $5!=0) bad=1}
        $1=="PPid:" {p++; parent=$2}
        END {if (u!=1 || p!=1 || bad || parent !~ /^[0-9]+$/) exit 1; print parent}
    ' "/proc/$1/status") || exit 1
    birth=$(sed 's/^.*) //' "/proc/$1/stat" | awk 'NF>=20 && $20 ~ /^[0-9]+$/ {print $20}')
    [ -n "$birth" ] || exit 1
    printf '%s:%s:%s\n' "$target" "$role" "$birth"
)
asus_service_main() {
    main=
    for pid in $(pidof ddnsto 2>/dev/null); do
        ident=$(asus_service_identity "$pid") || return 1
        case "$ident" in *:1:*)
            [ -z "$main" ] || return 1
            main=$pid; main_identity=$ident ;;
        esac
    done
    [ -n "$main" ]
}
asus_service_running() {
    asus_service_main || return 1
    stable_pid=$main stable_identity=$main_identity
    for probe in 2 3; do
        sleep 1
        asus_service_main || return 1
        [ "$main" = "$stable_pid" ] && [ "$main_identity" = "$stable_identity" ] || return 1
    done
}
asus_service_stop() {
    mains= children=
    for pid in $(pidof ddnsto 2>/dev/null); do
        ident=$(asus_service_identity "$pid" "${1:-}") || continue
        case "$ident" in *:1:*) mains="$mains $pid" ;; *) children="$children $pid" ;; esac
    done
    for pid in $mains $children; do
        ident=$(asus_service_identity "$pid" "${1:-}") || continue
        [ "$(asus_service_identity "$pid" "${1:-}")" = "$ident" ] || return 1
        kill -TERM "$pid" 2>/dev/null || {
            [ "$(asus_service_identity "$pid" "${1:-}")" != "$ident" ] || return 1
        }
    done
    for probe in 1 2 3 4 5; do
        remaining=0
        for pid in $(pidof ddnsto 2>/dev/null); do remaining=1; done
        [ "$remaining" = 0 ] && return 0
        sleep 1
    done
    return 1
}
asus_service_start() {
    [ "$(asus_service_get ddnsto_enable)" = 1 ] || return 0
    asus_service_main && return 0
    [ -z "$(pidof ddnsto 2>/dev/null)" ] || return 1
    token=$(asus_service_get ddnsto_token) || return 1
    case "$token" in ''|*[!a-zA-Z0-9_-]*) return 1 ;; esac
    enabled=$(asus_service_get ddnsto_feat_enabled) || return 1
    user=$(asus_service_get ddnsto_feat_username) || return 1
    pass=$(asus_service_get ddnsto_feat_password) || return 1
    port=$(asus_service_get ddnsto_feat_port) || return 1
    disk=$(asus_service_get ddnsto_feat_disk_path_selected) || return 1
    set -- -u "$token" -d
    if [ "$enabled" = 1 ] && [ -n "$user" ] && [ -n "$pass" ] && [ -n "$port" ]; then
        case "$port" in *[!0-9]*|'') return 1 ;; esac
        [ "${#port}" -le 5 ] && [ "$port" -gt 0 ] && [ "$port" -le 65535 ] || return 1
        set -- "$@" -n "$user" -k "$pass" -p "$port" -s "${disk:-/}"
    fi
    "$service_binary" "$@" >/dev/null 2>&1
}
asus_service_json() {
    LC_ALL=C awk 'BEGIN {printf "\""; for(i=1;i<32;i++) ctrl[sprintf("%c",i)]=i}
        {if(NR>1) printf "\\n"; for(i=1;i<=length($0);i++) {
            c=substr($0,i,1)
            if(c=="\\" || c=="\"") printf "\\%s",c
            else if(c in ctrl) printf "\\u%04x",ctrl[c]
            else printf "%s",c
        }} END {printf "\""}'
}
asus_service_response() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#1}" -le 16 ] || return 1
    curl --noproxy '*' --connect-timeout 2 --max-time 5 -fsS \
        -H 'Content-Type: application/json' --data-binary "$2" \
        "http://127.0.0.1:3030/_resp/$1" >/dev/null
}
asus_service_router_id() (
    query=/jffs/.ddnsto-installer/router-query.lock
    mkdir -m 700 "$query" 2>/dev/null || exit 1
    child=
    cleanup_query() {
        if [ -n "$child" ]; then
            kill -KILL "$child" 2>/dev/null || :
            wait "$child" 2>/dev/null || :
        fi
        rm -f "$query/output"
        rmdir "$query" 2>/dev/null || :
    }
    trap cleanup_query 0
    trap 'exit 1' 1 2 3 15
    (ulimit -c 0 && ulimit -f 1 && exec "$service_binary" -w) > "$query/output" 2>/dev/null &
    child=$!
    for probe in 1 2 3; do
        sleep 1
        kill -0 "$child" 2>/dev/null || break
    done
    if kill -0 "$child" 2>/dev/null; then exit 1; fi
    wait "$child" 2>/dev/null; result=$?
    child=
    [ "$result" = 0 ] || exit 1
    [ "$(wc -c < "$query/output")" -le 128 ] || exit 1
    LC_ALL=C awk '
        NR==1 && NF==2 && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+$/ &&
            length($2)==12 && $2 ~ /^[0-9a-f]+$/ { id=$2; valid=1 }
        END { if(NR!=1 || !valid) exit 1; print id }
    ' "$query/output"
)
asus_service_plugin_cd() {
    case "$1" in bin|scripts|init.d|webs|res) ;; *) return 1 ;; esac
    cd -P /jffs || return 1
    [ ! -L .koolshare ] && cd -P .koolshare || return 1
    [ "$(pwd -P)" = /jffs/.koolshare ] || return 1
    [ ! -L "$1" ] && cd -P "$1" || return 1
    [ "$(pwd -P)" = "/jffs/.koolshare/$1" ]
}
asus_service_owned_leaf() {
    case "$1" in Module_ddnsto.asp|icon-ddnsto.png)
        [ ! -L "./$1" ] && [ -f "./$1" ] &&
            cmp -s "./$1" "/jffs/.ddnsto-installer/current/$1" ;;
        *) [ -L "./$1" ] &&
            [ "$(readlink "./$1")" = "/jffs/.ddnsto-installer/current/$1" ] ;;
    esac
}
asus_service_uninstall() {
    owned='bin/ddnsto scripts/ddnsto_config.sh scripts/ddnsto_status.sh scripts/uninstall_ddnsto.sh init.d/S70ddnsto.sh webs/Module_ddnsto.asp res/icon-ddnsto.png'
    for entry in $owned; do
        (asus_service_plugin_cd "${entry%/*}" &&
            asus_service_owned_leaf "${entry##*/}") || {
            printf '%s\n' 'ASUS: uninstall refused: plugin file ownership changed' >&2
            return 1
        }
    done
    asus_service_stop || return 1
    for entry in $owned; do
        (
            asus_service_plugin_cd "${entry%/*}" || exit 1
            leaf=${entry##*/}
            asus_service_owned_leaf "$leaf" || exit 1
            rm -f "./$leaf"
        ) || return 1
    done
    for key in ddnsto_token ddnsto_enable ddnsto_version ddnsto_client_version \
        ddnsto_feat_enabled ddnsto_feat_username ddnsto_feat_password \
        ddnsto_feat_port ddnsto_feat_disk_path_selected \
        softcenter_module_ddnsto_version softcenter_module_ddnsto_install \
        softcenter_module_ddnsto_name softcenter_module_ddnsto_title \
        softcenter_module_ddnsto_description; do
        /usr/bin/dbus remove "$key" || return 1
    done
}
asus_service_status() {
    request=$1
    case "$request" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#request}" -le 16 ] || return 1
    state=0 feat=0 pidtext=
    if asus_service_main; then
        state=1; pidtext=$main
        for pid in $(pidof ddnsto 2>/dev/null); do
            ident=$(asus_service_identity "$pid") || continue
            case "$ident" in *:"$main":*) feat=1 ;; esac
        done
    fi
    version=$(asus_service_get ddnsto_version | asus_service_json) || return 1
    username=$(asus_service_get ddnsto_feat_username | asus_service_json) || return 1
    port=$(asus_service_get ddnsto_feat_port | asus_service_json) || return 1
    router_id=$(asus_service_router_id) || router_id=
    asus_service_response "$request" "{\"version\":$version,\"status\":$state,\"router_id\":\"$router_id\",\"pid\":\"$pidtext\",\"feat\":{\"status\":\"$feat\",\"username\":$username,\"port\":$port,\"disk_path\":\"/webdav/\"}}"
}
case "${1:-}" in
    start|stop|config|uninstall)
        mkdir -m 700 /jffs/.ddnsto-installer/install.lock 2>/dev/null || exit 16
        trap 'rmdir /jffs/.ddnsto-installer/install.lock 2>/dev/null || :' 0
        trap 'exit 1' 1 2 3 15 ;;
esac
case "${1:-}" in
    library) ;; # private installer/test source use; performs no action
    start|installer-start) asus_service_start ;;
    stop) asus_service_stop ;;
    migrate-stop) asus_service_stop legacy ;;
    running) asus_service_running ;;
    status) asus_service_status "${2:-}" ;;
    uninstall) asus_service_uninstall ;;
    config)
        case "${2:-}" in ''|*[!0-9]*) exit 2 ;; esac
        [ "${#2}" -le 16 ] || exit 2
        result=0
        asus_service_stop && asus_service_start || result=1
        asus_service_response "$2" "$2" || exit 1
        exit "$result" ;;
    *) exit 2 ;;
esac
ASUS_RUNTIME
}
_ddnsto_asus_prepare_runtime() (
    umask 077
    mkdir "$ASUS_ATTEMPT/runtime" || return 1
    ddnsto_asus_safe_file "$ASUS_ATTEMPT/payload/ddnsto" || return 1
    cp "$ASUS_ATTEMPT/payload/ddnsto" "$ASUS_ATTEMPT/runtime/ddnsto" || return 1
    chmod 700 "$ASUS_ATTEMPT/runtime/ddnsto" || return 1
    _ddnsto_asus_runtime > "$ASUS_ATTEMPT/runtime/service.sh" || return 1
    chmod 700 "$ASUS_ATTEMPT/runtime/service.sh" || return 1
    pins=$(ddnsto_asus_package "$ASUS_CHANNEL") || return 1
    printf '%s\n' "$pins" > "$ASUS_ATTEMPT/runtime/source-pin" || return 1
    digest=$(ddnsto_asus_hash "$ASUS_ATTEMPT/runtime/ddnsto") || return 1
    printf '%s\n' "$digest" > "$ASUS_ATTEMPT/runtime/binary.sha256" || return 1
)
ddnsto_asus_reusable() (
    [ "$(ddnsto_asus_get ddnsto_version)" = 4.2.8 ] || return 1
    [ -L "$ASUS_STATE/current" ] || return 1
    runtime=$(readlink -f "$ASUS_STATE/current") || return 1
    case "$runtime" in "$ASUS_STATE"/*/runtime) ;; *) return 1 ;; esac
    for name in ddnsto service.sh source-pin binary.sha256 \
        ddnsto_config.sh ddnsto_status.sh uninstall_ddnsto.sh S70ddnsto.sh \
        Module_ddnsto.asp icon-ddnsto.png; do
        ddnsto_asus_safe_file "$runtime/$name" || return 1
    done
    [ -x "$runtime/ddnsto" ] || return 1
    pins=$(ddnsto_asus_package "$ASUS_CHANNEL") || return 1
    printf '%s\n' "$pins" | cmp -s "$runtime/source-pin" - || return 1
    digest=$(ddnsto_asus_hash "$runtime/ddnsto") || return 1
    printf '%s\n' "$digest" | cmp -s "$runtime/binary.sha256" - || return 1
    _ddnsto_asus_runtime | cmp -s "$runtime/service.sh" - || return 1
    for kind in config status uninstall init; do
        case "$kind" in config) leaf=ddnsto_config.sh ;; status) leaf=ddnsto_status.sh ;;
            uninstall) leaf=uninstall_ddnsto.sh ;; init) leaf=S70ddnsto.sh ;; esac
        _ddnsto_asus_bridge "$kind" | cmp -s "$runtime/$leaf" - || return 1
    done
    for entry in $(_ddnsto_asus_plugin_files); do
        (
            _ddnsto_asus_plugin_cd "${entry%/*}" || exit 1
            leaf=${entry##*/}
            case "$leaf" in Module_ddnsto.asp|icon-ddnsto.png)
                [ ! -L "$leaf" ] && [ -f "$leaf" ] && cmp -s "$leaf" "$runtime/$leaf" ;;
                *) [ -L "$leaf" ] && [ "$(readlink "$leaf")" = "$ASUS_STATE/current/$leaf" ] ;;
            esac
        ) || return 1
    done
)
_ddnsto_asus_bridge() {
    printf '%s\n' '#!/bin/sh' 'PATH=/usr/sbin:/usr/bin:/sbin:/bin' 'export PATH' \
        'unset ENV BASH_ENV CDPATH'
    case "$1" in
        config) printf '%s\n' 'case "${1:-}" in start|stop) action=$1; shift ;; *) action=config ;; esac' \
            'exec /bin/sh /jffs/.ddnsto-installer/current/service.sh "$action" "$@"' ;;
        status) printf '%s\n' 'exec /bin/sh /jffs/.ddnsto-installer/current/service.sh status "$@"' ;;
        uninstall) printf '%s\n' 'exec /bin/sh /jffs/.ddnsto-installer/current/service.sh uninstall' ;;
        init) printf '%s\n' 'case "${1:-start}" in start|stop) ;; *) exit 2 ;; esac' \
            'exec /bin/sh /jffs/.ddnsto-installer/current/service.sh "${1:-start}"' ;;
    esac
}
ddnsto_asus_install_plugin() (
    umask 077
    [ -f "$ASUS_ATTEMPT/backup/complete" ] || return 1
    ddnsto_asus_safe_file "$ASUS_ATTEMPT/runtime/ddnsto" &&
        ddnsto_asus_safe_file "$ASUS_ATTEMPT/runtime/service.sh" || return 1
    for name in Module_ddnsto.asp icon-ddnsto.png; do
        ddnsto_asus_safe_file "$ASUS_ATTEMPT/payload/$name" || return 1
        cp "$ASUS_ATTEMPT/payload/$name" "$ASUS_ATTEMPT/runtime/$name" || return 1
        chmod 644 "$ASUS_ATTEMPT/runtime/$name" || return 1
    done
    _ddnsto_asus_bridge config > "$ASUS_ATTEMPT/runtime/ddnsto_config.sh" || return 1
    _ddnsto_asus_bridge status > "$ASUS_ATTEMPT/runtime/ddnsto_status.sh" || return 1
    _ddnsto_asus_bridge init > "$ASUS_ATTEMPT/runtime/S70ddnsto.sh" || return 1
    _ddnsto_asus_bridge uninstall > "$ASUS_ATTEMPT/runtime/uninstall_ddnsto.sh" || return 1
    chmod 755 "$ASUS_ATTEMPT/runtime/ddnsto_config.sh" \
        "$ASUS_ATTEMPT/runtime/ddnsto_status.sh" "$ASUS_ATTEMPT/runtime/S70ddnsto.sh" \
        "$ASUS_ATTEMPT/runtime/uninstall_ddnsto.sh" || return 1
    mkdir "$ASUS_ATTEMPT/publish" || return 1
    ln -s "$ASUS_ATTEMPT/runtime" "$ASUS_ATTEMPT/publish/current" || return 1
    : > "$ASUS_ATTEMPT/changed/current"
    (cd -P "$ASUS_STATE" && _ddnsto_asus_publish "$ASUS_ATTEMPT/publish/current") || return 1
    for entry in $(_ddnsto_asus_plugin_files); do
        (
            _ddnsto_asus_plugin_cd "${entry%/*}" || exit 1
            leaf=${entry##*/}
            case "$leaf" in Module_ddnsto.asp|icon-ddnsto.png)
                cp "$ASUS_ATTEMPT/runtime/$leaf" "$ASUS_ATTEMPT/publish/$leaf" || exit 1
                chmod 644 "$ASUS_ATTEMPT/publish/$leaf" || exit 1 ;;
                *) ln -s "$ASUS_STATE/current/$leaf" "$ASUS_ATTEMPT/publish/$leaf" || exit 1 ;;
            esac
            : > "$ASUS_ATTEMPT/changed/$leaf"
            _ddnsto_asus_publish "$ASUS_ATTEMPT/publish/$leaf"
        ) || return 1
    done
    for key in ddnsto_version ddnsto_client_version softcenter_module_ddnsto_version \
        softcenter_module_ddnsto_install softcenter_module_ddnsto_name \
        softcenter_module_ddnsto_title softcenter_module_ddnsto_description; do
        case "$key" in
            *_version) value=4.2.8 ;; *_install) value=1 ;;
            *_name) value=ddnsto ;; *_title) value=DDNSTO ;;
            *_description) value='DDNSTO remote access' ;;
        esac
        : > "$ASUS_ATTEMPT/changed/$key"
        ddnsto_asus_set "$key" "$value" || return 1
    done
)
_ddnsto_asus_service_call() (
    umask 077
    ddnsto_asus_private_dir "$ASUS_ATTEMPT" || return 1
    runner=$(ddnsto_asus_mktemp "$ASUS_ATTEMPT") || return 1
    _ddnsto_asus_runtime > "$runner/service.sh" || return 1
    /bin/sh "$runner/service.sh" "$1"
)
ddnsto_asus_stop() { _ddnsto_asus_service_call migrate-stop; }
ddnsto_asus_start() { _ddnsto_asus_service_call installer-start; }
ddnsto_asus_running() { _ddnsto_asus_service_call running; }
ddnsto_asus_restore_plugin() (
    umask 077
    [ -f "$ASUS_ATTEMPT/backup/complete" ] || return 1
    ddnsto_asus_stop || return 1
    restore=$(ddnsto_asus_mktemp "$ASUS_ATTEMPT") || return 1
    for entry in $(_ddnsto_asus_plugin_files); do
        (
            leaf=${entry##*/}
            [ -f "$ASUS_ATTEMPT/changed/$leaf" ] || exit 0
            _ddnsto_asus_plugin_cd "${entry%/*}" || exit 1
            saved="$ASUS_ATTEMPT/backup/files/$leaf"
            if [ -e "$saved" ] || [ -L "$saved" ]; then
                cp -pP "$saved" "$restore/$leaf" || exit 1
                _ddnsto_asus_publish "$restore/$leaf" || exit 1
            else
                rm -f "./$leaf" || exit 1
            fi
        ) || return 1
    done
    recovery_conflict=0
    for key in $(_ddnsto_asus_metadata_keys); do
        [ -f "$ASUS_ATTEMPT/changed/$key" ] || continue
        case "$key" in ddnsto_token|ddnsto_enable)
            expected=$(cat "$ASUS_ATTEMPT/changed/$key") || return 1
            live=$(ddnsto_asus_get "$key") || return 1
            if [ "$live" != "$expected" ]; then
                recovery_conflict=1
                continue
            fi ;;
        esac
        value=$(cat "$ASUS_ATTEMPT/backup/config/$key") || return 1
        ddnsto_asus_set "$key" "$value" || return 1
    done
    if [ -f "$ASUS_ATTEMPT/changed/current" ]; then
        if [ -L "$ASUS_ATTEMPT/backup/current" ]; then
            cp -pP "$ASUS_ATTEMPT/backup/current" "$restore/current" || return 1
            (cd -P "$ASUS_STATE" && _ddnsto_asus_publish "$restore/current") || return 1
        elif [ "$(cat "$ASUS_ATTEMPT/backup/config/ddnsto_enable")" != 1 ]; then
            rm -f "$ASUS_STATE/current" || return 1
        fi
    fi
    if [ "$recovery_conflict" = 1 ]; then
        printf '%s\n' 'ASUS: recovery refused: concurrent account/enable change; external values preserved' >&2
        return 1
    fi
    if [ "$(cat "$ASUS_ATTEMPT/backup/config/ddnsto_enable")" = 1 ]; then
        if [ ! -L "$ASUS_STATE/current" ]; then
            ln -s "$ASUS_ATTEMPT/runtime" "$restore/current" || return 1
            (cd -P "$ASUS_STATE" && _ddnsto_asus_publish "$restore/current") || return 1
        fi
        ddnsto_asus_start && ddnsto_asus_running || return 1
    fi
)
ddnsto_asus_identity() {
    if [ "$#" = 2 ]; then
        asus_existing_token=$1 asus_version=$2
    else
        asus_existing_token=$(ddnsto_asus_get ddnsto_token) || return 2
        asus_version=$(ddnsto_asus_get ddnsto_version) || return 2
    fi
    [ -z "$asus_existing_token" ] || [ "$asus_existing_token" = "$TOKEN" ] || {
        ddnsto_flow_error E_ACCOUNT '插件属于其他账号，未执行换绑' '请使用原账号重新复制命令'; return 2;
    }
    if [ -n "$asus_version" ]; then
        asus_order=$(ddnsto_version_order "$asus_version" 4.2.8) || asus_order=unknown
        case "$asus_order" in -1|0) ;; *)
            ddnsto_flow_error E_VERSION '插件版本更新或无法识别，未覆盖现有版本' '请使用对应版本安装器；不会降级'; return 2 ;;
        esac
        [ -n "$asus_existing_token" ] || {
            ddnsto_flow_error E_ACCOUNT '已安装插件缺少账号信息，未修改配置' '请先在软件中心检查 Token'; return 2;
        }
    fi
}
ddnsto_asus_checkpoint() {
    [ -z "${ASUS_CANCEL:-}" ] || [ ! -f "$ASUS_CANCEL" ] || {
        ddnsto_flow_error E_CANCELLED '安装已取消，正在完成必要恢复' '请等待当前命令结束后检查状态'; return 143;
    }
}
ddnsto_asus_snapshot_config() {
    mkdir "$ASUS_ATTEMPT/config" || return 12
    for key in ddnsto_token ddnsto_enable ddnsto_version ddnsto_client_version \
        ddnsto_feat_enabled ddnsto_feat_username ddnsto_feat_password \
        ddnsto_feat_port ddnsto_feat_disk_path_selected; do
        ddnsto_asus_get "$key" > "$ASUS_ATTEMPT/config/$key" || return 12
    done
}
ddnsto_asus_config_unchanged() {
    for key in ddnsto_token ddnsto_enable ddnsto_version ddnsto_client_version \
        ddnsto_feat_enabled ddnsto_feat_username ddnsto_feat_password \
        ddnsto_feat_port ddnsto_feat_disk_path_selected; do
        ddnsto_asus_get "$key" > "$ASUS_ATTEMPT/compare" || return 12
        cmp -s "$ASUS_ATTEMPT/config/$key" "$ASUS_ATTEMPT/compare" || return 2
    done
}
ddnsto_asus_ensure_locked() (
    umask 077
    ddnsto_asus_preflight || exit $?
    case "$TOKEN" in ''|*[!a-zA-Z0-9_-]*)
        ddnsto_flow_error E_TOKEN 'Token 格式无效' '请从控制台重新复制'; exit 2 ;;
    esac
    ddnsto_asus_busy || { ddnsto_flow_error E_BUSY '软件中心正在安装其他插件' '请等待软件中心任务结束'; exit 16; }
    ddnsto_asus_identity || exit $?
    ASUS_ATTEMPT=$(ddnsto_asus_mktemp "$ASUS_STATE") || exit 12
    ddnsto_asus_snapshot_config || exit $?
    ddnsto_asus_identity "$(cat "$ASUS_ATTEMPT/config/ddnsto_token")" "$(cat "$ASUS_ATTEMPT/config/ddnsto_version")" || exit $?
    ddnsto_asus_checkpoint || exit $?
    if [ "$asus_version" = 4.2.8 ] && [ "$(cat "$ASUS_ATTEMPT/config/ddnsto_enable")" = 1 ] &&
        ddnsto_asus_reusable && ddnsto_asus_running; then
        ddnsto_asus_config_unchanged && ddnsto_asus_checkpoint || exit 2
        ddnsto_flow_note installed
        ddnsto_flow_note starting
        ddnsto_flow_note started
        exit 0
    fi
    ddnsto_asus_fetch "$ASUS_ATTEMPT/package.tar.gz" || {
        ddnsto_flow_error E_DOWNLOAD '插件下载或校验失败，现有服务未停止' '请检查 HTTPS 下载后重试'; exit 11;
    }
    ddnsto_asus_extract "$ASUS_ATTEMPT/package.tar.gz" "$ASUS_ATTEMPT/payload" "$ASUS_CHANNEL" "$ASUS_ARCH" || {
        ddnsto_flow_error E_PACKAGE '插件包结构或平台标记不符合审核记录' '请联系发布者检查安装包，未执行包内脚本'; exit 11;
    }
    ddnsto_asus_checkpoint || exit $?
    ddnsto_asus_busy && ddnsto_asus_config_unchanged || {
        ddnsto_flow_error E_CONFIG '下载期间软件中心或配置发生变化' '请稍后重新执行，未覆盖修改'; exit 2;
    }
    ddnsto_asus_backup_plugin || {
        ddnsto_flow_error E_BACKUP '无法安全备份现有插件' '请检查存储和插件文件，未停止服务'; exit 12;
    }
    changed=0
    finish_asus() {
        result=$?
        trap - EXIT HUP INT TERM
        if [ "$result" != 0 ] && [ "$changed" = 1 ]; then
            if ! ddnsto_asus_restore_plugin; then
                ddnsto_flow_error E_RECOVERY '安装失败且恢复未完成，已保留私有备份' "请检查 $ASUS_ATTEMPT" || :
            fi
        fi
        exit "$result"
    }
    trap finish_asus EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    ddnsto_asus_checkpoint || exit $?
    ddnsto_flow_note installing
    changed=1
    ddnsto_asus_stop || { ddnsto_flow_error E_STOP '未确认旧进程停止，未覆盖文件' '请检查客户端进程'; exit 13; }
    ddnsto_asus_install_plugin || {
        ddnsto_flow_error E_PACKAGE '插件文件安装失败，正在尝试恢复' "备份位于 $ASUS_ATTEMPT"; exit 11;
    }
    ddnsto_asus_checkpoint || exit $?
    [ "$(ddnsto_asus_get ddnsto_token)" = "$asus_existing_token" ] || {
        ddnsto_flow_error E_ACCOUNT '安装期间账号发生变化，不覆盖新配置' '请检查软件中心账号后重试'; exit 2;
    }
    if [ -z "$asus_existing_token" ]; then
        printf '%s' "$TOKEN" > "$ASUS_ATTEMPT/changed/ddnsto_token" || exit 12
        ddnsto_asus_set ddnsto_token "$TOKEN" || exit 12
    fi
    printf '1' > "$ASUS_ATTEMPT/changed/ddnsto_enable" || exit 12
    ddnsto_asus_set ddnsto_enable 1 || exit 12
    [ "$(ddnsto_asus_get ddnsto_token)" = "$TOKEN" ] || {
        ddnsto_flow_error E_ACCOUNT '启动前账号发生变化，不覆盖新配置' '请停止并发修改后重试'; exit 2;
    }
    ddnsto_flow_note installed
    ddnsto_flow_note starting
    ddnsto_asus_start && ddnsto_asus_running || {
        ddnsto_flow_error E_START '插件安装后未确认稳定启动，正在尝试恢复' "请检查私有备份 $ASUS_ATTEMPT"; exit 13;
    }
    ddnsto_asus_checkpoint || exit $?
    [ "$(ddnsto_asus_get ddnsto_token)" = "$TOKEN" ] || {
        ddnsto_flow_error E_ACCOUNT '启动期间账号发生变化，不能确认安装成功' '请停止并发修改后检查软件中心配置'; exit 2;
    }
    changed=0
    ddnsto_flow_note started
)
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
installer_dispatch ddnsto "$@"
ZSETUP_PRIVATE_ROOT_PROGRAM
}

bootstrap_and_run() {
    status "[1/4] Checking zsetup..."
    ddnsto_bootstrap_zsetup || {
        bootstrap_rc=$?
        ddnsto_flow_error E_BOOTSTRAP 'zsetup 下载、校验或缓存检查失败，尚未安装客户端' '请检查 HTTPS 下载连通性、系统时间、SHA-256 工具及私有缓存权限；不要删除客户端配置' || :
        return "$bootstrap_rc"
    }
    status "      zsetup $RESCUE_VERSION is ready"
    ZSETUP_BIN=$ACTIVE_ZSETUP
    ZSETUP_SOURCE_BASES=${ZSETUP_SOURCE_BASES:-$DIRECT_PRIMARY_BASES}
    ZSETUP_SOURCE_FALLBACK=${ZSETUP_SOURCE_FALLBACK-$DIRECT_FALLBACK_BASE}
    export ZSETUP_BIN ZSETUP_ARCH ZSETUP_SOURCE_BASES ZSETUP_SOURCE_FALLBACK
    installer_dispatch ddnsto "$@"
}

# installer_dispatch parses shared options before this business preflight.
ddnsto_entry_install() {
    case "${1:-}" in --help|-h) ddnsto_usage; return 0 ;; esac
    ddnsto_parse_args "$@" || return $?
    if [ "${ZSETUP_INSTALLER_MODE:-0}" = 1 ] && [ "$PLAN_ONLY" = 0 ]; then
        os=${ZSETUP_OS:-$("$ZSETUP_BIN" context get os)}
        package_manager=${ZSETUP_PACKAGE_MANAGER:-$("$ZSETUP_BIN" context get package_manager)}
        ddnsto_detect_platform || return $?
    else
        ddnsto_local_platform || return $?
    fi
    ddnsto_validate_platform_options || return $?
    if [ "$ACTION" = ensure ] && [ "$PLAN_ONLY" = 0 ]; then
        if [ "$detected_platform" = synology ] && [ "$(id -u)" != 0 ]; then
            # Recommendation entry is already a verified private file. DSM
            # administrators authorize the same file; never download it again.
            [ -f "$0" ] && command -v sudo >/dev/null 2>&1 || {
                ddnsto_flow_error E_PRIVILEGE '群晖自动安装需要管理员权限及本地脚本文件' '请 sudo -i 后重新执行控制台命令'; return 2;
            }
            printf '%s\n' 'DDNSTO：需要 DSM 管理员权限，请按提示输入当前用户的密码。' >&2
            sudo -v || {
                ddnsto_flow_error E_PRIVILEGE '未取得 DSM 管理员授权，尚未修改套件' '请在交互式 SSH 终端输入当前管理员密码，或 sudo -i 后重试'; return 2;
            }
            sudo -n -- sh "$0" "$@"
            return $?
        fi
        ddnsto_ensure_entry "$@"
        return $?
    fi
    if [ "$REQUESTED_METHOD" = docker ]; then
        if [ "$PLAN_ONLY" = 1 ]; then ddnsto_docker_plan
        elif [ "$ACTION" = status ]; then ddnsto_docker_lifecycle
        else ddnsto_docker_locked; fi
        return $?
    fi
    if [ "$PLAN_ONLY" = 1 ]; then ddnsto_plan; return $?; fi
    if [ "$detected_platform" = synology ]; then
        ddnsto_synology_entry
        return $?
    fi
    case "$detected_platform" in linux|openwrt) ;; *) ddnsto_error 'native installation unavailable for this device'; return 2 ;; esac
    case "$ACTION" in
        status|start|stop|restart|repair|configure|uninstall)
            if [ "$detected_platform" = openwrt ]; then
                if [ "$ACTION" = status ]; then ddnsto_openwrt_local
                else ddnsto_machine_locked ddnsto_openwrt_local; fi
                return $?
            fi
            ddnsto_managed_native || return $?
            ddnsto_managed_action
            return $? ;;
    esac
    # Preserve shared directory choices when bootstrap dispatches a second time.
    ZSETUP_INSTALL_SCOPE=${installer_scope:-system}
    ZSETUP_INSTALL_PREFIX=${installer_prefix:-}
    [ -z "${installer_work_dir:-}" ] || ZSETUP_WORK_DIR=$installer_work_dir
    export ZSETUP_INSTALL_SCOPE ZSETUP_INSTALL_PREFIX
    [ -z "${ZSETUP_WORK_DIR:-}" ] || export ZSETUP_WORK_DIR
    if [ "${ZSETUP_INSTALLER_MODE:-0}" = 1 ]; then
        ddnsto_install "$@"
    else
        bootstrap_and_run "$@"
    fi
}

main() {
    case "${1:-}" in --help|-h) ddnsto_usage; return 0 ;; esac
    if [ "${0##*/}" = setup_ddnsto.sh ]; then
        [ "$#" -ge 1 ] && [ -n "$1" ] || { ddnsto_error 'Usage: setup_ddnsto.sh TOKEN'; return 2; }
        setup_token=$1; shift
        set -- --token "$setup_token" "$@"
    fi
    installer_dispatch ddnsto-entry "$@"
}
main "$@"
