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
