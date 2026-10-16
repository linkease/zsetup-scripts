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
        fastnet|fastpve) INSTALLER_MAX_DOWNLOAD=33554432; INSTALLER_MAX_EXPANDED=0; INSTALLER_MAX_FILES=1 ;;
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
    ib_relative=$1; ib_output=$2; ib_sha=${3:-}; ib_fresh=${4:-0}
    case "${ib_relative##*/}" in
        version.txt|VERSION|VERSION_LITE|SHA256SUMS) ib_metadata=1; ib_limit=16384 ;;
        *) ib_metadata=0; ib_limit=$((INSTALLER_MAX_DOWNLOAD - INSTALLER_DOWNLOAD_BYTES)); [ "$ib_limit" -gt 0 ] || return 11 ;;
    esac
    set -- "$ZSETUP_BIN" download -o "$ib_output" --max-bytes "$ib_limit" --min-free-bytes "$INSTALLER_RESERVE"
    [ -z "$ib_sha" ] || set -- "$@" --sha256 "$ib_sha"
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
    "$@" <&0 &
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
    trap - EXIT
    trap '' HUP INT TERM
    installer_transaction_cleanup || { [ "$it_exit" != 0 ] || it_exit=12; }
    exit "$it_exit"
}

installer_transaction_finish() {
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
    case "$il_app" in fastnet|fastpve) ;;
        *) [ "$il_seen_scope:$il_seen_prefix:$il_seen_work" = 0:0:0 ] || { printf 'Installer storage migration pending for %s\n' "$il_app" >&2; return 2; } ;;
    esac
    "${il_app}_install" "$@"
}

installer_launcher_prepare() {
    il_application=$1
    case "$1" in fastnet) il_display=FastNet ;; fastpve) il_display=FastPVE ;; *) il_display=$1 ;; esac
    il_work_hint=${installer_work_dir:-${ZSETUP_WORK_DIR:-}}
    [ -z "$il_work_hint" ] || [ ! -L "$il_work_hint" ] || return 2
    installer_policy "$1" || return $?
    installer_preflight "$1" "$2" "$INSTALLER_REQUIRED_BYTES" 1 || return $?
    [ "$INSTALLER_SCOPE" != system ] || INSTALLER_COMMAND="$INSTALLER_PREFIX/current"
    [ ! -L "$INSTALLER_PREFIX" ] || return 2
    umask 077
    mkdir -p "$INSTALLER_PREFIX"
    [ "$("$ZSETUP_BIN" storage "$INSTALLER_PREFIX" get private_directory)" = true ] || return 12
    [ ! -L "$INSTALLER_PREFIX/.managed" ] && [ ! -L "$INSTALLER_PREFIX/versions" ] || return 2
    il_owner=
    if [ -f "$INSTALLER_PREFIX/.managed" ] && [ ! -L "$INSTALLER_PREFIX/.managed" ]; then
        installer_file_size "$INSTALLER_PREFIX/.managed" || return 2
        [ "$INSTALLER_FILE_SIZE" -le 65 ] || return 2
        IFS= read -r il_owner < "$INSTALLER_PREFIX/.managed" || return 2
        [ "$il_owner" = "$1" ] || return 2
    else
        [ ! -e "$INSTALLER_PREFIX/versions" ] && [ ! -L "$INSTALLER_PREFIX/current" ] && [ ! -e "$INSTALLER_PREFIX/current" ] || return 2
        (set -C; printf '%s\n' "$1" > "$INSTALLER_PREFIX/.managed") || return 2
    fi
    if [ "$INSTALLER_SCOPE" = user ]; then
        if [ -e "$INSTALLER_COMMAND" ] || [ -L "$INSTALLER_COMMAND" ]; then
            [ -L "$INSTALLER_COMMAND" ] && [ "$(readlink "$INSTALLER_COMMAND")" = "$INSTALLER_PREFIX/current" ] || {
                printf 'Installer: existing command belongs to another installation: %s\n' "$INSTALLER_COMMAND" >&2; return 2;
            }
        fi
    fi
    installer_transaction_begin || return $?
    INSTALLER_CLEANUP_HOOK=installer_launcher_cleanup
    il_candidate=
    il_new_version=0
    il_activated=0
    il_previous=
    mkdir -p "$INSTALLER_PREFIX/versions"
}

installer_launcher_cleanup() {
    if [ "$il_activated" = 1 ]; then
        if [ -n "$il_previous" ]; then
            ln -s "$il_previous" "$INSTALLER_PREFIX/.restore.$$" || return 1
            mv -f "$INSTALLER_PREFIX/.restore.$$" "$INSTALLER_PREFIX/current" || return 1
        else
            rm -f "$INSTALLER_PREFIX/current" || return 1
        fi
        il_activated=0
    fi
    [ -z "$il_candidate" ] || rm -f "$il_candidate" || return 1
    if [ "$il_new_version" = 1 ]; then rm -rf "$il_version_dir" || return 1; fi
    rm -f "$INSTALLER_PREFIX/.current.$$" "$INSTALLER_PREFIX/.previous.$$"
}

installer_launcher_activate() {
    il_version=$1; il_remote_name=$2; il_sha=$3
    il_version_dir="$INSTALLER_PREFIX/versions/$il_version"
    INSTALLER_EXECUTABLE="$il_version_dir/bin/$il_application"
    il_marker="$INSTALLER_EXECUTABLE.verified"
    [ ! -L "$il_version_dir" ] && [ ! -L "$il_version_dir/bin" ] || return 2
    for il_path in "$INSTALLER_EXECUTABLE" "$il_marker"; do
        [ ! -L "$il_path" ] && { [ ! -e "$il_path" ] || [ -f "$il_path" ]; } || return 2
    done
    il_cached=0
    if [ -x "$INSTALLER_EXECUTABLE" ] && [ -f "$il_marker" ]; then
        installer_file_size "$INSTALLER_EXECUTABLE" || return $?
        il_payload_size=$INSTALLER_FILE_SIZE
        [ "$il_payload_size" -le "$INSTALLER_MAX_DOWNLOAD" ] || return 11
        installer_file_size "$il_marker" || return 2
        [ "$INSTALLER_FILE_SIZE" -le 128 ] || return 2
        il_record=
        IFS= read -r il_record < "$il_marker" || il_record=
        il_old_sha=${il_record%%:*}
        case "$il_old_sha" in *[!0123456789abcdef]*|'') ;;
            *) if [ "${#il_old_sha}" = 64 ] && [ "$il_old_sha" != "$il_sha" ]; then
                printf 'Installer: installed version %s has a different digest; immutable versions cannot be replaced.\n' "$il_version" >&2
                return 11
            fi ;;
        esac
        if [ "$il_record" = "$il_sha:$il_payload_size" ]; then il_cached=1; fi
    fi
    if [ "$il_cached" = 1 ]; then
        status "[3/4] $il_display is already downloaded (verified cached version)"
        installer_exec_native "$ZSETUP_BIN" run -- "$INSTALLER_EXECUTABLE" version || return $?
    else
        status "[3/4] Downloading $il_display..."
        installer_download "$il_remote_name" "$transaction_dir/product" "$il_sha" || return $?
        chmod 0755 "$transaction_dir/product"
        installer_exec_native "$ZSETUP_BIN" run -- "$transaction_dir/product" version || return $?
        if [ ! -d "$il_version_dir" ]; then
            mkdir "$il_version_dir" || return 12
            il_new_version=1
        fi
        mkdir -p "$il_version_dir/bin"
        il_candidate="$il_version_dir/bin/.candidate.$$"
        installer_exec_native "$ZSETUP_BIN" capture -o "$il_candidate" --max-bytes "$INSTALLER_MAX_DOWNLOAD" --min-free-bytes "$INSTALLER_RESERVE" -- cat "$transaction_dir/product" || return $?
        chmod 0755 "$il_candidate"
        installer_file_size "$il_candidate" || return $?
        printf '%s:%s\n' "$il_sha" "$INSTALLER_FILE_SIZE" > "$transaction_dir/verified"
        mv -f "$il_candidate" "$INSTALLER_EXECUTABLE" || return 12
        il_candidate=
        mv -f "$transaction_dir/verified" "$il_marker" || return 12
    fi
    installer_storage_check "$INSTALLER_PREFIX" "$INSTALLER_RESERVE" 1 1 || return $?
    if [ -e "$INSTALLER_PREFIX/current" ] || [ -L "$INSTALLER_PREFIX/current" ]; then
        [ -L "$INSTALLER_PREFIX/current" ] && [ -f "$INSTALLER_PREFIX/current" ] || return 2
        il_previous=$(readlink "$INSTALLER_PREFIX/current") || return 2
        case "$il_previous" in versions/*/bin/"$il_application") ;; *) return 2 ;; esac
        il_old_version=${il_previous#versions/}; il_old_version=${il_old_version%/bin/"$il_application"}
        case "$il_old_version" in ''|*[!0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._+-]*|.*) return 2 ;; esac
    fi
    ln -s "versions/$il_version/bin/$il_application" "$INSTALLER_PREFIX/.current.$$" || return 12
    il_activated=1
    mv -f "$INSTALLER_PREFIX/.current.$$" "$INSTALLER_PREFIX/current" || return 12
    if [ "$INSTALLER_SCOPE" = user ]; then
        mkdir -p "${INSTALLER_COMMAND%/*}"
        il_candidate="${INSTALLER_COMMAND%/*}/.$il_application.$$"
        ln -s "$INSTALLER_PREFIX/current" "$il_candidate" || return 12
        mv -f "$il_candidate" "$INSTALLER_COMMAND" || return 12
        il_candidate=
    fi
    if [ -n "$il_previous" ] && [ "$il_previous" != "versions/$il_version/bin/$il_application" ]; then
        ln -s "$il_previous" "$INSTALLER_PREFIX/.previous.$$" || return 12
        mv -f "$INSTALLER_PREFIX/.previous.$$" "$INSTALLER_PREFIX/previous" || return 12
    fi
    il_keep=$(readlink "$INSTALLER_PREFIX/current")
    il_keep_old=$(readlink "$INSTALLER_PREFIX/previous" 2>/dev/null || true)
    for il_dir in "$INSTALLER_PREFIX"/versions/*; do
        [ -d "$il_dir" ] && [ ! -L "$il_dir" ] || continue
        il_target="versions/${il_dir##*/}/bin/$il_application"
        [ "$il_target" != "$il_keep" ] && [ "$il_target" != "$il_keep_old" ] || continue
        [ -f "$il_dir/bin/$il_application.verified" ] && [ ! -L "$il_dir/bin/$il_application.verified" ] || continue
        rm -rf "$il_dir" || return 12
    done
    il_activated=0
    il_new_version=0
}


# Business logic: maintained in ddnsto/business.sh
# Included at build time; only ddnsto-install.sh is a public installer.
ddnsto_error() { printf 'DDNSTO: %s\n' "$*" >&2; }

ddnsto_usage() {
    printf '%s\n' 'Usage: ddnsto-install.sh [--token TOKEN] [--force-version lite|standard] [--verify-status]' \
        'OpenWrt: token optional; automatic Lite selection below 900 MB.' \
        'Linux x86_64/aarch64: --token required without an interactive terminal.'
}

ddnsto_parse_args() {
    TOKEN=
    FORCE_VERSION=
    VERIFY_STATUS=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --token|--force-version)
                [ "$#" -ge 2 ] && [ -n "$2" ] || { ddnsto_error "$1 requires a value"; return 2; }
                case "$1" in --token) TOKEN=$2 ;; *) FORCE_VERSION=$2 ;; esac
                shift 2 ;;
            --token=*) TOKEN=${1#--token=}; [ -n "$TOKEN" ] || return 2; shift ;;
            --force-version=*) FORCE_VERSION=${1#--force-version=}; shift ;;
            --verify-status) VERIFY_STATUS=1; shift ;;
            *) ddnsto_error "unknown argument: $1"; return 2 ;;
        esac
    done
    case "$FORCE_VERSION" in ''|lite|standard) ;; *) ddnsto_error 'version must be lite or standard'; return 2 ;; esac
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

ddnsto_checksum() {
    "$ZSETUP_BIN" metadata sha256 "$1" "$2" || {
        ddnsto_error "invalid, missing or duplicate SHA256 for $2"; return 11;
    }
}

ddnsto_rollback() {
    [ "${replacement_started:-0}" = 1 ] || return 0
    if [ "$had_old" = 1 ]; then
        ddnsto_privileged mv -f "$backup" "$bin_path" || {
            ddnsto_error "rollback failed; backup retained at $backup"; return 1;
        }
        replacement_started=0
        ddnsto_privileged "$bin_path" -u "$TOKEN" -daemon || status 'DDNSTO: previous service could not be restarted; manual recovery needed'
    else
        ddnsto_privileged rm -f "$bin_path"
        replacement_started=0
    fi
}

ddnsto_cleanup() {
    ddnsto_rollback || true
    [ -z "${install_candidate:-}" ] || ddnsto_privileged rm -f "$install_candidate"
    if [ "${replacement_started:-0}" = 0 ] && [ -n "${backup:-}" ]; then
        ddnsto_privileged rm -f "$backup"
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
    version_pointer=VERSION
    [ "$SELECTED_VERSION" != lite ] || version_pointer=VERSION_LITE
    ddnsto_download "openwrt/$version_pointer" "$transaction_dir/version" '' 1
    version_num=$("$ZSETUP_BIN" metadata version "$transaction_dir/version")
    case "$version_num" in ''|*[!0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._+-]*) ddnsto_error 'invalid version metadata'; return 11 ;; esac
    version_folder=$SELECTED_VERSION
    [ "$pkg_ext" != apk ] || version_folder="$version_folder-apk"
    relative_folder="openwrt/$version_folder/$version_num"
    ddnsto_download "$relative_folder/SHA256SUMS" "$transaction_dir/sums" '' 1
    status "      DDNSTO $version_num ($SELECTED_VERSION; Lite below 900 MB)"
    status '[3/4] Downloading and verifying DDNSTO packages...'
    package_cache="$work_dir/cache/$version_folder/$version_num/$arch"
    mkdir -p "$package_cache"
    main_package="ddnsto_$package_arch.$pkg_ext"
    ui_package="luci-app-ddnsto.$pkg_ext"
    language_package="luci-i18n-ddnsto-zh-cn.$pkg_ext"
    for package in "$main_package" "$ui_package" "$language_package"; do
        digest=$(ddnsto_checksum "$transaction_dir/sums" "$package")
        ddnsto_verified_download "$relative_folder/$package" "$package_cache/$package" "$digest"
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
    status 'DDNSTO installation completed; refresh LuCI if its menu is missing'
}

ddnsto_linux() {
    case "$arch" in x86_64|aarch64) ;; *) ddnsto_error "unsupported Linux architecture: $arch"; return 2 ;; esac
    [ "$FORCE_VERSION" != lite ] || { ddnsto_error 'Linux only supports standard'; return 2; }
    [ "$VERIFY_STATUS" = 0 ] || { ddnsto_error '--verify-status is for OpenWrt'; return 2; }
    if [ -z "$TOKEN" ]; then
        if [ -t 0 ]; then
            printf 'DDNSTO token: ' >&2
            IFS= read -r TOKEN
        else
            ddnsto_error 'Linux needs --token TOKEN for noninteractive installation'; return 2
        fi
    fi
    [ -n "$TOKEN" ] || { ddnsto_error 'empty token'; return 2; }
    version_num=${DDNSTO_VERSION:-4.2.3}
    case "$version_num" in ''|*[!0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._+-]*) ddnsto_error 'invalid DDNSTO_VERSION'; return 2 ;; esac
    status "[2/4] Checking DDNSTO standard $version_num ($arch)..."
    archive_name="ddnsto-standard-$version_num.tar.gz"
    ddnsto_download linux-binary/SHA256SUMS "$transaction_dir/sums" '' 1
    digest=$(ddnsto_checksum "$transaction_dir/sums" "$archive_name")
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
    SUDO=
    if [ ! -w "$bin_dir" ] && [ "$(id -u)" != 0 ]; then
        command -v sudo >/dev/null 2>&1 || { ddnsto_error 'root or sudo is required'; return 2; }
        SUDO=sudo
    fi
    status '[4/4] Installing and starting DDNSTO...'
    ddnsto_privileged mkdir -p "$bin_dir"
    install_candidate="$bin_dir/.ddnsto-candidate.$$"
    backup="$bin_dir/.ddnsto-backup.$$"
    ddnsto_privileged cp "$extracted" "$install_candidate"
    ddnsto_privileged chmod 0755 "$install_candidate"
    had_old=0
    if [ -f "$bin_path" ]; then
        ddnsto_privileged cp -p "$bin_path" "$backup"
        had_old=1
        ddnsto_privileged "$bin_path" stop
    fi
    replacement_started=1
    ddnsto_privileged mv -f "$install_candidate" "$bin_path"
    install_candidate=
    if ddnsto_privileged "$bin_path" -u "$TOKEN" -daemon; then
        replacement_started=0
        ddnsto_privileged rm -f "$backup"
    else
        start_code=$?
        ddnsto_error 'start failed; restoring previous binary'
        return "$start_code"
    fi
    status 'DDNSTO installation completed'
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


bootstrap_and_run() {
    status "[1/4] Checking zsetup..."
    bootstrap_zsetup
    status "      zsetup $RESCUE_VERSION is ready"
    ZSETUP_BIN=$ACTIVE_ZSETUP
    ZSETUP_SOURCE_BASES=${ZSETUP_SOURCE_BASES:-$DIRECT_PRIMARY_BASES}
    ZSETUP_SOURCE_FALLBACK=${ZSETUP_SOURCE_FALLBACK-$DIRECT_FALLBACK_BASE}
    export ZSETUP_BIN ZSETUP_ARCH ZSETUP_SOURCE_BASES ZSETUP_SOURCE_FALLBACK
    installer_dispatch ddnsto "$@"
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
