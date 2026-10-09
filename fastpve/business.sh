# FastPVE owns the PVE menu; this installer only verifies and launches its binary.
fastpve_download() {
    fp_remote=$1
    fp_destination=$2
    fp_sha=${3:-}
    fp_fresh=${4:-0}
    set -- "$ZSETUP_BIN" download -o "$fp_destination"
    [ -z "$fp_sha" ] || set -- "$@" --sha256 "$fp_sha"
    [ "$fp_fresh" = 0 ] || set -- "$@" --no-cache
    [ -z "${ZSETUP_CA_FILE:-}" ] || set -- "$@" --ca-file "$ZSETUP_CA_FILE"
    for fp_base in $ZSETUP_SOURCE_BASES; do
        set -- "$@" "${fp_base%/}/fastpve/$fp_remote"
    done
    [ -z "${ZSETUP_SOURCE_FALLBACK:-}" ] || set -- "$@" --fallback-url "${ZSETUP_SOURCE_FALLBACK%/}/fastpve/$fp_remote"
    "$@"
}

fastpve_cleanup() {
    [ -z "${transaction_dir:-}" ] || rm -rf "$transaction_dir"
}

fastpve_size() {
    # wc is a base POSIX tool; shell splitting removes its padding without tr/sed.
    set -- $(wc -c < "$1")
    printf '%s' "$1"
}

fastpve_install() {
    : "${ZSETUP_BIN:?zsetup is required}"
    : "${ZSETUP_SOURCE_BASES:?zsetup source group is required}"
    fp_arch=${ZSETUP_ARCH:-$("$ZSETUP_BIN" context get arch)}
    fp_pm=${ZSETUP_PACKAGE_MANAGER:-$("$ZSETUP_BIN" context get package_manager)}
    if [ "$fp_arch" != x86_64 ] || [ "$fp_pm" != apt ]; then
        echo 'FastPVE: requires x86_64 PVE with apt' >&2
        return 2
    fi
    if ! command -v pveversion >/dev/null 2>&1 || ! pveversion >/dev/null 2>&1; then
        echo 'FastPVE: a working Proxmox VE installation is required' >&2
        return 2
    fi
    if [ "$(id -u)" != 0 ]; then
        echo 'FastPVE: run as root on the PVE host' >&2
        return 2
    fi

    umask 077
    work_dir=${ZSETUP_WORK_DIR:-/tmp/zsetup/fastpve}
    [ ! -L "$work_dir" ] || { echo 'FastPVE: cache directory must not be a symlink' >&2; return 2; }
    mkdir -p "$work_dir"
    chmod 0700 "$work_dir"
    transaction_dir=$(mktemp -d "$work_dir/.transaction.XXXXXX")
    trap fastpve_cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    status '[2/4] Checking FastPVE version...'
    fastpve_download version.txt "$transaction_dir/version.txt" '' 1
    fp_version=$("$ZSETUP_BIN" metadata version "$transaction_dir/version.txt" VERSION)
    fp_digest=$("$ZSETUP_BIN" metadata sha256 "$transaction_dir/version.txt" FASTPVE_SHA256)
    status "      FastPVE $fp_version"
    fp_name="FastPVE-$fp_version"
    cache_file="$work_dir/$fp_name"
    fp_marker="$cache_file.verified"
    for fp_path in "$cache_file" "$fp_marker"; do
        if [ -L "$fp_path" ] || { [ -e "$fp_path" ] && [ ! -f "$fp_path" ]; }; then
            echo 'FastPVE: cache files must be regular files, not symlinks or directories' >&2
            return 2
        fi
    done
    fp_cached=0
    # Private cache markers are written only after native SHA verification and version success.
    # As with other apps, normal reuse avoids hashing the complete binary again.
    if [ -x "$cache_file" ] && [ -f "$cache_file" ] && [ ! -L "$cache_file" ] && [ -f "$fp_marker" ] && [ ! -L "$fp_marker" ]; then
        fp_size=$(fastpve_size "$cache_file")
        fp_previous=
        if IFS= read -r fp_previous < "$fp_marker" && [ "$fp_previous" = "$fp_digest:$fp_size" ]; then
            fp_cached=1
        fi
    fi
    if [ "$fp_cached" = 1 ]; then
        status '[3/4] Using verified cached FastPVE'
        "$cache_file" version
    else
        status '[3/4] Downloading FastPVE...'
        fastpve_download "$fp_name" "$transaction_dir/product" "$fp_digest"
        chmod 0755 "$transaction_dir/product"
        "$transaction_dir/product" version
        fp_size=$(fastpve_size "$transaction_dir/product")
        printf '%s:%s\n' "$fp_digest" "$fp_size" > "$transaction_dir/verified"
        mv -f "$transaction_dir/product" "$cache_file"
        mv -f "$transaction_dir/verified" "$fp_marker"
        status '      Download complete'
    fi
    fastpve_cleanup
    transaction_dir=
    trap - EXIT HUP INT TERM
    status '[4/4] Starting FastPVE...'
    exec "$cache_file" "$@"
}
