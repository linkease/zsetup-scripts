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
    "${il_app}_install" "$@"
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
            set -- --token "$TOKEN"
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


# Business logic: maintained in linkease/business.sh
# Included at build time; only linkease-install.sh is maintained as the public entry.
linkease_error() { printf 'LinkEase: %s\n' "$*" >&2; }

linkease_usage() {
    printf '%s\n' 'Usage: linkease-install.sh [--version VERSION]' \
        'Linux: default version 1.7.5; installs LinkEase, media, HEIF converter and linkmount.' \
        'OpenWrt opkg: defaults to server VERSION; x86_64/aarch64/armv7 supported.'
    printf '%s\n' 'Linux systemd: user preparation + sudo -n commit (or explicit root), system scope; --installer-prefix PATH and --installer-work-dir PATH precede business arguments.'
}

linkease_parse_args() {
    version_override=${LINKEASE_VERSION:-}
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --version)
                [ "$#" -ge 2 ] && [ -n "$2" ] || { linkease_error '--version requires a value'; return 2; }
                version_override=$2; shift 2 ;;
            --version=*) version_override=${1#--version=}; [ -n "$version_override" ] || return 2; shift ;;
            *) linkease_error "unknown argument: $1"; return 2 ;;
        esac
    done
    case "$version_override" in '' ) ;; *[!0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._+-]*|.*|-*|+*|_*) linkease_error 'invalid version'; return 2 ;; esac
    [ "${#version_override}" -le 64 ] || return 2
}

# All transport, HTTPS/Race/fallback policy and digest verification remain in zsetup.
linkease_download() { installer_download "$@"; }

linkease_verified_download() {
    le_name=$1
    le_digest=$("$ZSETUP_BIN" metadata sha256 "$transaction_dir/sums" "$le_name") || {
        linkease_error "invalid or missing SHA256 for $le_name"; return 11;
    }
    le_file="$cache_dir/$le_name"
    le_marker="$le_file.verified"
    installer_package_immutable "$le_marker" "$le_digest" || return $?
    linkease_download "$relative_folder/$le_name" "$le_file" "$le_digest" || return $?
    le_size=$(wc -c < "$le_file" | tr -d '[:space:]')
    printf '%s:%s\n' "$le_digest" "$le_size" > "$transaction_dir/verified"
    mv -f "$transaction_dir/verified" "$le_marker"
}

# Stream only requested members to regular staging files: no archive-provided paths/links are installed.
linkease_unpack_linux() {
    mkdir -p "$transaction_dir/products/linkmount"
    for le_binary in linkease heif-converter linkease-media; do
        installer_extract_member "$transaction_dir/products/$le_binary" tar -xOzf "$cache_dir/$archive_name" "linkease-binary-$version_num/$le_binary.$binary_arch" || return $?
        [ -s "$transaction_dir/products/$le_binary" ] || { linkease_error "empty or missing $le_binary"; return 11; }
        chmod 0755 "$transaction_dir/products/$le_binary"
    done
    # Info-ZIP -Z1 is required on Linux. Read filenames with shell builtins, without awk/sed.
    installer_exec_native "$ZSETUP_BIN" capture -o "$transaction_dir/zip-members" --max-bytes 16384 --min-free-bytes "$INSTALLER_RESERVE" -- unzip -Z1 "$cache_dir/$mount_name" || {
        linkease_error 'unzip must support -Z1 member listing'; return 2;
    }
    : > "$transaction_dir/mount-files"
    le_member_count=0
    while IFS= read -r le_member || [ -n "$le_member" ]; do
        le_member_count=$((le_member_count + 1))
        [ "$le_member_count" -le "$INSTALLER_MAX_FILES" ] || return 11
        case "$le_member" in
            ''|*[!0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._+/-]*|/*|../*|*/../*|*/..|./*|*/./*|*/.|*//* )
                linkease_error 'invalid linkmount archive member'; return 11 ;;
        esac
        case "$le_member" in
            "$mount_arch/"|"$mount_arch/bin/") continue ;;
            "$mount_arch/bin/"*) le_output=${le_member#"$mount_arch/bin/"} ;;
            *) linkease_error 'unexpected linkmount archive layout'; return 11 ;;
        esac
        case "$le_output" in
            */) mkdir -p "$transaction_dir/products/linkmount/$le_output" ;;
            *)
                le_target="$transaction_dir/products/linkmount/$le_output"
                [ ! -e "$le_target" ] || { linkease_error 'duplicate linkmount archive member'; return 11; }
                mkdir -p "$(dirname "$le_target")"
                installer_extract_member "$le_target" unzip -p "$cache_dir/$mount_name" "$le_member" || return $?
                printf '%s\n' "$le_output" >> "$transaction_dir/mount-files"
                [ -s "$le_target" ] || { linkease_error 'empty linkmount archive file'; return 11; } ;;
        esac
    done < "$transaction_dir/zip-members"
    [ -s "$transaction_dir/products/linkmount/linkmount_bin" ] || { linkease_error 'linkmount_bin missing'; return 11; }
    chmod -R 0755 "$transaction_dir/products/linkmount"
    installer_exec_native "$ZSETUP_BIN" run -- "$transaction_dir/products/linkease" showVersion
}

linkease_register() {
    if [ "$SERVICE_HAD_UNIT" = 1 ]; then
        installer_exec_native "$ZSETUP_BIN" run -- "$INSTALLER_PREFIX/$SERVICE_OLD/bin/linkease" --serviceControl uninstall || return $?
    fi
    installer_exec_native "$ZSETUP_BIN" run -- "$SERVICE_EXEC" --serviceControl install
}

linkease_linux_metadata() {
    for le_tool in tar unzip; do
        command -v "$le_tool" >/dev/null 2>&1 || { linkease_error "$le_tool is required on Linux"; return 2; }
    done
    case "$arch" in x86_64) binary_arch=x86_64; mount_arch=amd64 ;; aarch64) binary_arch=aarch64; mount_arch=arm64 ;; armv7) binary_arch=arm; mount_arch=arm ;; esac
    version_num=${version_override:-1.7.5}
    relative_folder="LinuxStorage/$version_num"
    status "[2/4] Checking LinkEase $version_num ($arch)..."
    linkease_download "$relative_folder/SHA256SUMS" "$transaction_dir/sums" '' 1 || return $?
    archive_name="linkease-binary-$version_num.tar.gz"; mount_name="$mount_arch.zip"
    le_archive_sha=$("$ZSETUP_BIN" metadata sha256 "$transaction_dir/sums" "$archive_name") || return 11
    le_mount_sha=$("$ZSETUP_BIN" metadata sha256 "$transaction_dir/sums" "$mount_name") || return 11
}

linkease_linux() {
    linkease_linux_metadata || return $?
    installer_service_cached "$version_num" "$le_archive_sha:$le_mount_sha" || return $?
    if [ "$SERVICE_CACHED" = 0 ]; then
        status '[3/4] Downloading and verifying LinkEase and linkmount...'
        cache_dir=$transaction_dir
        linkease_download "$relative_folder/$archive_name" "$cache_dir/$archive_name" "$le_archive_sha" || return $?
        linkease_download "$relative_folder/$mount_name" "$cache_dir/$mount_name" "$le_mount_sha" || return $?
        linkease_unpack_linux || return $?
        installer_service_stage || return $?
        for le_binary in linkease heif-converter linkease-media; do installer_service_copy "$le_binary" || return $?; done
        while IFS= read -r le_output; do installer_service_copy "linkmount/$le_output" || return $?; done < "$transaction_dir/mount-files"
        installer_service_commit_version || return $?
    else
        installer_exec_native "$ZSETUP_BIN" run -- "$SERVICE_EXEC" showVersion || return $?
    fi
    status '[4/4] Installing and checking the LinkEase system service...'
    installer_service_activate || return $?
    status 'LinkEase installation completed'
}

linkease_openwrt() {
    command -v opkg >/dev/null 2>&1 || { linkease_error 'OpenWrt requires opkg'; return 2; }
    case "$arch" in x86_64|aarch64) package_arch=$arch ;; armv7) package_arch=arm ;; esac
    version_num=$version_override
    status "[2/4] Checking LinkEase OpenWrt version ($arch)..."
    if [ -z "$version_num" ]; then
        linkease_download Openwrt/VERSION "$transaction_dir/version" '' 1 || return $?
        version_num=$("$ZSETUP_BIN" metadata version "$transaction_dir/version") || return $?
    fi
    relative_folder="Openwrt/$version_num"
    linkease_download "$relative_folder/SHA256SUMS" "$transaction_dir/sums" '' 1 || return $?
    installer_package_cache "$version_num" "$arch" || return $?
    cache_dir=$PACKAGE_CACHE
    status '[3/4] Downloading and verifying LinkEase packages...'
    set -- "linkease_$package_arch.ipk" luci-app-linkease.ipk luci-i18n-linkease-zh-cn.ipk
    case "$arch" in x86_64|aarch64) set -- "$@" "linkmount_$arch.ipk" "ffmpeg-remux_$arch.ipk" ;; esac
    for le_package in "$@"; do linkease_verified_download "$le_package" || return $?; done
    status '[4/4] Installing LinkEase packages...'
    installer_package_command remove remove app-meta-linkease luci-i18n-linkease-zh-cn luci-app-linkease linkease || true
    for le_package in "$@"; do installer_package_command install install "$cache_dir/$le_package" || return $?; done
    installer_exec_native "$ZSETUP_BIN" run -- linkease showVersion || return $?
    status 'LinkEase installation completed; refresh LuCI if its menu is missing'
}

linkease_install() {
    : "${ZSETUP_BIN:?zsetup is required}" "${ZSETUP_SOURCE_BASES:?source group is required}"
    linkease_parse_args "$@" || return $?
    os=${ZSETUP_OS:-$("$ZSETUP_BIN" context get os)}
    package_manager=${ZSETUP_PACKAGE_MANAGER:-$("$ZSETUP_BIN" context get package_manager)}
    arch=${ZSETUP_ARCH:-$("$ZSETUP_BIN" context get arch)}
    case "$arch" in x86_64|aarch64|armv7) ;; *) linkease_error "unsupported architecture: $arch"; return 2 ;; esac
    case "$os:$package_manager" in
        openwrt:opkg) business_platform=openwrt ;;
        ubuntu:apt|debian:apt|centos:yum|centos:dnf|rhel:yum|rhel:dnf|linux:*) business_platform=linux ;;
        *) linkease_error "unsupported platform: $os/$package_manager"; return 2 ;;
    esac
    INSTALLER_REMOTE_APP=LinkEase
    if [ "$business_platform" = linux ]; then
        [ -z "${LINKEASE_APP_DIR:-}" ] || { linkease_error 'LINKEASE_APP_DIR is retired; use --installer-prefix for the protected installation root'; return 2; }
        ip_uid=$("$ZSETUP_BIN" storage / get effective_uid) || return 12
        if [ "$ip_uid" != 0 ]; then installer_privilege_install linkease "$@"; return $?; fi
        installer_service_prepare linkease || return $?
        linkease_linux || return $?
        installer_transaction_finish
        return $?
    fi
    installer_package_prepare linkease || return $?
    linkease_openwrt || return $?
    PACKAGE_PHASE=complete
    installer_transaction_finish
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
installer_download() {
    ib_relative=$1; ib_output=$2; ib_sha=${3:-}; ib_fresh=${4:-0}
    case "${ib_relative##*/}" in
        version.txt|VERSION|VERSION_LITE|SHA256SUMS) ib_metadata=1; ib_limit=16384 ;;
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
    "${il_app}_install" "$@"
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
linkease_error() { printf 'LinkEase: %s\n' "$*" >&2; }
linkease_usage() {
    printf '%s\n' 'Usage: linkease-install.sh [--version VERSION]' \
        'Linux: default version 1.7.5; installs LinkEase, media, HEIF converter and linkmount.' \
        'OpenWrt opkg: defaults to server VERSION; x86_64/aarch64/armv7 supported.'
    printf '%s\n' 'Linux systemd: user preparation + sudo -n commit (or explicit root), system scope; --installer-prefix PATH and --installer-work-dir PATH precede business arguments.'
}
linkease_parse_args() {
    version_override=${LINKEASE_VERSION:-}
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --version)
                [ "$#" -ge 2 ] && [ -n "$2" ] || { linkease_error '--version requires a value'; return 2; }
                version_override=$2; shift 2 ;;
            --version=*) version_override=${1#--version=}; [ -n "$version_override" ] || return 2; shift ;;
            *) linkease_error "unknown argument: $1"; return 2 ;;
        esac
    done
    case "$version_override" in '' ) ;; *[!0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._+-]*|.*|-*|+*|_*) linkease_error 'invalid version'; return 2 ;; esac
    [ "${#version_override}" -le 64 ] || return 2
}
linkease_download() { installer_download "$@"; }
linkease_verified_download() {
    le_name=$1
    le_digest=$("$ZSETUP_BIN" metadata sha256 "$transaction_dir/sums" "$le_name") || {
        linkease_error "invalid or missing SHA256 for $le_name"; return 11;
    }
    le_file="$cache_dir/$le_name"
    le_marker="$le_file.verified"
    installer_package_immutable "$le_marker" "$le_digest" || return $?
    linkease_download "$relative_folder/$le_name" "$le_file" "$le_digest" || return $?
    le_size=$(wc -c < "$le_file" | tr -d '[:space:]')
    printf '%s:%s\n' "$le_digest" "$le_size" > "$transaction_dir/verified"
    mv -f "$transaction_dir/verified" "$le_marker"
}
linkease_unpack_linux() {
    mkdir -p "$transaction_dir/products/linkmount"
    for le_binary in linkease heif-converter linkease-media; do
        installer_extract_member "$transaction_dir/products/$le_binary" tar -xOzf "$cache_dir/$archive_name" "linkease-binary-$version_num/$le_binary.$binary_arch" || return $?
        [ -s "$transaction_dir/products/$le_binary" ] || { linkease_error "empty or missing $le_binary"; return 11; }
        chmod 0755 "$transaction_dir/products/$le_binary"
    done
    installer_exec_native "$ZSETUP_BIN" capture -o "$transaction_dir/zip-members" --max-bytes 16384 --min-free-bytes "$INSTALLER_RESERVE" -- unzip -Z1 "$cache_dir/$mount_name" || {
        linkease_error 'unzip must support -Z1 member listing'; return 2;
    }
    : > "$transaction_dir/mount-files"
    le_member_count=0
    while IFS= read -r le_member || [ -n "$le_member" ]; do
        le_member_count=$((le_member_count + 1))
        [ "$le_member_count" -le "$INSTALLER_MAX_FILES" ] || return 11
        case "$le_member" in
            ''|*[!0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._+/-]*|/*|../*|*/../*|*/..|./*|*/./*|*/.|*//* )
                linkease_error 'invalid linkmount archive member'; return 11 ;;
        esac
        case "$le_member" in
            "$mount_arch/"|"$mount_arch/bin/") continue ;;
            "$mount_arch/bin/"*) le_output=${le_member#"$mount_arch/bin/"} ;;
            *) linkease_error 'unexpected linkmount archive layout'; return 11 ;;
        esac
        case "$le_output" in
            */) mkdir -p "$transaction_dir/products/linkmount/$le_output" ;;
            *)
                le_target="$transaction_dir/products/linkmount/$le_output"
                [ ! -e "$le_target" ] || { linkease_error 'duplicate linkmount archive member'; return 11; }
                mkdir -p "$(dirname "$le_target")"
                installer_extract_member "$le_target" unzip -p "$cache_dir/$mount_name" "$le_member" || return $?
                printf '%s\n' "$le_output" >> "$transaction_dir/mount-files"
                [ -s "$le_target" ] || { linkease_error 'empty linkmount archive file'; return 11; } ;;
        esac
    done < "$transaction_dir/zip-members"
    [ -s "$transaction_dir/products/linkmount/linkmount_bin" ] || { linkease_error 'linkmount_bin missing'; return 11; }
    chmod -R 0755 "$transaction_dir/products/linkmount"
    installer_exec_native "$ZSETUP_BIN" run -- "$transaction_dir/products/linkease" showVersion
}
linkease_register() {
    if [ "$SERVICE_HAD_UNIT" = 1 ]; then
        installer_exec_native "$ZSETUP_BIN" run -- "$INSTALLER_PREFIX/$SERVICE_OLD/bin/linkease" --serviceControl uninstall || return $?
    fi
    installer_exec_native "$ZSETUP_BIN" run -- "$SERVICE_EXEC" --serviceControl install
}
linkease_linux_metadata() {
    for le_tool in tar unzip; do
        command -v "$le_tool" >/dev/null 2>&1 || { linkease_error "$le_tool is required on Linux"; return 2; }
    done
    case "$arch" in x86_64) binary_arch=x86_64; mount_arch=amd64 ;; aarch64) binary_arch=aarch64; mount_arch=arm64 ;; armv7) binary_arch=arm; mount_arch=arm ;; esac
    version_num=${version_override:-1.7.5}
    relative_folder="LinuxStorage/$version_num"
    status "[2/4] Checking LinkEase $version_num ($arch)..."
    linkease_download "$relative_folder/SHA256SUMS" "$transaction_dir/sums" '' 1 || return $?
    archive_name="linkease-binary-$version_num.tar.gz"; mount_name="$mount_arch.zip"
    le_archive_sha=$("$ZSETUP_BIN" metadata sha256 "$transaction_dir/sums" "$archive_name") || return 11
    le_mount_sha=$("$ZSETUP_BIN" metadata sha256 "$transaction_dir/sums" "$mount_name") || return 11
}
linkease_linux() {
    linkease_linux_metadata || return $?
    installer_service_cached "$version_num" "$le_archive_sha:$le_mount_sha" || return $?
    if [ "$SERVICE_CACHED" = 0 ]; then
        status '[3/4] Downloading and verifying LinkEase and linkmount...'
        cache_dir=$transaction_dir
        linkease_download "$relative_folder/$archive_name" "$cache_dir/$archive_name" "$le_archive_sha" || return $?
        linkease_download "$relative_folder/$mount_name" "$cache_dir/$mount_name" "$le_mount_sha" || return $?
        linkease_unpack_linux || return $?
        installer_service_stage || return $?
        for le_binary in linkease heif-converter linkease-media; do installer_service_copy "$le_binary" || return $?; done
        while IFS= read -r le_output; do installer_service_copy "linkmount/$le_output" || return $?; done < "$transaction_dir/mount-files"
        installer_service_commit_version || return $?
    else
        installer_exec_native "$ZSETUP_BIN" run -- "$SERVICE_EXEC" showVersion || return $?
    fi
    status '[4/4] Installing and checking the LinkEase system service...'
    installer_service_activate || return $?
    status 'LinkEase installation completed'
}
linkease_openwrt() {
    command -v opkg >/dev/null 2>&1 || { linkease_error 'OpenWrt requires opkg'; return 2; }
    case "$arch" in x86_64|aarch64) package_arch=$arch ;; armv7) package_arch=arm ;; esac
    version_num=$version_override
    status "[2/4] Checking LinkEase OpenWrt version ($arch)..."
    if [ -z "$version_num" ]; then
        linkease_download Openwrt/VERSION "$transaction_dir/version" '' 1 || return $?
        version_num=$("$ZSETUP_BIN" metadata version "$transaction_dir/version") || return $?
    fi
    relative_folder="Openwrt/$version_num"
    linkease_download "$relative_folder/SHA256SUMS" "$transaction_dir/sums" '' 1 || return $?
    installer_package_cache "$version_num" "$arch" || return $?
    cache_dir=$PACKAGE_CACHE
    status '[3/4] Downloading and verifying LinkEase packages...'
    set -- "linkease_$package_arch.ipk" luci-app-linkease.ipk luci-i18n-linkease-zh-cn.ipk
    case "$arch" in x86_64|aarch64) set -- "$@" "linkmount_$arch.ipk" "ffmpeg-remux_$arch.ipk" ;; esac
    for le_package in "$@"; do linkease_verified_download "$le_package" || return $?; done
    status '[4/4] Installing LinkEase packages...'
    installer_package_command remove remove app-meta-linkease luci-i18n-linkease-zh-cn luci-app-linkease linkease || true
    for le_package in "$@"; do installer_package_command install install "$cache_dir/$le_package" || return $?; done
    installer_exec_native "$ZSETUP_BIN" run -- linkease showVersion || return $?
    status 'LinkEase installation completed; refresh LuCI if its menu is missing'
}
linkease_install() {
    : "${ZSETUP_BIN:?zsetup is required}" "${ZSETUP_SOURCE_BASES:?source group is required}"
    linkease_parse_args "$@" || return $?
    os=${ZSETUP_OS:-$("$ZSETUP_BIN" context get os)}
    package_manager=${ZSETUP_PACKAGE_MANAGER:-$("$ZSETUP_BIN" context get package_manager)}
    arch=${ZSETUP_ARCH:-$("$ZSETUP_BIN" context get arch)}
    case "$arch" in x86_64|aarch64|armv7) ;; *) linkease_error "unsupported architecture: $arch"; return 2 ;; esac
    case "$os:$package_manager" in
        openwrt:opkg) business_platform=openwrt ;;
        ubuntu:apt|debian:apt|centos:yum|centos:dnf|rhel:yum|rhel:dnf|linux:*) business_platform=linux ;;
        *) linkease_error "unsupported platform: $os/$package_manager"; return 2 ;;
    esac
    INSTALLER_REMOTE_APP=LinkEase
    if [ "$business_platform" = linux ]; then
        [ -z "${LINKEASE_APP_DIR:-}" ] || { linkease_error 'LINKEASE_APP_DIR is retired; use --installer-prefix for the protected installation root'; return 2; }
        ip_uid=$("$ZSETUP_BIN" storage / get effective_uid) || return 12
        if [ "$ip_uid" != 0 ]; then installer_privilege_install linkease "$@"; return $?; fi
        installer_service_prepare linkease || return $?
        linkease_linux || return $?
        installer_transaction_finish
        return $?
    fi
    installer_package_prepare linkease || return $?
    linkease_openwrt || return $?
    PACKAGE_PHASE=complete
    installer_transaction_finish
}
installer_dispatch linkease "$@"
ZSETUP_PRIVATE_ROOT_PROGRAM
}

bootstrap_and_run() {
    status "[1/4] Checking zsetup..."
    bootstrap_zsetup
    status "      zsetup $RESCUE_VERSION is ready"
    ZSETUP_BIN=$ACTIVE_ZSETUP
    ZSETUP_SOURCE_BASES=${ZSETUP_SOURCE_BASES:-$DIRECT_PRIMARY_BASES}
    ZSETUP_SOURCE_FALLBACK=${ZSETUP_SOURCE_FALLBACK-$DIRECT_FALLBACK_BASE}
    export ZSETUP_BIN ZSETUP_ARCH ZSETUP_SOURCE_BASES ZSETUP_SOURCE_FALLBACK
    installer_dispatch linkease "$@"
}

main() {
    case "${1:-}" in --help|-h) linkease_usage; return 0 ;; esac
    status 'LinkEase installer'
    if [ "${ZSETUP_INSTALLER_MODE:-0}" = 1 ]; then
        status '[1/4] zsetup is ready'
        installer_dispatch linkease "$@"
    else
        bootstrap_and_run "$@"
    fi
}
main "$@"
