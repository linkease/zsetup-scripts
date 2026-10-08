fastnet_download() {
    remote_path=$1
    destination=$2
    expected_sha=${3:-}
    no_cache=${4:-0}
    set -- "$ZSETUP_BIN" download -o "$destination"
    [ -z "$expected_sha" ] || set -- "$@" --sha256 "$expected_sha"
    [ "$no_cache" -eq 0 ] || set -- "$@" --no-cache
    [ -z "${ZSETUP_CA_FILE:-}" ] || set -- "$@" --ca-file "$ZSETUP_CA_FILE"
    for base in $ZSETUP_SOURCE_BASES; do
        set -- "$@" "${base%/}/fastnet/$remote_path"
    done
    [ -z "${ZSETUP_SOURCE_FALLBACK:-}" ] || set -- "$@" --fallback-url "${ZSETUP_SOURCE_FALLBACK%/}/fastnet/$remote_path"
    "$@"
}

fastnet_install() {
    : "${ZSETUP_BIN:?zsetup is required}"
    : "${ZSETUP_SOURCE_BASES:?zsetup source group is required}"
    case "${ZSETUP_ARCH:-$(uname -m)}" in
        x86_64|amd64) arch_suffix=amd64; sha_key=FASTNET_AMD64_SHA256 ;;
        aarch64|arm64) arch_suffix=arm64; sha_key=FASTNET_ARM64_SHA256 ;;
        armv7l|armv7) arch_suffix=armv7; sha_key=FASTNET_ARMV7_SHA256 ;;
        *) echo "FastNet: unsupported architecture" >&2; return 2 ;;
    esac

    work_dir=${ZSETUP_WORK_DIR:-/tmp/zsetup/fastnet}
    mkdir -p "$work_dir"
    version_file="$work_dir/version.txt"
    status "[2/4] Checking FastNet version..."
    fastnet_download version.txt "$version_file" "" 1
    version=$("$ZSETUP_BIN" metadata version "$version_file" VERSION)
    expected_sha=$("$ZSETUP_BIN" metadata sha256 "$version_file" "$sha_key")
    if [ -z "$version" ] || [ -z "$expected_sha" ]; then
        echo "FastNet: version metadata is incomplete" >&2
        return 11
    fi
    status "      FastNet $version"

    binary_name="FastNet-${version}.${arch_suffix}"
    cache_file="$work_dir/$binary_name"
    if [ ! -x "$cache_file" ] || ! "$cache_file" version >/dev/null 2>&1; then
        status "[3/4] Downloading FastNet..."
        candidate="$work_dir/.${binary_name}.candidate.$$"
        trap 'unlink "$candidate" 2>/dev/null || true' EXIT HUP INT TERM
        fastnet_download "$binary_name" "$candidate" "$expected_sha" 0
        chmod 0755 "$candidate"
        "$candidate" version >/dev/null
        mv -f "$candidate" "$cache_file"
        trap - EXIT HUP INT TERM
        status "      Download complete"
    else
        status "[3/4] FastNet is already downloaded"
    fi
    "$cache_file" version
    status "[4/4] Starting FastNet..."
    exec "$cache_file" "$@"
}
