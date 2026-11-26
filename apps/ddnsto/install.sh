#!/bin/sh
ddnsto_entry_main() {
set -eu

APP_ID='ddnsto'
CONFIG_PRIMARY_URLS='https://dl.istoreos.com/binary/zsetup-scripts/apps/zsetup/config.json https://fw.d4ctech.com/binary/zsetup-scripts/apps/zsetup/config.json https://fw20.koolcenter.com/binary/zsetup-scripts/apps/zsetup/config.json'
CONFIG_FALLBACK_URL='https://fw.koolcenter.com/binary/zsetup-scripts/apps/zsetup/config.json'

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

bootstrap_notice() {
    if command -v zsetup_bootstrap_progress >/dev/null 2>&1; then
        zsetup_bootstrap_progress "$@"
    fi
    return 0
}

bootstrap_mips_byte_order() {
    type od >/dev/null 2>&1 || return 1
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
    bootstrap_notice source "$base"
    if type curl >/dev/null 2>&1; then
        found=1
        rm -f "$destination" 2>/dev/null || true
        if curl -fsSL --connect-timeout 10 --max-time 30 -o "$destination" "$url"; then
            return 0
        fi
        bootstrap_notice retry
    fi
    if type wget >/dev/null 2>&1; then
        found=1
        rm -f "$destination" 2>/dev/null || true
        if wget -q -T 10 -O "$destination" "$url"; then
            return 0
        fi
        bootstrap_notice retry
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
    type sha256sum >/dev/null 2>&1 || type openssl >/dev/null 2>&1 ||
        type shasum >/dev/null 2>&1
}

hash_matches() {
    [ -f "$1" ] || return 1
    if [ -z "${EXPECTED_SHA256:-}" ]; then
        echo "zsetup: bootstrap SHA-256 verification skipped; HTTPS transport remains required" >&2
        return 0
    fi
    if type sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "$1")
        actual=${actual%% *}
    elif type openssl >/dev/null 2>&1; then
        actual=$(openssl dgst -sha256 "$1")
        actual=${actual##*= }
    elif type shasum >/dev/null 2>&1; then
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
    metadata_incomplete=0
    for base in $BOOTSTRAP_BASES; do
        bootstrap_fetch_from_base "$scheme" "$base" "$ZSETUP_STABLE_PATH" "$stable_file" || continue
        read_stable_version "$stable_file" || continue
        EXPECTED_SHA256=
        ZSETUP_RELEASE_PATH="zsetup/$RESCUE_VERSION"
        if [ "$ZSETUP_STABLE_PATH" = zsetup/stable-macos ]; then
            # macOS releases have their own namespace. Keep the historical
            # flat layout usable, but select binary and checksum as one pair.
            have_hash_tool || {
                echo "zsetup: macOS bootstrap requires a SHA-256 verification tool" >&2
                return 11
            }
            for release_path in "zsetup/macos/$RESCUE_VERSION" "zsetup/$RESCUE_VERSION"; do
                if bootstrap_fetch_from_base "$scheme" "$base" "$release_path/SHA256SUMS" "$sums_file" &&
                    read_expected_sha256 "$sums_file"; then
                    ZSETUP_RELEASE_PATH=$release_path
                    return 0
                fi
            done
            echo "zsetup: stable $RESCUE_VERSION has no valid checksum for $ZSETUP_ARTIFACT in macOS or flat release directories" >&2
            metadata_incomplete=1
            continue
        fi
        if have_hash_tool && bootstrap_fetch_from_base "$scheme" "$base" "$ZSETUP_RELEASE_PATH/SHA256SUMS" "$sums_file"; then
            # A fetched manifest which omits this platform is a broken release,
            # not permission to execute an unverified artifact from it.
            read_expected_sha256 "$sums_file" || {
                echo "zsetup: stable $RESCUE_VERSION does not publish $ZSETUP_ARTIFACT; release metadata must be repaired" >&2
                metadata_incomplete=1
                continue
            }
        fi
        return 0
    done
    [ "$metadata_incomplete" = 0 ] || return 11
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
    if fetch_bootstrap_metadata https "$stable_file" "$sums_file"; then
        :
    else
        metadata_rc=$?
        # An authenticated release missing this platform cannot be repaired by
        # HTTP, a different architecture, or silently downgrading the runtime.
        [ "$metadata_rc" != 11 ] || return 11
        confirm_insecure_http
        metadata_scheme=http
        fetch_bootstrap_metadata http "$stable_file" "$sums_file"
    fi

    if find_existing_zsetup; then
        bootstrap_notice cached
        trap - EXIT HUP INT TERM
        rm -f "$stable_file" "$sums_file" 2>/dev/null || true
        return 0
    fi

    rescue_dir="$WORK_ROOT/rescue/$RESCUE_VERSION"
    bootstrap_notice download
    rescue_bin="$rescue_dir/zsetup"
    candidate="$rescue_dir/.zsetup-download.$$"
    mkdir -p "$rescue_dir"
    if ! bootstrap_fetch https "$ZSETUP_RELEASE_PATH/$ZSETUP_ARTIFACT" "$candidate"; then
        confirm_insecure_http
        bootstrap_fetch http "$ZSETUP_RELEASE_PATH/$ZSETUP_ARTIFACT" "$candidate"
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


# Human-facing stages. Never print arguments (which may contain the Token).
DDNSTO_HUMAN_OUTPUT=1
export DDNSTO_HUMAN_OUTPUT

zsetup_bootstrap_progress() {
    case "$1" in
        source) printf 'DDNSTO：正在连接下载源 %s…\n' "${2#*://}" >&2 ;;
        retry) printf '%s\n' 'DDNSTO：此下载源未成功，正在尝试下一种下载方式或镜像…' >&2 ;;
        cached) printf '%s\n' 'DDNSTO：使用已有安装工具，无需重复下载。' >&2 ;;
        download) printf '%s\n' 'DDNSTO：正在下载并校验安装工具…' >&2 ;;
    esac
}

ddnsto_entry_wait() (
    ddnsto_stage=$1
    shift
    printf 'DDNSTO：%s…\n' "$ddnsto_stage" >&2
    ddnsto_interval=${DDNSTO_PROGRESS_INTERVAL:-8}
    case "$ddnsto_interval" in ''|*[!0-9]*|0) ddnsto_interval=8 ;; esac
    (
        ddnsto_sleep=
        trap '[ -z "$ddnsto_sleep" ] || kill "$ddnsto_sleep" 2>/dev/null || :; exit 0' HUP INT TERM
        while :; do
            sleep "$ddnsto_interval" & ddnsto_sleep=$!
            wait "$ddnsto_sleep" || exit 0
            ddnsto_sleep=
            printf 'DDNSTO：%s，仍在处理，请稍候…\n' "$ddnsto_stage" >&2
        done
    ) &
    ddnsto_ticker=$!
    trap 'kill "$ddnsto_ticker" 2>/dev/null || :; wait "$ddnsto_ticker" 2>/dev/null || :' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    # Execute in a separate subshell so bootstrap traps and exec cannot replace
    # the ticker cleanup handler. Preserve the original command's exit code.
    set +e
    ( set -e; "$@" )
    ddnsto_rc=$?
    if [ "$ddnsto_rc" != 0 ]; then
        printf 'DDNSTO：阶段“%s”失败（退出码 %s）；下一步：根据上方错误检查网络或诊断记录后重试。\n' "$ddnsto_stage" "$ddnsto_rc" >&2
    fi
    exit "$ddnsto_rc"
)

printf '%s\n' 'DDNSTO：正在检查系统和已有安装…' >&2
# Metadata for DDNSTO only. Prefer native stat, but minimal OpenWrt firmware
# may omit both stat and its BusyBox applet. Never replace checks with success.
ddnsto_file_fields() (
    [ "$#" = 1 ] && [ ! -L "$1" ] || return 1
    if command -v stat >/dev/null 2>&1; then
        # BSD stat L contains only rwx; M is required for sticky/set-ID bits.
        if [ "$(uname -s)" = Darwin ]; then stat -f '%u %Mp%Lp %l' "$1"
        else stat -c '%u %a %h' "$1"; fi
        return $?
    fi
    # Only unambiguous paths and regular files/directories. Reject ACL markers,
    # unexpected listing formats and symlinks rather than guessing permissions.
    case "$1" in /*) ;; *) return 1 ;; esac
    case "$1" in *[!a-zA-Z0-9_./-]*) return 1 ;; esac
    expected_path=$1
    listing=$(LC_ALL=C TIME_STYLE=locale ls -dn "$1") || return 1
    set -f
    IFS=$(printf ' \t\n_')
    IFS=${IFS%_}
    set -- $listing
    [ "$#" = 9 ] && [ "$9" = "$expected_path" ] || return 1
    permissions=$1 links=$2 owner=$3
    case "$owner:$links" in *[!0-9:]*) return 1 ;; esac
    [ -n "$owner" ] && [ -n "$links" ] && [ "$links" -gt 0 ] || return 1
    case "$permissions" in
        [-d][r-][w-][xsS-][r-][w-][xsS-][r-][w-][xtT-]) ;;
        *) return 1 ;;
    esac
    bits=${permissions#?} mode=0 special=0 position=0
    while [ -n "$bits" ]; do
        character=${bits%"${bits#?}"}; bits=${bits#?}
        position=$((position + 1))
        case "$character" in -|S|T) bit=0 ;; *) bit=1 ;; esac
        mode=$((mode * 2 + bit))
        case "$position:$character" in
            3:s|3:S) special=$((special + 2048)) ;;
            6:s|6:S) special=$((special + 1024)) ;;
            9:t|9:T) special=$((special + 512)) ;;
        esac
    done
    printf '%s %o %s\n' "$owner" "$((mode + special))" "$links"
)

# Restricted interface used by Linux/OpenWrt protection checks. This is not a
# replacement stat executable and is never installed into the system PATH.
ddnsto_stat() (
    [ "$#" = 3 ] && [ "$1" = -c ] || return 1
    format=$2
    fields=$(ddnsto_file_fields "$3") || return 1
    set -- $fields
    [ "$#" = 3 ] || return 1
    case "$format" in
        %u) printf '%s\n' "$1" ;;
        %a) printf '%s\n' "$2" ;;
        %h) printf '%s\n' "$3" ;;
        *) return 1 ;;
    esac
)

# Validate storage ancestors before privileged DDNSTO adapters create or
# replace files.  These are filesystem-safety primitives, not zsetup version
# policy, so they live with the portable metadata implementation.
ddnsto_bootstrap_safe_ancestors() (
    case "$1" in /*) ;; *) return 1 ;; esac
    case "$1/" in *//*|*/./*|*/../*) [ "$1" = / ] || return 1 ;; esac
    directory=$1
    while :; do
        [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
        owner=$(ddnsto_stat -c %u "$directory") || return 1
        mode=$(ddnsto_stat -c %a "$directory") || return 1
        [ "$owner" = 0 ] || [ "$owner" = "$(id -u)" ] || return 1
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
    [ -d "$1" ] && [ "$(ddnsto_stat -c %u "$1")" = "$(id -u)" ] &&
        [ "$(ddnsto_stat -c %a "$1")" = 700 ]
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

# Standard-entry preflight: runs before native bootstrap, not inside its payload.
# Reuse the business filesystem checks; never remount DSM /tmp or chmod strangers.
ddnsto_entry_private_storage() {
    ddnsto_bootstrap_safe_ancestors "${1%/*}" &&
        ddnsto_bootstrap_private_dir "$1" || {
        printf '%s\n' 'DDNSTO: unsafe installer cache; check ownership/permissions or run as a DSM administrator; code=12' >&2
        return 12
    }
    WORK_ROOT=$1
    ZSETUP_ROOT=$WORK_ROOT
    ZSETUP_MANAGED_ROOT=$WORK_ROOT/managed
    ZSETUP_CACHE_DIR=$WORK_ROOT/installers
    export ZSETUP_ROOT ZSETUP_MANAGED_ROOT ZSETUP_CACHE_DIR
}

ddnsto_entry_storage() {
    DDNSTO_ENTRY_APPLIANCE=
    DDNSTO_ENTRY_LEGACY=0
    if [ -f /etc.defaults/VERSION ] && [ -x /usr/syno/bin/synopkg ]; then
        DDNSTO_ENTRY_APPLIANCE=synology
        if [ -n "${ZSETUP_ROOT:-}" ]; then
            ddnsto_entry_private_storage "$ZSETUP_ROOT"
        elif [ "$(id -u)" = 0 ]; then
            ddnsto_entry_private_storage /var/lib/ddnsto-installer
        else
            # DSM's home entry can be a symlink into the actual data volume.
            # Resolve it first, then validate every real ancestor.
            entry_home=$(CDPATH= cd -P -- "${HOME:?}" && pwd -P) || return 12
            ddnsto_entry_private_storage "$entry_home/.ddnsto-installer"
        fi
    elif [ -x /bin/nvram ] && [ -x /usr/bin/dbus ] && [ -d /koolshare ]; then
        DDNSTO_ENTRY_APPLIANCE=asus
        ddnsto_asus_storage || {
            printf '%s\n' 'DDNSTO: unsafe ASUS installer storage; check /jffs; code=12' >&2
            return 12
        }
        WORK_ROOT=$ASUS_STATE/entry-bootstrap
        ddnsto_asus_private_dir "$WORK_ROOT" || return 12
        ZSETUP_ROOT=$WORK_ROOT
        export ZSETUP_ROOT
        case "$(uname -r)" in 2.6.*) DDNSTO_ENTRY_LEGACY=1 ;; esac
    fi
}

ddnsto_entry_storage

# Native 0.6.4 reports these supported appliances as unknown. Keep their
# fingerprint/transaction adapter, without falsifying native context or falling
# back from a failed generic install. The generated identity is immutable.
ddnsto_entry_appliance() (
    [ -n "$DDNSTO_ENTRY_APPLIANCE" ] || return 0
    umask 077
    if [ "$DDNSTO_ENTRY_APPLIANCE" = asus ]; then
        entry_dir=$(ddnsto_asus_mktemp "$WORK_ROOT") || exit 12
    else entry_dir=$(mktemp -d "$WORK_ROOT/entry.XXXXXX") || exit 12; fi
    entry_file=$entry_dir/install.sh
    trap 'rm -f "$entry_file"; rmdir "$entry_dir"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    entry_digest='c352ddf239efe68d7c59edd941f9c2ec9abc8ce696f1320b99f5e1449ceb9541'
    entry_size='618824'
    entry_relative='ddnsto/versions/0.3.4/install.sh'
    if [ "$DDNSTO_ENTRY_LEGACY" = 1 ]; then
        entry_ok=0
        for entry_base in $CONFIG_PRIMARY_URLS "$CONFIG_FALLBACK_URL"; do
            entry_base=${entry_base%/zsetup/config.json}
            if bootstrap_fetch_from_base https "$entry_base" "$entry_relative" "$entry_file"; then
                entry_ok=1; break
            fi
        done
        [ "$entry_ok" = 1 ] && [ "$(wc -c < "$entry_file")" -eq "$entry_size" ] &&
            [ "$(ddnsto_asus_hash "$entry_file")" = "$entry_digest" ] || exit 11
    else
        # Keep caller arguments untouched in the parent function/subshell.
        ddnsto_entry_fetch_payload() {
            set -- download --quiet -o "$entry_file" --sha256 "$entry_digest" --size "$entry_size" --max-bytes "$entry_size"
            for entry_base in $CONFIG_PRIMARY_URLS; do
                set -- "$@" "${entry_base%/zsetup/config.json}/$entry_relative"
            done
            case " $CONFIG_PRIMARY_URLS " in
                *" $CONFIG_FALLBACK_URL "*) ;;
                *) set -- "$@" --fallback-url "${CONFIG_FALLBACK_URL%/zsetup/config.json}/$entry_relative" ;;
            esac
            "$ACTIVE_ZSETUP" "$@"
        }
        ddnsto_entry_fetch_payload || exit $?
    fi
    sh "$entry_file" "$@"
)


if [ "$DDNSTO_ENTRY_LEGACY" = 0 ]; then
ACTIVE_ZSETUP=$(ddnsto_entry_wait "正在准备安装工具，首次运行可能稍久" bootstrap_zsetup_path)
fi
if [ -n "$DDNSTO_ENTRY_APPLIANCE" ]; then
    ddnsto_entry_wait "正在下载、校验并运行安装器" ddnsto_entry_appliance "$@"
    exit "$?"
fi

config_dir=$WORK_ROOT/zsetup-scripts
config_file=$config_dir/config.json
config_candidate=$config_dir/.config.json.$$
mkdir -p "$config_dir"
trap 'rm -f "$config_candidate" 2>/dev/null || true' EXIT HUP INT TERM
download_business_config() {
    set -- download --quiet -o "$config_candidate" --max-bytes 131072
    for config_url in $CONFIG_PRIMARY_URLS; do set -- "$@" "$config_url"; done
    set -- "$@" --fallback-url "$CONFIG_FALLBACK_URL"
    "$ACTIVE_ZSETUP" "$@"
}
if [ "$APP_ID" = ddnsto ]; then
    ddnsto_entry_wait '正在获取安装信息' download_business_config
else
    download_business_config
fi
chmod 0600 "$config_candidate"
mv -f "$config_candidate" "$config_file"
trap - EXIT HUP INT TERM
ZSETUP_CONFIG=$config_file
export ZSETUP_CONFIG
if [ "$APP_ID" = ddnsto ]; then
    index_file=$config_dir/ddnsto-index.json
    config_candidate=$config_dir/.ddnsto-index.json.$$
    trap 'rm -f "$config_candidate" 2>/dev/null || true' EXIT HUP INT TERM
    index_urls=
    for config_url in $CONFIG_PRIMARY_URLS; do
        index_urls="$index_urls ${config_url%/config.json}/ddnsto-index.json"
    done
    CONFIG_PRIMARY_URLS=$index_urls
    CONFIG_FALLBACK_URL=${CONFIG_FALLBACK_URL%/config.json}/ddnsto-index.json
    ddnsto_entry_wait '正在获取安装索引' download_business_config
    chmod 0600 "$config_candidate"
    mv -f "$config_candidate" "$index_file"
    trap - EXIT HUP INT TERM
    ZSETUP_SOURCE_BASES=$DIRECT_PRIMARY_BASES
    ZSETUP_SOURCE_FALLBACK=$DIRECT_FALLBACK_BASE
    export ZSETUP_SOURCE_BASES ZSETUP_SOURCE_FALLBACK
    ddnsto_entry_wait '正在下载、校验并运行安装器' "$ACTIVE_ZSETUP" install --index "$index_file" "$APP_ID" --foreground -- "$@"
    exit "$?"
fi
exec "$ACTIVE_ZSETUP" install "$APP_ID" --foreground -- "$@"

}
ddnsto_entry_main "$@" </dev/null
