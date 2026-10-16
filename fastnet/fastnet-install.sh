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

# Linux system-service adapter. Business programs own registration/configuration;
# this coordinator owns protected payloads, activation, health and rollback.
# No automatic sudo child is spawned: privileged invocations must already have
# a root owner, so cancellation can join every install operation as the same UID.
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


# Business logic: maintained in fastnet/business.sh
fastnet_install() {
    : "${ZSETUP_BIN:?zsetup is required}" "${ZSETUP_SOURCE_BASES:?source group is required}"
    case "${ZSETUP_ARCH:-$(uname -m)}" in
        x86_64|amd64) arch_suffix=amd64; sha_key=FASTNET_AMD64_SHA256 ;;
        aarch64|arm64) arch_suffix=arm64; sha_key=FASTNET_ARM64_SHA256 ;;
        armv7l|armv7) arch_suffix=armv7; sha_key=FASTNET_ARMV7_SHA256 ;;
        *) echo 'FastNet: unsupported architecture' >&2; return 2 ;;
    esac
    INSTALLER_REMOTE_APP=fastnet
    installer_launcher_prepare fastnet user || return $?
    status '[2/4] Checking FastNet version...'
    installer_download version.txt "$transaction_dir/version" '' 1 || return $?
    version=$("$ZSETUP_BIN" metadata version "$transaction_dir/version" VERSION) || return $?
    expected_sha=$("$ZSETUP_BIN" metadata sha256 "$transaction_dir/version" "$sha_key") || return $?
    installer_launcher_activate "$version" "FastNet-$version.$arch_suffix" "$expected_sha" || return $?
    installer_transaction_finish || return $?
    status '[4/4] Starting FastNet...'
    exec "$INSTALLER_EXECUTABLE" "$@"
}


bootstrap_and_run() {
    status "[1/4] Checking zsetup..."
    bootstrap_zsetup
    status "      zsetup $RESCUE_VERSION is ready"
    ZSETUP_BIN=$ACTIVE_ZSETUP
    ZSETUP_SOURCE_BASES=${ZSETUP_SOURCE_BASES:-$DIRECT_PRIMARY_BASES}
    ZSETUP_SOURCE_FALLBACK=${ZSETUP_SOURCE_FALLBACK-$DIRECT_FALLBACK_BASE}
    export ZSETUP_BIN ZSETUP_ARCH ZSETUP_SOURCE_BASES ZSETUP_SOURCE_FALLBACK
    installer_dispatch fastnet "$@"
}

main() {
    status "FastNet installer"
    if [ "${ZSETUP_INSTALLER_MODE:-0}" = 1 ]; then
        status "[1/4] zsetup is ready"
        installer_dispatch fastnet "$@"
    else
        bootstrap_and_run "$@"
    fi
}

main "$@"
