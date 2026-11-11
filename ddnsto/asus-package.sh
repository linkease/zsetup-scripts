# Controlled ASUS package adapter; source asus-platform.sh before this module.
# ddnsto_asus_extract ARCHIVE DEST CHANNEL ARCH -> 0 success, nonzero rejection.
# Caller MUST verify ARCHIVE size + SHA256 against ddnsto_asus_package CHANNEL,
# keep it immutable through this call, and establish trusted owner state for
# DEST's parent and all ancestors. A private child of writable /tmp or
# /koolshare is NOT sufficient. This module does not establish that trust.
# Success leaves only three private staged files; it never runs package code.
# OS commands remain shell-function mockable; no stat/id/command dependency.
# Requires tar (-t/-v/-xO/-z), awk, wc, cmp, mkdir/rmdir, rm, chmod and shell
# ulimit/type. od is optional: absent od relies on the caller-verified pin;
# present but failing od is fatal. ARCH is armv7l or aarch64 (armsoft: armv7l).
# Limits: compressed archive/binary 12 MiB, other members 64 KiB, metadata
# extraction 64 B, each listing 16 KiB, declared aggregate 26 MiB.
# Validation covers the complete logical member listing reported by tar, not
# raw extension headers or bytes tar ignores after its end marker. Exact pins
# remain mandatory. Output is bounded; decompression CPU time is not bounded
# here. Caller owns cancellation, trusted storage, and subsequent installation.
# On failure only this call's fixed staging filenames are removed. An existing
# DEST is never reused/deleted. SIGKILL or I/O failure may leave private residue;
# never consume DEST unless the function returned zero.
_ddnsto_asus_package_tar() { tar "$@"; }
_ddnsto_asus_package_od() { od "$@"; }
_ddnsto_asus_package_has_od() { type od >/dev/null 2>&1; }

# Per-file kernel ceiling before opening output, then an exact byte ceiling.
# POSIX/ash uses 512-byte blocks; shells using 1024-byte blocks can transiently
# write up to twice the ceiling. No unbounded command substitution or pipeline
# masks tar failure. gzip/tar stream data; no archive tree is ever materialized.
_ddnsto_asus_package_capture() (
    ceiling=$1 output=$2; shift 2
    (ulimit -c 0 || exit 1
     ulimit -f "$(((ceiling + 511) / 512))" || exit 1
     _ddnsto_asus_package_tar "$@" > "$output" 2>/dev/null) || return 1
    bytes=$(wc -c < "$output") || return 1
    [ "$bytes" -gt 0 ] && [ "$bytes" -le "$ceiling" ]
)

_ddnsto_asus_package_member() (
    member=$1 output=$2 ceiling=$3
    expected=$(awk -v name="$member" '$6 == name {print $3}' .types) || return 1
    _ddnsto_asus_package_capture "$ceiling" "$output" -xOzf "$archive" "$member" || return 1
    [ "$(wc -c < "$output")" -eq "$expected" ]
)

ddnsto_asus_extract() (
    [ "$#" = 4 ] || return 2
    unset IFS # POSIX default splitting, independent of caller overrides.
    archive=$1 dest=$2 channel=$3 arch=$4
    # Use the existing platform authority, not a second marker/version table.
    pins=$(ddnsto_asus_package "$channel") || return 2
    set -f
    set -- $pins
    [ "$#" = 5 ] && [ "$2" = 4.2.8 ] || return 2
    version=$2 marker=$3
    case "$channel:$arch" in
        armsoft:armv7l) binary=ddnsto ;;
        armsoft:*) return 2 ;;
        *:armv7l) binary=ddnsto_arm ;;
        *:aarch64) binary=ddnsto_aarch64 ;;
        *) return 2 ;;
    esac
    # Absolute, unambiguous paths only. Ownership/ancestor permissions are the
    # caller storage adapter contract; reject symlinks as an extra guard.
    for path in "$archive" "$dest"; do
        case "$path" in /*) ;; *) return 2 ;; esac
        case "$path" in /|*/|*//*|*/./*|*/../*|*/.|*/..|*[!a-zA-Z0-9_./+-]*) return 2 ;; esac
        while [ "$path" != / ]; do
            [ ! -L "$path" ] || return 2
            path=${path%/*}; path=${path:-/}
        done
    done
    [ -f "$archive" ] || return 2
    bytes=$(wc -c < "$archive") || return 1
    [ "$bytes" -gt 0 ] && [ "$bytes" -le 12582912 ] || return 1
    LC_ALL=C; export LC_ALL
    unset TAR_OPTIONS GZIP
    umask 077
    mkdir "$dest" || return 1
    cd "$dest" || { rmdir "$dest"; return 1; }
    trap 'rm -f ddnsto Module_ddnsto.asp icon-ddnsto.png .names .types .valid .version; rmdir "$dest"' 0
    trap 'exit 1' 1 2 3 15
    _ddnsto_asus_package_capture 16384 .names -tzf "$archive" || return 1
    _ddnsto_asus_package_capture 16384 .types -tvzf "$archive" || return 1
    # GNU and BusyBox verbose listings have mode, owner/group, size, date,
    # time, name. Reject every other grammar rather than guessing a name.
    LC_ALL=C awk -v channel="$channel" '
        BEGIN {
            split("ddnsto/ ddnsto/webs/ ddnsto/res/ ddnsto/bin/ ddnsto/scripts/", dirs, " ")
            for (i in dirs) want[dirs[i]] = "d"
            split("webs/Module_ddnsto.asp res/icon-ddnsto.png .valid version install.sh uninstall.sh scripts/ddnsto_config.sh scripts/ddnsto_status.sh", files, " ")
            for (i in files) want["ddnsto/" files[i]] = "-"
            if (channel == "armsoft") {
                want["ddnsto/bin/ddnsto"] = "-"
                want["ddnsto/res/ddnsto_check.html"] = "-"
            } else {
                want["ddnsto/bin/ddnsto_arm"] = "-"
                want["ddnsto/bin/ddnsto_aarch64"] = "-"
            }
        }
        NR == FNR {
            if (!($0 in want) || seen[$0]++) bad = 1
            names[FNR] = $0
            count++
            next
        }
        {
            if (NF != 6 || $6 != names[FNR] || substr($1, 1, 1) != want[$6] ||
                length($1) != 10 || $3 !~ /^[0-9]+$/) bad = 1
            ceiling = ($6 ~ /^ddnsto\/bin\/ddnsto/) ? 12582912 : 65536
            if (want[$6] == "d") { if ($3 != 0) bad = 1 }
            else if ($3 < 1 || $3 > ceiling) bad = 1
            total += $3
            types++
        }
        END {
            for (name in want) if (seen[name] != 1) bad = 1
            if (count != 15 || types != count || total > 27262976) bad = 1
            exit bad
        }
    ' .names .types || return 1
    _ddnsto_asus_package_member ddnsto/.valid .valid 64 || return 1
    _ddnsto_asus_package_member ddnsto/version .version 64 || return 1
    printf '%s\n' "$marker" | cmp -s .valid - || return 1
    printf '%s\n' "$version" | cmp -s .version - || return 1
    _ddnsto_asus_package_member "ddnsto/bin/$binary" ddnsto 12582912 || return 1
    _ddnsto_asus_package_member ddnsto/webs/Module_ddnsto.asp Module_ddnsto.asp 65536 || return 1
    _ddnsto_asus_package_member ddnsto/res/icon-ddnsto.png icon-ddnsto.png 65536 || return 1
    if _ddnsto_asus_package_has_od; then
        header=$(_ddnsto_asus_package_od -An -v -tu1 -N20 ddnsto) || return 1
        set -- $header
        [ "$#" = 20 ] || return 1
        [ "$1 $2 $3 $4 $6 $7" = '127 69 76 70 1 1' ] || return 1
        class=$5
        shift 16
        case "$1 $2" in '2 0'|'3 0') ;; *) return 1 ;; esac
        case "$arch:$class:$3:$4" in armv7l:1:40:0|aarch64:2:183:0) ;; *) return 1 ;; esac
    fi
    chmod 700 ddnsto || return 1
    rm -f .names .types .valid .version || return 1
    trap - 0
)
