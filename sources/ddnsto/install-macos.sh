#!/bin/sh
# Generated from templates/install-macos.sh.in and platform-releases.json; edit those sources, then run scripts/build-entrypoints.py.
# Engineering candidate: bootstraps zsetup automatically; native canary pending.
set -eu
set +x
umask 077
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
    command -v sha256sum >/dev/null 2>&1 || command -v openssl >/dev/null 2>&1 ||
        command -v shasum >/dev/null 2>&1
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
    elif command -v shasum >/dev/null 2>&1; then
        actual=$(shasum -a 256 "$1")
        actual=${actual%% *}
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

# Return the verified native path while confining bootstrap's temporary signal
# traps to a subprocess. Long-running installers can call this after installing
# their own transaction cleanup traps without losing those handlers.
bootstrap_zsetup_path() (
    bootstrap_zsetup
    printf '%s\n' "$ACTIVE_ZSETUP"
)
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
BUSINESS_ENV=production
SWITCH_ENVIRONMENT=0
mac_plist_env=production
environment_change=0
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
        --token|--token-file|--version|--platform|--method|--action|--env)
            [ "$#" -ge 2 ] || fail 'argument requires a value'
            case "$1" in --token) TOKEN=$2 ;; --token-file) TOKEN_FILE=$2 ;;
                --platform) REQUESTED_PLATFORM=$2 ;; --method) REQUESTED_METHOD=$2 ;;
                --action) ACTION=$2 ;; --env) BUSINESS_ENV=$2 ;; *) VERSION=$2 ;; esac
            shift 2 ;;
        --token=*) TOKEN=${1#--token=}; shift ;;
        --env=*) BUSINESS_ENV=${1#--env=}; shift ;;
        --switch-environment) SWITCH_ENVIRONMENT=1; shift ;;
        --plan) PLAN_ONLY=1; shift ;;
        --help|-h) printf '%s\n' 'Usage: install-macos.sh [--plan] [--action ensure|install|update|status|start|stop|restart|repair|uninstall|configure] [--platform auto|macos] [--method auto|native] [--token TOKEN | --token-file FILE] [--version 4.2.8]' '默认 ensure：自动安装、升级或启动同账号服务，保留配置和设备身份，不降级。请传入 Token，不提供交互菜单。' 'configure 显式更换 Token；uninstall 保留配置和身份。'; exit 0 ;;
        *) fail 'unknown argument' ;;
    esac
done
case "$BUSINESS_ENV" in production|test) ;; *) fail '--env must be test or production' ;; esac
mac_plist_env=$BUSINESS_ENV
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
        "client_version=$VERSION" 'zsetup_channel=zsetup/stable-macos' 'zsetup_min_version=0.5.0' \
        'native_status=requires-launchd-preflight' \
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
    check_config_shape
}
check_config_shape() {
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
wait_job_unloaded() {
    unload_attempt=0
    while launchctl print "$domain/$LABEL" >/dev/null 2>&1; do
        [ "$unload_attempt" -lt 10 ] || fail 'service still loaded after stop' 1
        unload_attempt=$((unload_attempt + 1))
        sleep 1
    done
}
check_runtime_identity() {
    identity="$CONFIG_DIR/.ddnsto_boot.cfg"
    [ -e "$identity" ] || [ -L "$identity" ] || return 0
    protected_path "$CONFIG_DIR" private
    [ -f "$identity" ] && [ ! -L "$identity" ] || fail 'runtime identity must be regular'
    metadata=$(stat -f '%u %l' "$identity") || fail 'cannot inspect runtime identity'
    [ "$metadata" = "$uid 1" ] || fail 'runtime identity ownership or hardlink mismatch'
}
protect_runtime_identity() {
    check_runtime_identity
    [ -e "$identity" ] || return 0
    # Published CLI 4.2.8 explicitly chmods its boot file to 0777. It lives
    # inside our owner-only directory; tighten only this owned regular file.
    chmod 600 "$identity" || fail 'cannot protect runtime identity'
}
stable_running() {
    previous_pid=
    observation=0
    attempt=0
    while [ "$attempt" -lt 30 ]; do
        attempt=$((attempt + 1))
        sleep 1
        job=$(launchctl print "$domain/$LABEL" 2>/dev/null) || fail '本地服务未运行，请检查本地日志后重试' 1
        validate_job
        # launchctl also prints nested coalition states. The first state is
        # the service's own state; initial server reassignment may relaunch it.
        job_state=$(printf '%s\n' "$job" | awk '$1 == "state" && $2 == "=" {print $3; exit}')
        if [ "$job_state" != running ]; then observation=0; previous_pid=; continue; fi
        current_pid=$(printf '%s\n' "$job" | sed -n 's/^[[:space:]]*pid = \([1-9][0-9]*\)[[:space:]]*$/\1/p')
        case "$current_pid" in ''|*[!0-9]*) fail '本地服务没有有效进程，请检查本地日志' 1 ;; esac
        if [ "$previous_pid" != "$current_pid" ]; then observation=0; fi
        previous_pid=$current_pid
        observation=$((observation + 1))
        if [ "$observation" -ge 3 ]; then
            protect_runtime_identity
            diagnostic_event stable
            return 0
        fi
    done
    fail '本地服务在 30 秒观察窗口内未稳定运行，请检查本地日志' 1
}
xml() { printf '%s' "$1" | sed 's/\&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }
mac_environment_xml() {
    case "$mac_plist_env" in
        legacy) return 0 ;;
        production) assignment='{"serverDomain":"kooldns.cn","legacyControlAddr":"tunnel.kooldns.cn:4445"}' ;;
        test) assignment='{"serverDomain":"toany.net","legacyControlAddr":"tunnel.toany.net:4445","controlWssURLs":["wss://web.toany.net:9445/ws/control"],"publicWssURLs":["wss://web.toany.net:9445/__ws/public"]}' ;;
    esac
    printf '<key>EnvironmentVariables</key><dict><key>DDNSTO_TEST_SERVER_ASSIGNMENT_JSON</key><string>%s</string></dict>' "$(xml "$assignment")"
}
check_loaded_environment() {
    # Compare with the CURRENT authenticated definition, not the requested
    # target, so an explicitly authorized switch can inspect the old job.
    expected_assignment=
    if [ ! -f "$plist" ]; then
        # Repair may recover a removed definition from the still-loaded owned
        # job. Its program/path/config have already been authenticated.
        for job_environment in production test; do
            loaded_assignment=$(mac_plist_env=$job_environment; mac_environment_xml >/dev/null; printf '%s' "$assignment")
            if printf '%s\n' "$normalized" | grep -F -x -q "DDNSTO_TEST_SERVER_ASSIGNMENT_JSON => $loaded_assignment"; then
                if [ "$job_environment" != "$BUSINESS_ENV" ]; then
                    [ "$SWITCH_ENVIRONMENT" = 1 ] || fail '已加载服务的业务环境不同；确认后使用 --switch-environment'
                    environment_change=1
                fi
                return 0
            fi
        done
        if printf '%s\n' "$normalized" | grep -F -q DDNSTO_TEST_SERVER_ASSIGNMENT_JSON; then
            fail '服务定义缺失且加载环境无法确认；未修改设备'
        fi
        if [ "$BUSINESS_ENV" != production ]; then
            [ "$SWITCH_ENVIRONMENT" = 1 ] || fail '已加载服务默认 production；确认后使用 --switch-environment'
            environment_change=1
        fi
        return 0
    fi
    for job_environment in production test; do
        expected_xml=$(mac_plist_env=$job_environment; mac_environment_xml)
        if grep -F -x -q "$expected_xml" "$plist"; then
            expected_assignment=$(mac_plist_env=$job_environment; mac_environment_xml >/dev/null; printf '%s' "$assignment")
            break
        fi
    done
    if [ -n "$expected_assignment" ]; then
        printf '%s\n' "$normalized" | grep -F -x -q "DDNSTO_TEST_SERVER_ASSIGNMENT_JSON => $expected_assignment" ||
            fail '已加载服务的业务环境与受管定义不同；未修改设备，请核对 launchd 状态'
    elif printf '%s\n' "$normalized" | grep -F -q DDNSTO_TEST_SERVER_ASSIGNMENT_JSON; then
        fail '历史服务继承了未确认的业务环境；未修改设备'
    fi
}
managed_plist() {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>$(xml "$binary")</string><string>--config</string><string>$(xml "$config")</string></array>
<key>WorkingDirectory</key><string>$(xml "$CONFIG_DIR")</string>
$(mac_environment_xml)
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
    for file in "$config" "$binary" "$plist" "$marker" "$receipt"; do
        [ ! -L "$file" ] || fail 'managed files must not be symlinks'
        [ ! -e "$file" ] || [ -f "$file" ] || fail 'managed files must be regular'
        protected_path "$file"
    done
    protected_path "$config" private
    protected_path "$marker" private
    protected_path "$receipt" private
    # The client may restore 0777 on a later launch. Accept only this owned,
    # single-link identity inside an owner-private directory; never relax the
    # checks for configuration, receipts, executable or service definition.
    check_runtime_identity
    if [ -e "$binary" ] || [ -e "$config" ] || [ -e "$plist" ] || [ -e "$marker" ] || [ -e "$receipt" ] || [ -e "$CONFIG_DIR/.ddnsto_boot.cfg" ]; then
        [ -f "$marker" ] && [ -f "$config" ] || fail 'existing unmanaged or incomplete installation'
        retained_environment=
        case "$(cat "$marker")" in
            ddnsto-macos-v1) state=installed ;;
            ddnsto-macos-v1-retained) state=retained; retained_environment=production ;;
            ddnsto-macos-v1-retained:production) state=retained; retained_environment=production ;;
            ddnsto-macos-v1-retained:test) state=retained; retained_environment=test ;;
            *) fail 'unrecognized ownership marker' ;;
        esac
        if [ "$state" = retained ]; then
            [ ! -e "$binary" ] && [ ! -e "$plist" ] || fail 'retained installation contains unexpected files'
            if [ -n "$retained_environment" ] && [ "$retained_environment" != "$BUSINESS_ENV" ]; then
                [ "$SWITCH_ENVIRONMENT" = 1 ] && [ "$ACTION" = install ] || fail '保留配置的业务环境不同；确认重新安装并切换后使用 --switch-environment'
                environment_change=1
            fi
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
                existing_environment=
                for mac_plist_env in production test legacy; do
                    expected_plist=$(managed_plist)
                    # Historical plist has no blank environment line.
                    [ "$mac_plist_env" != legacy ] || expected_plist=$(printf '%s\n' "$expected_plist" | sed '/^$/d')
                    if [ "$actual_plist" = "$expected_plist" ]; then existing_environment=$mac_plist_env; break; fi
                done
                mac_plist_env=$BUSINESS_ENV
                [ -n "$existing_environment" ] || fail 'existing unmanaged plist; migrate it before retrying'
                if [ "$existing_environment" = legacy ]; then
                    existing_environment=production
                fi
                if [ "$existing_environment" != "$BUSINESS_ENV" ]; then
                    [ "$SWITCH_ENVIRONMENT" = 1 ] || fail '业务环境不同；确认切换后使用 --switch-environment；未修改设备'
                    case "$ACTION" in install|update|repair) ;; *) fail '环境切换需要 ensure/install/update/repair，维护动作不会隐式切换' ;; esac
                    environment_change=1
                fi
            fi
        fi
    fi
    if [ -f "$config" ]; then
        check_config_shape
        if grep -E -i -q '^[[:space:]]*(remote_?addr|server_?addr|serverAssignment|serverDomain|bootConfigPath)[[:space:]]*:' "$config"; then
            fail '配置包含自定义服务器或启动记录路径，业务环境无法确认；未修改设备'
        fi
    fi
    if [ "$state" != absent ] && { [ -e "$CONFIG_DIR/.ddnsto_boot.cfg" ] ||
        { [ ! -f "$plist" ] && [ -z "${retained_environment:-}" ]; }; }; then
        # Confirm both the installation and any loaded job before chmod.
        # Preserve identity bytes and avoid restarting an already healthy job.
        check_job
        if [ ! -f "$plist" ] && [ -z "${retained_environment:-}" ] && [ "$job_present" = 0 ]; then
            if [ "$BUSINESS_ENV" != production ]; then
                [ "$SWITCH_ENVIRONMENT" = 1 ] || fail '历史安装默认 production；确认后使用 --switch-environment'
                environment_change=1
            fi
        fi
        if [ -e "$CONFIG_DIR/.ddnsto_boot.cfg" ]; then protect_runtime_identity; fi
    fi
}
check_job() {
    job_present=0
    job=$(launchctl print "$domain/$LABEL" 2>/dev/null) || return 0
    job_present=1
    [ "$state" = installed ] || fail 'existing unmanaged launchd job'
    validate_job
}
validate_job() {
    # Fail closed if a same-label job does not describe our exact file paths.
    normalized=$(printf '%s\n' "$job" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    printf '%s\n' "$normalized" | grep -F -x -q "program = $binary" &&
    printf '%s\n' "$normalized" | grep -F -x -q "path = $plist" &&
    printf '%s\n' "$normalized" | grep -F -x -q "$config" || fail 'existing unmanaged launchd job'
    check_loaded_environment
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
    wait_job_unloaded
    removed=1
    rm -f "$binary" "$plist"
    printf 'ddnsto-macos-v1-retained:%s\n' "$BUSINESS_ENV" > "$marker"
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
        wait_job_unloaded
        printf '%s\n' 'local_service=stopped cloud_status=unverified' '已停止并禁用登录启动。使用 --action start 恢复。'
        exit 0
    fi
    diagnostic_event starting
    launchctl enable "$domain/$LABEL" || fail 'could not enable service'
    if [ "$ACTION" = restart ] && launchctl print "$domain/$LABEL" >/dev/null 2>&1; then
        launchctl bootout "$domain/$LABEL" || fail 'could not stop service for restart'
        wait_job_unloaded
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
        if [ "$environment_change" = 1 ] || [ ! -f "$plist" ] || [ "$(cat "$plist")" != "$(managed_plist)" ]; then
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
    ZSETUP_BIN=$(installer_output bootstrap_zsetup_path) || fail 'zsetup stable bootstrap download/checksum failed; no client changes made' 11
}
printf 'DDNSTO：安装器固定版本 %s，未查询推荐版本。\n' "$VERSION" >&2
if [ "$ACTION" != repair ] && [ "$ACTION" != configure ]; then
    diagnostic_event installing
    # Bootstrap before taking the DDNSTO transaction lock. The shared
    # bootstrap owns temporary signal traps while it verifies the core.
    ensure_zsetup
fi
mkdir -p "$CONFIG_DIR"
mkdir "$CONFIG_DIR/.install-lock" 2>/dev/null || fail 'another installation is active'
locked=1
if [ "$ACTION" != repair ] && [ "$ACTION" != configure ]; then
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
