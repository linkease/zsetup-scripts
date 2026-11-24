#!/bin/sh
# Low-level apps tree transaction bundled by publish-apps.py.
# Production operators use publish-apps.py so the public namespace cannot vary.
set -eu

[ "$#" -eq 3 ] || { echo 'usage: publish.sh stage|activate|rollback|verify APPS PUBLIC_APPS_ROOT' >&2; exit 2; }
mode=$1
src=${2%/}
dst=${3%/}
case "$mode" in stage|activate|rollback|verify) ;; *) exit 2 ;; esac
case "$src:$dst" in /*:/*) ;; *) echo 'apps publish: absolute paths required' >&2; exit 2 ;; esac
case "$dst" in /|*/../*|*/..|*/./*|*/.|*\\*) echo 'apps publish: unsafe public apps root' >&2; exit 2 ;; esac

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
die() { printf 'apps publish: %s\n' "$1" >&2; exit 1; }
[ -d "$src" ] && [ ! -L "$src" ] || die 'apps source must be a real directory'
[ -d "$dst" ] && [ ! -L "$dst" ] || die 'public apps root must be a real directory'
[ -f "$src/SHA256SUMS" ] && [ ! -L "$src/SHA256SUMS" ] || die 'missing SHA256SUMS'
(cd "$src" && sha256sum -c SHA256SUMS >/dev/null) || die 'source checksum failed'
release_id=$(sha256sum "$src/SHA256SUMS")
release_id=${release_id%% *}

if [ -n "${ZSETUP_PUBLISH_PREVALIDATED_RELEASE_ID:-}" ]; then
    [ "$ZSETUP_PUBLISH_PREVALIDATED_RELEASE_ID" = "$release_id" ] || die 'prevalidated release id does not match source'
else
    publish_python=${ZSETUP_PUBLISH_PYTHON:-python3}
    "$publish_python" -B "$root/scripts/check-public-tree.py" "$src" >/dev/null || die 'public tree policy failed'
    if [ "${ZSETUP_PUBLISH_ALLOW_UNVERSIONED:-0}" != 1 ]; then
        repo=$(git -C "$src" rev-parse --show-toplevel 2>/dev/null) || die 'production source must belong to Git'
        case "$src" in "$repo"/*) relative=${src#"$repo"/} ;; "$repo") relative=. ;; *) die 'cannot resolve apps source in Git' ;; esac
        [ -z "$(git -C "$repo" status --porcelain -- "$relative")" ] || die 'production apps source must be clean and reviewed'
    fi
fi

mkdir -p "$dst/zsetup"
[ ! -L "$dst/zsetup" ] || die 'zsetup destination is a symlink'
snapshot="$dst/zsetup/.apps-rollback-$release_id"
lock="$dst/zsetup/.apps-publish-lock"
mkdir "$lock" 2>/dev/null || die 'publication lock is held'
locked=1
switching=0

safe_destination() {
    relative=$1
    current=$dst
    old_ifs=$IFS; IFS=/; set -- $relative; IFS=$old_ifs
    for part in "$@"; do
        current=$current/$part
        [ ! -L "$current" ] || return 1
    done
}

safe_relative() {
    case "$1" in
        ''|/*|../*|*/../*|*/..|./*|*/./*|*/.|*\\*) return 1 ;;
        *) return 0 ;;
    esac
}

source_contains() {
    wanted=$1
    while IFS=' ' read -r ignored candidate; do
        [ "$candidate" = "$wanted" ] && return 0
    done < "$src/SHA256SUMS"
    return 1
}

atomic_copy() {
    from=$1
    to=$2
    safe_destination "${to#"$dst"/}" || return 1
    parent=$(dirname -- "$to")
    mkdir -p "$parent" || return 1
    temporary="$to.apps-tmp-$$"
    # Detached release archives may carry the build host's numeric owner and
    # group-write bits.  Create the destination as the publication account and
    # retain executable bits while ensuring public files are not writable by
    # group/other users.
    cp "$from" "$temporary" || return 1
    chmod go-w "$temporary" || return 1
    mv -f "$temporary" "$to" || return 1
}

is_immutable() {
    old_ifs=$IFS; IFS=/; set -- $1; IFS=$old_ifs
    if [ "$#" -ge 4 ] && [ "$2" = versions ]; then
        case "$3" in [0-9]*.[0-9]*.[0-9]*) return 0 ;; *) return 1 ;; esac
    fi
    [ "$#" -ge 3 ] || return 1
    case "$2" in [0-9]*.[0-9]*.[0-9]*) return 0 ;; *) return 1 ;; esac
}

restore() {
    [ -f "$snapshot/mutable-list" ] || return 1
    while IFS= read -r relative; do
        [ -n "$relative" ] || continue
        target=$dst/$relative
        if [ -f "$snapshot/missing/$relative" ]; then
            rm -f "$target" || return 1
        else
            atomic_copy "$snapshot/previous/$relative" "$target" || return 1
        fi
    done < "$snapshot/mutable-list"
}

cleanup() {
    result=$?
    trap - 0 1 2 15
    if [ "$switching" -eq 1 ] && [ "$result" -ne 0 ]; then
        if restore; then
            printf '%s\n' 'apps publish: activation failed; previous mutable tree restored' >&2
        else
            printf 'apps publish: activation and restoration failed; retain %s\n' "$snapshot" >&2
        fi
    fi
    rm -f "$dst"/*.apps-tmp-$$ "$dst"/*/*.apps-tmp-$$ "$dst"/*/*/*.apps-tmp-$$ 2>/dev/null || :
    if [ "$locked" -eq 1 ]; then rmdir "$lock" 2>/dev/null || result=1; fi
    exit "$result"
}
trap cleanup 0
trap 'exit 1' 1 2 15

if [ "$mode" = verify ]; then
    [ -f "$dst/SHA256SUMS" ] && [ ! -L "$dst/SHA256SUMS" ] || die 'published file missing: SHA256SUMS'
    cmp "$src/SHA256SUMS" "$dst/SHA256SUMS" >/dev/null || die 'published file differs: SHA256SUMS'
    while IFS=' ' read -r digest relative; do
        [ -n "$relative" ] || continue
        [ -f "$dst/$relative" ] && [ ! -L "$dst/$relative" ] || die "published file missing: $relative"
        cmp "$src/$relative" "$dst/$relative" >/dev/null || die "published file differs: $relative"
    done < "$src/SHA256SUMS"
    if [ -f "$snapshot/retired-list" ]; then
        while IFS= read -r relative; do
            [ -n "$relative" ] || continue
            [ ! -e "$dst/$relative" ] || die "retired published file remains: $relative"
        done < "$snapshot/retired-list"
    fi
    printf 'Verified apps release %s\n' "$release_id"
    exit 0
fi

if [ "$mode" = stage ]; then
    [ ! -e "$snapshot" ] && [ ! -L "$snapshot" ] || die 'release snapshot already exists'
    # Reject all immutable conflicts before recording mutable state.
    while IFS=' ' read -r digest relative; do
        [ -n "$relative" ] || continue
        if is_immutable "$relative" && [ -e "$dst/$relative" ]; then
            [ -f "$dst/$relative" ] && [ ! -L "$dst/$relative" ] || die "immutable target is invalid: $relative"
            cmp "$src/$relative" "$dst/$relative" >/dev/null || die "immutable version has different bytes: $relative"
        fi
    done < "$src/SHA256SUMS"
    mkdir "$snapshot"
    chmod 0700 "$snapshot"
    : > "$snapshot/mutable-list"
    : > "$snapshot/retired-list"
    relative=SHA256SUMS
    safe_destination "$relative" || die 'mutable target has a symlink ancestor: SHA256SUMS'
    printf '%s\n' "$relative" >> "$snapshot/mutable-list"
    if [ -e "$dst/$relative" ]; then
        [ -f "$dst/$relative" ] || die 'mutable target is not a regular file: SHA256SUMS'
        mkdir -p "$snapshot/previous"
        cp -p "$dst/$relative" "$snapshot/previous/$relative"
    else
        mkdir -p "$snapshot/missing"
        : > "$snapshot/missing/$relative"
    fi
    while IFS=' ' read -r digest relative; do
        [ -n "$relative" ] || continue
        if is_immutable "$relative"; then
            if [ ! -e "$dst/$relative" ]; then atomic_copy "$src/$relative" "$dst/$relative" || die "failed to stage $relative"; fi
        else
            safe_destination "$relative" || die "mutable target has a symlink ancestor: $relative"
            printf '%s\n' "$relative" >> "$snapshot/mutable-list"
            if [ -e "$dst/$relative" ]; then
                [ -f "$dst/$relative" ] || die "mutable target is not a regular file: $relative"
                mkdir -p "$snapshot/previous/$(dirname -- "$relative")"
                cp -p "$dst/$relative" "$snapshot/previous/$relative"
            else
                mkdir -p "$snapshot/missing/$(dirname -- "$relative")"
                : > "$snapshot/missing/$relative"
            fi
        fi
    done < "$src/SHA256SUMS"
    if [ -f "$dst/SHA256SUMS" ]; then
        while IFS=' ' read -r digest relative; do
            [ -n "$relative" ] || continue
            safe_relative "$relative" || die "unsafe retired path in current SHA256SUMS: $relative"
            source_contains "$relative" && continue
            target=$dst/$relative
            [ -e "$target" ] || continue
            safe_destination "$relative" || die "retired target has a symlink ancestor: $relative"
            [ -f "$target" ] && [ ! -L "$target" ] || die "retired target is not a regular file: $relative"
            actual=$(sha256sum "$target"); actual=${actual%% *}
            [ "$actual" = "$digest" ] || die "retired target differs from current manifest: $relative"
            printf '%s\n' "$relative" >> "$snapshot/mutable-list"
            printf '%s\n' "$relative" >> "$snapshot/retired-list"
            mkdir -p "$snapshot/previous/$(dirname -- "$relative")"
            cp -p "$target" "$snapshot/previous/$relative"
        done < "$dst/SHA256SUMS"
    fi
    printf '%s\n' staged > "$snapshot/phase"
    printf 'Staged apps release %s; mutable tree unchanged\n' "$release_id"
    exit 0
fi

[ -d "$snapshot" ] && [ ! -L "$snapshot" ] || die 'release snapshot is missing'
phase=$(cat "$snapshot/phase")

if [ "$mode" = rollback ]; then
    [ "$phase" = activated ] || die 'release is not active'
    while IFS= read -r relative; do
        [ -n "$relative" ] || continue
        if [ -f "$src/$relative" ]; then
            [ -f "$dst/$relative" ] && cmp "$src/$relative" "$dst/$relative" >/dev/null || die "later publication changed $relative"
        else
            [ ! -e "$dst/$relative" ] || die "later publication restored retired file $relative"
        fi
    done < "$snapshot/mutable-list"
    restore || die 'rollback failed'
    printf '%s\n' rolled-back > "$snapshot/phase"
    printf 'Rolled back mutable apps release %s; immutable versions retained\n' "$release_id"
    exit 0
fi

[ "$phase" = staged ] || die 'release is not staged'
while IFS= read -r relative; do
    [ -n "$relative" ] || continue
    if [ -f "$snapshot/missing/$relative" ]; then
        [ ! -e "$dst/$relative" ] || die "mutable target appeared after staging: $relative"
    else
        [ -f "$dst/$relative" ] && cmp "$snapshot/previous/$relative" "$dst/$relative" >/dev/null || die "mutable target changed after staging: $relative"
    fi
done < "$snapshot/mutable-list"

copy_count=0
switching=1
for activation_class in ordinary config entry; do
    while IFS= read -r relative; do
        [ -n "$relative" ] || continue
        [ -f "$src/$relative" ] || continue
        case "$relative" in
            zsetup/config.json) class=config ;;
            */*.sh|*/*.ps1) class=entry ;;
            *) class=ordinary ;;
        esac
        [ "$class" = "$activation_class" ] || continue
        atomic_copy "$src/$relative" "$dst/$relative" || exit 1
        copy_count=$((copy_count + 1))
        if [ "${ZSETUP_PUBLISH_FAIL_AFTER:-0}" -eq "$copy_count" ] 2>/dev/null && [ "$copy_count" -gt 0 ]; then
            printf 'apps publish: injected failure after %s files\n' "$copy_count" >&2
            exit 99
        fi
    done < "$snapshot/mutable-list"
done
while IFS= read -r relative; do
    [ -n "$relative" ] || continue
    rm -f "$dst/$relative" || exit 1
    parent=$(dirname -- "$dst/$relative")
    while [ "$parent" != "$dst" ]; do
        rmdir "$parent" 2>/dev/null || break
        parent=$(dirname -- "$parent")
    done
done < "$snapshot/retired-list"
printf '%s\n' activated > "$snapshot/phase"
switching=0
printf 'Activated apps release %s; rollback snapshot %s\n' "$release_id" "$snapshot"
