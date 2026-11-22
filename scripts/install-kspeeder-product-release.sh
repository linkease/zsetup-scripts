#!/bin/sh
# Low-level immutable product mirror transaction. No network calls and no
# deletion of historical files. Use publish-kspeeder-products.py in production.
set -eu

[ "$#" -eq 3 ] || { echo 'usage: install-kspeeder-product-release.sh stage|activate|verify|rollback PACKAGE BINARY_ROOT' >&2; exit 2; }
mode=$1
src=${2%/}
binary=${3%/}
case "$mode" in stage|activate|verify|rollback) ;; *) exit 2 ;; esac
die() { printf 'kspeeder product release: %s\n' "$1" >&2; exit 1; }
case "$src:$binary" in /*:/*) ;; *) die 'absolute paths required' ;; esac
case "$binary" in /|*/../*|*/..|*/./*|*/.|*\\*) die 'unsafe binary root' ;; esac
[ -d "$src" ] && [ ! -L "$src" ] || die 'package directory is missing or a symlink'
[ -d "$binary" ] && [ ! -L "$binary" ] || die 'binary root is missing or a symlink'
[ -f "$src/PACKAGE-SHA256SUMS" ] && [ ! -L "$src/PACKAGE-SHA256SUMS" ] || die 'package checksums are missing'
(cd "$src" && sha256sum -c PACKAGE-SHA256SUMS >/dev/null) || die 'package checksum failed'

IFS= read -r version < "$src/release-state.txt" || die 'release version is missing'
release_id=$(sed -n '2p' "$src/release-state.txt")
case "$version" in [0-9]*.[0-9]*.[0-9]*) ;; *) die 'unsafe product version' ;; esac
[ "${#release_id}" -eq 64 ] || die 'invalid release identity'
case "$release_id" in *[!0-9a-f]*) die 'invalid release identity' ;; esac

product=$binary/kspeeder
immutable_src=$src/immutable/kspeeder/$version
immutable_dst=$product/$version
pointers='version.txt ks-cli-version.txt'
snapshot=$product/.product-rollback-$release_id
lock=$product/.product-publish-lock
locked=0
switching=0
stage_dir=

mkdir -p "$product"
[ -d "$product" ] && [ ! -L "$product" ] || die 'product root is invalid'
mkdir "$lock" 2>/dev/null || die 'publication lock is held'
locked=1

checksum() {
    value=$(sha256sum "$1") || return 1
    printf '%s\n' "${value%% *}"
}

verify_immutable() {
    [ -d "$1" ] && [ ! -L "$1" ] || return 1
    [ -f "$1/SHA256SUMS" ] && [ ! -L "$1/SHA256SUMS" ] || return 1
    (cd "$1" && sha256sum -c SHA256SUMS >/dev/null) || return 1
}

restore() {
    for pointer in $pointers; do
        target=$product/$pointer
        if [ -f "$snapshot/previous/$pointer.missing" ]; then
            rm -f "$target" || return 1
        else
            cp -p "$snapshot/previous/$pointer" "$target.product-tmp-$$" || return 1
            mv -f "$target.product-tmp-$$" "$target" || return 1
        fi
    done
}

cleanup() {
    result=$?
    trap - 0 1 2 15
    if [ "$switching" -eq 1 ] && [ "$result" -ne 0 ]; then
        restore || printf 'kspeeder product release: restoration failed; retain %s\n' "$snapshot" >&2
    fi
    [ -z "$stage_dir" ] || rm -rf "$stage_dir"
    rm -f "$product"/*.product-tmp-$$ 2>/dev/null || :
    if [ "$locked" -eq 1 ]; then rmdir "$lock" 2>/dev/null || result=1; fi
    exit "$result"
}
trap cleanup 0
trap 'exit 1' 1 2 15

verify_immutable "$immutable_src" || die 'package immutable tree failed verification'
for pointer in $pointers; do
    [ -f "$src/pointers/kspeeder/$pointer" ] && [ ! -L "$src/pointers/kspeeder/$pointer" ] || die "package pointer is missing: $pointer"
    cmp "$src/pointers/kspeeder/$pointer" "$immutable_src/$pointer" >/dev/null || die "pointer differs from immutable metadata: $pointer"
done

if [ "$mode" = verify ]; then
    verify_immutable "$immutable_dst" || die 'published immutable tree failed verification'
    for pointer in $pointers; do
        [ -f "$product/$pointer" ] && [ ! -L "$product/$pointer" ] || die "published pointer is missing: $pointer"
        cmp "$src/pointers/kspeeder/$pointer" "$product/$pointer" >/dev/null || die "published pointer differs: $pointer"
    done
    printf 'Verified KSpeeder product release %s (%s)\n' "$version" "$release_id"
    exit 0
fi

if [ "$mode" = stage ]; then
    [ ! -e "$snapshot" ] && [ ! -L "$snapshot" ] || die 'release snapshot already exists'
    if [ -e "$immutable_dst" ] || [ -L "$immutable_dst" ]; then
        verify_immutable "$immutable_dst" || die 'existing immutable version is invalid'
        cmp "$immutable_src/SHA256SUMS" "$immutable_dst/SHA256SUMS" >/dev/null || die 'immutable version has different bytes'
    fi
    mkdir "$snapshot"
    chmod 0700 "$snapshot"
    mkdir "$snapshot/previous"
    for pointer in $pointers; do
        [ ! -L "$product/$pointer" ] || die "published pointer is a symlink: $pointer"
        if [ -f "$product/$pointer" ]; then
            cp -p "$product/$pointer" "$snapshot/previous/$pointer"
        elif [ -e "$product/$pointer" ]; then
            die "published pointer is not a regular file: $pointer"
        else
            : > "$snapshot/previous/$pointer.missing"
        fi
    done
    if [ ! -d "$immutable_dst" ]; then
        stage_dir=$product/.product-stage-$$
        cp -R "$immutable_src" "$stage_dir"
        find "$stage_dir" -type f -exec chmod go-w {} \;
        verify_immutable "$stage_dir" || die 'staged immutable tree failed verification'
        mv "$stage_dir" "$immutable_dst"
        stage_dir=
    fi
    printf '%s\n' staged > "$snapshot/phase"
    printf 'Staged KSpeeder product release %s; root pointers unchanged\n' "$version"
    exit 0
fi

[ -d "$snapshot" ] && [ ! -L "$snapshot" ] || die 'release snapshot is missing'
phase=$(cat "$snapshot/phase")
verify_immutable "$immutable_dst" || die 'staged immutable tree changed'

if [ "$mode" = rollback ]; then
    [ "$phase" = activated ] || die 'release is not active'
    for pointer in $pointers; do
        cmp "$product/$pointer" "$src/pointers/kspeeder/$pointer" >/dev/null || die 'later publication changed root pointers'
    done
    restore || die 'rollback failed'
    printf '%s\n' rolled-back > "$snapshot/phase"
    printf 'Rolled back KSpeeder root pointers; immutable %s retained\n' "$version"
    exit 0
fi

[ "$phase" = staged ] || die 'release is not staged'
for pointer in $pointers; do
    if [ -f "$snapshot/previous/$pointer.missing" ]; then
        [ ! -e "$product/$pointer" ] || die 'root pointer appeared after staging'
    else
        cmp "$snapshot/previous/$pointer" "$product/$pointer" >/dev/null || die 'root pointer changed after staging'
    fi
done
switching=1
for pointer in $pointers; do
    cp "$src/pointers/kspeeder/$pointer" "$product/$pointer.product-tmp-$$"
    chmod 0644 "$product/$pointer.product-tmp-$$"
    mv -f "$product/$pointer.product-tmp-$$" "$product/$pointer"
done
printf '%s\n' activated > "$snapshot/phase"
switching=0
printf 'Activated KSpeeder product release %s; rollback snapshot %s\n' "$version" "$snapshot"
