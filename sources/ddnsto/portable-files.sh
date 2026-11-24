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
