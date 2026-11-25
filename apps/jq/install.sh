#!/bin/sh
set -eu

APP_ID='jq'
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




bootstrap_zsetup

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
