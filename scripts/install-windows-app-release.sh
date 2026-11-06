#!/bin/sh
# Server-side stage/activate/rollback primitive for an already reviewed Windows app.
set -eu
[ "$#" -eq 3 ] || { echo 'usage: install-windows-app-release.sh stage|activate|rollback PACKAGE BINARY_ROOT' >&2; exit 2; }
mode=$1
src=${2%/}
dst=${3%/}
case "$mode" in stage|activate|rollback) ;; *) exit 2 ;; esac
die() { printf 'Windows app release: %s\n' "$1" >&2; exit 1; }
case "$dst" in /*) ;; *) die 'absolute binary root required' ;; esac
case "$dst" in /|*/../*|*/..|*/./*|*/.|*\\*) die 'unsafe binary root' ;; esac
[ -d "$dst/zsetup" ] && [ ! -L "$dst/zsetup" ] || die 'zsetup directory is missing or a symlink'
[ -f "$src/PACKAGE-SHA256SUMS" ] && [ ! -L "$src/PACKAGE-SHA256SUMS" ] || die 'missing package checksums'
(cd "$src" && sha256sum -c PACKAGE-SHA256SUMS >/dev/null) || die 'package checksum failed'
{
 IFS= read -r app
 IFS= read -r version
 IFS= read -r stable
 IFS= read -r old_config_sha
 IFS= read -r new_config_sha
 IFS= read -r installer_sha
 IFS= read -r core_sha
} < "$src/release-state.txt" || die 'incomplete release state'
[ "$app" = scoop ] || die 'application is not enabled'
case "$version" in ''|.*|stable|latest|*[!0-9A-Za-z._+-]*) die 'unsafe immutable version' ;; esac
case "$stable" in ''|*[!0-9.]*) die 'unsafe stable version' ;; esac
for sha in "$old_config_sha" "$new_config_sha" "$installer_sha" "$core_sha"; do
 [ "${#sha}" -eq 64 ] || die 'invalid digest length'
 case "$sha" in *[!0-9a-f]*) die 'invalid digest' ;; esac
done
entries='scoop/scoop-install.ps1'
targets="$entries zsetup/config-windows.json"
immutable="scoop/$version/scoop-install.ps1"
snapshot="$dst/scoop/.installer-rollback-$new_config_sha"
lock="$dst/zsetup/.windows-app-release-lock"
locked=0
switching=0
building_snapshot=0
stage_dir=''
checksum() { sum=$(sha256sum "$1") || return 1; printf '%s\n' "${sum%% *}"; }
regular_or_missing() { [ ! -L "$1" ] || return 1; [ ! -e "$1" ] || [ -f "$1" ]; }
restore() {
 for target in $targets; do
  if [ -f "$snapshot/previous/$target.missing" ]; then rm -f "$dst/$target" || return 1
  else
   cp -p "$snapshot/previous/$target" "$dst/$target.app-tmp-$$" || return 1
   mv -f "$dst/$target.app-tmp-$$" "$dst/$target" || return 1
  fi
 done
}
cleanup() {
 result=$?
 trap - 0 1 2 15
 if [ "$switching" -eq 1 ] && [ "$result" -ne 0 ]; then restore || printf 'Windows app release: restoration failed; retain %s\n' "$snapshot" >&2; fi
 if [ "$locked" -eq 1 ]; then
  for target in $targets; do rm -f "$dst/$target.app-tmp-$$"; done
  [ -z "$stage_dir" ] || rm -rf "$stage_dir"
  [ "$building_snapshot" -eq 0 ] || rm -rf "$snapshot"
  rmdir "$lock" || result=1
 fi
 exit "$result"
}
trap cleanup 0
trap 'exit 1' 1 2 15
mkdir "$lock" 2>/dev/null || die 'another publisher owns the Windows application lock'
locked=1
[ ! -L "$dst/scoop" ] || die 'Scoop directory is a symlink'
[ ! -e "$dst/scoop" ] || [ -d "$dst/scoop" ] || die 'Scoop directory is invalid'
for target in $targets; do regular_or_missing "$dst/$target" || die 'pointer is a symlink or non-regular file'; done
[ -f "$dst/zsetup/stable-windows" ] && [ ! -L "$dst/zsetup/stable-windows" ] || die 'stable-windows is missing or a symlink'
[ "$(cat "$dst/zsetup/stable-windows")" = "$stable" ] || die 'Windows core stable changed; prepare a fresh release'
[ -f "$src/immutable/$immutable" ] && [ ! -L "$src/immutable/$immutable" ] || die 'immutable source missing'
[ "$(checksum "$src/immutable/$immutable")" = "$installer_sha" ] || die 'immutable source digest differs'
for target in $entries; do [ "$(checksum "$src/pointers/$target")" = "$installer_sha" ] || die 'public entry differs'; done
[ "$(checksum "$src/pointers/zsetup/config-windows.json")" = "$new_config_sha" ] || die 'Windows config differs from release identity'
mkdir -p "$dst/scoop"
if [ "$mode" = stage ]; then
 [ "$(checksum "$dst/zsetup/config-windows.json")" = "$old_config_sha" ] || die 'live Windows config changed'
 [ ! -e "$snapshot" ] && [ ! -L "$snapshot" ] || die 'release snapshot already exists'
 if [ -e "$dst/scoop/$version" ]; then
  [ -f "$dst/$immutable" ] && [ ! -L "$dst/$immutable" ] && [ "$(checksum "$dst/$immutable")" = "$installer_sha" ] || die 'immutable version conflict'
 fi
 mkdir "$snapshot"; building_snapshot=1; chmod 0700 "$snapshot"
 for target in $targets; do
  mkdir -p "$snapshot/previous/$(dirname "$target")"
  if [ -f "$dst/$target" ]; then cp -p "$dst/$target" "$snapshot/previous/$target"
  else : > "$snapshot/previous/$target.missing"; fi
 done
 printf '%s\n' "$new_config_sha" > "$snapshot/identity"
 if [ ! -d "$dst/scoop/$version" ]; then
  stage_dir="$dst/scoop/.installer-stage-$$"; mkdir "$stage_dir"
  cp "$src/immutable/$immutable" "$stage_dir/scoop-install.ps1"
  chmod 0644 "$stage_dir/scoop-install.ps1"
  [ "$(checksum "$stage_dir/scoop-install.ps1")" = "$installer_sha" ] || die 'staged installer checksum failed'
  mv "$stage_dir" "$dst/scoop/$version"; stage_dir=''
 fi
 printf '%s\n' staged > "$snapshot/phase"; building_snapshot=0
 printf 'Staged Scoop Windows app %s; pointers unchanged\n' "$version"
 exit 0
fi
[ -d "$snapshot" ] && [ ! -L "$snapshot" ] || die 'staged snapshot missing'
[ "$(cat "$snapshot/identity")" = "$new_config_sha" ] || die 'snapshot identity mismatch'
[ -f "$dst/$immutable" ] && [ "$(checksum "$dst/$immutable")" = "$installer_sha" ] || die 'staged immutable installer changed'
if [ "$mode" = rollback ]; then
 [ "$(cat "$snapshot/phase")" = activated ] || die 'release is not active'
 for target in $targets; do cmp "$dst/$target" "$src/pointers/$target" >/dev/null || die 'refusing out-of-order rollback'; done
 restore || die 'rollback failed; snapshot retained'
 printf '%s\n' rolled-back > "$snapshot/phase"
 printf 'Restored Scoop Windows entry/config; immutable candidate retained\n'
 exit 0
fi
[ "$(cat "$snapshot/phase")" = staged ] || die 'release is not staged'
[ "$(checksum "$dst/zsetup/config-windows.json")" = "$old_config_sha" ] || die 'live Windows config changed after staging'
for target in $targets; do
 if [ -f "$snapshot/previous/$target.missing" ]; then [ ! -e "$dst/$target" ] || die 'entry appeared after staging'
 else cmp "$snapshot/previous/$target" "$dst/$target" >/dev/null || die 'entry changed after staging'; fi
done
switching=1
for target in $targets; do
 cp "$src/pointers/$target" "$dst/$target.app-tmp-$$"
 chmod 0644 "$dst/$target.app-tmp-$$"
 mv -f "$dst/$target.app-tmp-$$" "$dst/$target"
done
printf '%s\n' activated > "$snapshot/phase"
switching=0
printf 'Activated Scoop Windows app %s; stable-windows/core unchanged\n' "$version"
