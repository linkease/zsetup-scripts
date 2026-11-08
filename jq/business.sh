# jq release policy. Native zsetup owns HTTPS, SHA256, size and download caching.
jq_resolve() {
    jq_os=${ZSETUP_OS:-}
    if [ -z "$jq_os" ]; then
        case "$(uname -s)" in Linux) jq_os=linux ;; Darwin) jq_os=macos ;; MINGW*|MSYS*|CYGWIN*) jq_os=windows ;; *) return 2 ;; esac
    fi
    case "$jq_os" in linux|ubuntu|debian|istoreos|openwrt) jq_os=linux ;; darwin|macos) jq_os=macos ;; windows) ;; *) return 2 ;; esac
    jq_arch=${ZSETUP_ARCH:-$(uname -m)}
    case "$jq_arch" in x86_64|amd64) jq_arch=amd64 ;; aarch64|arm64) jq_arch=arm64 ;; armv7|armv7l) jq_arch=armhf ;; i386|i686|x86) jq_arch=i386 ;; esac
    jq_release_artifact "$jq_os" "$jq_arch" || { printf '%s\n' 'jq: no verified artifact for this platform/architecture' >&2; return 2; }
}

jq_install() {
    jq_resolve || return $?
    if [ "${1:-}" = --plan ] && [ "$#" = 1 ]; then
        printf 'application=jq\nversion=%s\nplatform=%s\nartifact=%s\nsha256=%s\nsize=%s\nurl=%s\n' \
            "$jq_version" "$jq_os" "$jq_artifact" "$jq_sha" "$jq_size" "$jq_url"
        return
    fi
    jq_prefix=${ZSETUP_INSTALL_PREFIX:-$HOME/.local/lib/linkease/jq}; jq_action=install
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --installer-prefix) [ "$#" -ge 2 ] || return 2; jq_prefix=$2; shift 2 ;;
            --remove) jq_action=remove; shift ;;
            *) printf '%s\n' 'jq: unsupported installer argument' >&2; return 2 ;;
        esac
    done
    : "${ZSETUP_BIN:?an existing zsetup is required}"
    if [ "$jq_os" = windows ] && command -v cygpath >/dev/null 2>&1; then
        ZSETUP_BIN=$(cygpath -u "$ZSETUP_BIN")
        jq_prefix=$(cygpath -u "$jq_prefix")
    fi
    jq_extension=; [ "$jq_os" != windows ] || jq_extension=.exe
    jq_command="$HOME/.local/bin/jq$jq_extension"
    jq_check_path "$jq_prefix" && jq_check_path "${jq_command%/*}" || return 2
    [ ! -L "$jq_prefix/.managed" ] || return 2
    if [ -e "$jq_prefix/.managed" ]; then
        [ "$(cat "$jq_prefix/.managed")" = jq ] || return 2
    else
        [ "$jq_action" != remove ] || return 0
        [ ! -e "$jq_command" ] && [ ! -L "$jq_command" ] || return 2
        for jq_entry in "$jq_prefix"/* "$jq_prefix"/.[!.]* "$jq_prefix"/..?*; do
            [ ! -e "$jq_entry" ] && [ ! -L "$jq_entry" ] || return 2
        done
        umask 077; mkdir -p "$jq_prefix"
        (set -C; printf 'jq\n' > "$jq_prefix/.managed") || return 2
    fi
    [ ! -L "$jq_prefix/current" ] || return 2
    jq_old=
    if [ -e "$jq_prefix/current" ]; then
        jq_old=$(cat "$jq_prefix/current")
        jq_valid_version "$jq_old" || return 2
    fi
    if [ -e "$jq_command" ] || [ -L "$jq_command" ]; then
        [ ! -L "$jq_command" ] && [ -f "$jq_command" ] && [ -n "$jq_old" ] || return 2
        jq_check_version_path "$jq_old" || return 2
        cmp -s "$jq_command" "$jq_prefix/versions/$jq_old/bin/jq$jq_extension" || {
            printf '%s\n' 'jq: preserve the conflicting command' >&2; return 11;
        }
    fi
    umask 077
    mkdir "$jq_prefix/.install-lock" || return 2
    jq_stage=; jq_committed=0; jq_replacing=0
    trap 'jq_cleanup' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    jq_stage=$(mktemp -d "$jq_prefix/.download.XXXXXX") || return 12
    if [ "$jq_action" = remove ]; then jq_remove; return $?; fi
    jq_check_version_path "$jq_version" || return 2
    jq_bin="$jq_prefix/versions/$jq_version/bin/jq$jq_extension"
    jq_output="$jq_stage/product"
    # Let native zsetup revalidate an owned existing file through its SHA cache.
    [ ! -f "$jq_bin" ] || jq_output=$jq_bin
    # Prepared bytes are a cache input, validated by native zsetup against the
    # original release SHA256/size. Never overwrite an owned version with an
    # unvalidated cache, and never follow an external cache symlink.
    if [ "$jq_output" != "$jq_bin" ] && [ -n "${JQ_ARTIFACT_CACHE:-}" ]; then
        [ -f "$JQ_ARTIFACT_CACHE" ] && [ ! -L "$JQ_ARTIFACT_CACHE" ] || return 2
        cp "$JQ_ARTIFACT_CACHE" "$jq_output" || return 12
    fi
    set -- "$ZSETUP_BIN" download -o "$jq_output" --sha256 "$jq_sha" --size "$jq_size"
    [ -z "${ZSETUP_CA_FILE:-}" ] || set -- "$@" --ca-file "$ZSETUP_CA_FILE"
    if [ -n "${JQ_DOWNLOAD_BASE:-}" ]; then
        case "$JQ_DOWNLOAD_BASE" in https://*) ;; *) return 2 ;; esac
        jq_url="${JQ_DOWNLOAD_BASE%/}/$jq_artifact"
    fi
    "$@" "$jq_url" || return $?
    chmod 0755 "$jq_output" || return 12
    [ "$("$jq_output" --version | tr -d '\r')" = "jq-$jq_version" ] || return 11
    "$jq_output" -ne '("abc"|test("^a")) and (("abc"|match("^a").string)=="a") and (("abc"|sub("^a";"x"))=="xbc") and (({text:"中文"}|tojson|fromjson|.text)=="中文")' || return 11
    mkdir -p "${jq_bin%/*}" "${jq_command%/*}" || return 12
    if [ "$jq_output" != "$jq_bin" ]; then mv "$jq_output" "$jq_bin" || return 12; fi
    printf '%s:%s\n' "$jq_sha" "$jq_size" > "$jq_bin.verified" || return 12
    [ ! -f "$jq_command" ] || cp "$jq_command" "$jq_stage/old-command" || return 12
    cp "$jq_bin" "${jq_command}.candidate.$$" || return 12
    chmod 0755 "${jq_command}.candidate.$$"
    jq_replacing=1
    mv -f "${jq_command}.candidate.$$" "$jq_command" || return 12
    printf '%s\n' "$jq_version" > "$jq_stage/current"
    mv -f "$jq_stage/current" "$jq_prefix/current" || return 12
    jq_committed=1
    printf 'application=jq\nversion=%s\ncommand=%s\nexecutable=%s\nfunctionalValidation=passed\n' "$jq_version" "$jq_command" "$jq_bin"
}

jq_file_sha() {
    if command -v sha256sum >/dev/null 2>&1; then jq_digest=$(sha256sum < "$1") || return 11
    elif command -v shasum >/dev/null 2>&1; then jq_digest=$(shasum -a 256 < "$1") || return 11
    else printf '%s\n' 'jq removal requires native SHA256 support' >&2; return 127; fi
    jq_digest=${jq_digest%% *}
}

jq_remove() {
    # Complete validation precedes every deletion; configuration and staging
    # outside the owned versions remain in place.
    [ ! -L "$jq_prefix/versions" ] || return 11
    for jq_dir in "$jq_prefix"/versions/* "$jq_prefix"/versions/.[!.]* "$jq_prefix"/versions/..?*; do
        [ -e "$jq_dir" ] || [ -L "$jq_dir" ] || continue
        jq_valid_version "${jq_dir##*/}" || return 11
        jq_check_version_path "${jq_dir##*/}" || return 11
        [ -d "$jq_dir/bin" ] || return 11
        jq_file="$jq_dir/bin/jq$jq_extension"
        [ -f "$jq_file" ] && [ -f "$jq_file.verified" ] || return 11
        jq_record=$(cat "$jq_file.verified")
        jq_record_sha=${jq_record%%:*};jq_record_size=${jq_record#*:}
        case "$jq_record_sha" in *[!a-f0-9]*|'') return 11 ;; esac
        [ "${#jq_record_sha}" = 64 ] || return 11
        jq_file_sha "$jq_file" || return $?
        [ "$jq_digest" = "$jq_record_sha" ] && [ "$(wc -c < "$jq_file" | tr -d ' ')" = "$jq_record_size" ] || return 11
        for jq_entry in "$jq_dir"/* "$jq_dir"/.[!.]* "$jq_dir"/..?*; do
            [ -e "$jq_entry" ] || [ -L "$jq_entry" ] || continue
            [ "$jq_entry" = "$jq_dir/bin" ] || return 11
        done
        for jq_entry in "$jq_dir/bin"/* "$jq_dir/bin"/.[!.]* "$jq_dir/bin"/..?*; do
            [ -e "$jq_entry" ] || [ -L "$jq_entry" ] || continue
            case "$jq_entry" in "$jq_file"|"$jq_file.verified") ;; *) return 11 ;; esac
        done
    done
    for jq_dir in "$jq_prefix"/versions/*; do
        [ -d "$jq_dir" ] || continue
        rm -f "$jq_dir/bin/jq$jq_extension" "$jq_dir/bin/jq$jq_extension.verified"
        rmdir "$jq_dir/bin" "$jq_dir" || return 12
    done
    [ ! -d "$jq_prefix/versions" ] || rmdir "$jq_prefix/versions" || return 12
    rm -f "$jq_command" "$jq_prefix/current" "$jq_prefix/.managed"
    jq_committed=1
    printf 'application=jq\nstatus=removed\n'
}

jq_valid_version() {
    case "$1" in ''|*[!0-9.]*|.*|*..*|*.) return 2 ;; esac
    jq_remaining=${1#*.}; [ "$jq_remaining" != "$1" ] || return 2
    jq_remaining=${jq_remaining#*.}; case "$jq_remaining" in ''|*.*) return 2 ;; esac
}

jq_check_path() {
    case "$1" in /*) ;; *) return 2 ;; esac
    case "$1" in /|/bin|/sbin|/usr|/usr/*|/etc|/etc/*|*/../*|*/..|*/./*|*/.|*//*|*'
'*|*''*) return 2 ;; esac
    jq_parent=$1
    while [ "$jq_parent" != / ]; do
        [ ! -L "$jq_parent" ] || return 2
        [ ! -e "$jq_parent" ] || [ -d "$jq_parent" ] || return 2
        jq_parent=${jq_parent%/*}; [ -n "$jq_parent" ] || jq_parent=/
    done
}

jq_check_version_path() {
    jq_valid_version "$1" || return 2
    jq_check_path "$jq_prefix/versions/$1/bin" || return 2
    jq_file="$jq_prefix/versions/$1/bin/jq$jq_extension"
    for jq_path in "$jq_file" "$jq_file.verified"; do
        [ ! -L "$jq_path" ] || return 2
        [ ! -e "$jq_path" ] || [ -f "$jq_path" ] || return 2
    done
}

jq_cleanup() {
    if [ "$jq_replacing" = 1 ] && [ "$jq_committed" = 0 ]; then
        if [ -f "$jq_stage/old-command" ]; then mv -f "$jq_stage/old-command" "$jq_command"; else rm -f "$jq_command"; fi
    fi
    rm -f "${jq_command}.candidate.$$"
    [ -z "$jq_stage" ] || rm -rf "$jq_stage"
    rmdir "$jq_prefix/.install-lock"
}
