#!/bin/sh
# Low-level transaction for an already verified, explicitly authorized application
# release. Stage first; public HTTPS readback/canary precede activate. No network
# calls or core/version changes are performed by this script.
set -eu
[ "$#" -eq 3 ] || { echo 'usage: install-app-release.sh stage|activate|rollback PACKAGE BINARY_ROOT' >&2; exit 2; }
mode=$1
src=${2%/}
dst=${3%/}
case "$mode" in stage|activate|rollback) ;; *) exit 2 ;; esac
die() { printf 'app release: %s\n' "$1" >&2; exit 1; }
case "$dst" in /*) ;; *) die 'absolute binary root required' ;; esac
case "$dst" in /|*/../*|*/..|*/./*|*/.|*\\*) die 'unsafe binary root' ;; esac
[ -d "$dst" ] && [ ! -L "$dst" ] || die 'binary root is missing or a symlink'
for dir in zsetup; do
 [ -d "$dst/$dir" ] && [ ! -L "$dst/$dir" ] || die 'application/core directory is missing or a symlink'
done
[ -f "$src/PACKAGE-SHA256SUMS" ] && [ ! -L "$src/PACKAGE-SHA256SUMS" ] || die 'missing package checksums'
(cd "$src" && sha256sum -c PACKAGE-SHA256SUMS >/dev/null) || die 'package checksum failed'
{
 IFS= read -r app
 IFS= read -r version
 IFS= read -r readiness
 IFS= read -r stable
 IFS= read -r old_config_sha
 IFS= read -r new_config_sha
 IFS= read -r installer_sha
} < "$src/release-state.txt" || die 'incomplete release state'
case "$app" in
 fastnet) entries='fastnet/fastnet-install.sh fastnet/install.sh' ;;
 linkspace) entries='linkspace/linkspace-install.sh' ;;
 *) die 'application is not enabled' ;;
esac
[ ! -L "$dst/$app" ] || die 'application directory is a symlink'
[ ! -e "$dst/$app" ] || [ -d "$dst/$app" ] || die 'application directory is invalid'
[ "$readiness" = ready-for-staging ] || die 'candidate has unresolved blockers'
case "$version" in ''|.*|stable|latest|*[!0-9A-Za-z._+-]*) die 'unsafe immutable version' ;; esac
case "$stable" in ''|*[!0-9.]*) die 'unsafe stable version' ;; esac
for sha in "$old_config_sha" "$new_config_sha" "$installer_sha"; do
 [ "${#sha}" -eq 64 ] || die 'invalid digest length'
 case "$sha" in *[!0-9a-f]*) die 'invalid digest' ;; esac
done
targets="$entries zsetup/config.json"
immutable="$app/$version/$app-install.sh"
snapshot="$dst/$app/.installer-rollback-$new_config_sha"
lock="$dst/zsetup/.windows-release-lock"
locked=0
switching=0
building_snapshot=0
stage_dir=''
checksum() {
 sum=$(sha256sum "$1") || return 1
 printf '%s\n' "${sum%% *}"
}
regular_or_missing() {
 [ ! -L "$1" ] || return 1
 [ ! -e "$1" ] || [ -f "$1" ]
}
restore() {
 for target in $targets; do
  if [ -f "$snapshot/previous/$target.missing" ]; then
   rm -f "$dst/$target" || return 1
  else
   cp -p "$snapshot/previous/$target" "$dst/$target.app-tmp-$$" || return 1
   mv -f "$dst/$target.app-tmp-$$" "$dst/$target" || return 1
  fi
 done
}
cleanup() {
 result=$?
 trap - 0 1 2 15
 if [ "$switching" -eq 1 ] && [ "$result" -ne 0 ]; then
  if restore; then
   printf 'app release: activation failed; previous %s entries and config restored\n' "$app" >&2
  else
   printf 'app release: restoration failed; retain snapshot %s\n' "$snapshot" >&2
  fi
 fi
 if [ "$locked" -eq 1 ]; then
  for target in $targets; do rm -f "$dst/$target.app-tmp-$$"; done
  if [ -n "$stage_dir" ]; then rm -rf "$stage_dir"; fi
  if [ "$building_snapshot" -eq 1 ]; then rm -rf "$snapshot"; fi
  rmdir "$lock" || result=1
 fi
 exit "$result"
}
trap cleanup 0
trap 'exit 1' 1 2 15
mkdir "$lock" 2>/dev/null || die 'another core/application publisher owns the lock'
locked=1
mkdir -p "$dst/$app"
for target in $targets; do regular_or_missing "$dst/$target" || die 'pointer is a symlink or non-regular file'; done
[ ! -L "$dst/zsetup/stable" ] && [ -f "$dst/zsetup/stable" ] || die 'stable is missing or a symlink'
[ "$(cat "$dst/zsetup/stable")" = "$stable" ] || die 'live core stable changed; prepare a fresh release'
[ -f "$src/immutable/$immutable" ] && [ ! -L "$src/immutable/$immutable" ] || die 'immutable source missing'
[ "$(checksum "$src/immutable/$immutable")" = "$installer_sha" ] || die 'immutable source digest differs'
for target in $entries; do
 [ "$(checksum "$src/pointers/$target")" = "$installer_sha" ] || die 'public entry differs from immutable installer'
done
[ "$(checksum "$src/pointers/zsetup/config.json")" = "$new_config_sha" ] || die 'config differs from release identity'
[ ! -L "$dst/$app/$version" ] || die 'immutable directory is a symlink'
if [ "$mode" = stage ]; then
 [ "$(checksum "$dst/zsetup/config.json")" = "$old_config_sha" ] || die 'live config changed; prepare a fresh release'
 [ ! -e "$snapshot" ] && [ ! -L "$snapshot" ] || die 'release snapshot already exists; refusing overwrite'
 if [ -e "$dst/$app/$version" ]; then
  [ -d "$dst/$app/$version" ] && [ ! -L "$dst/$immutable" ] && [ -f "$dst/$immutable" ] || die 'immutable target is invalid'
  [ "$(checksum "$dst/$immutable")" = "$installer_sha" ] || die 'immutable version has different bytes'
 fi
 mkdir "$snapshot"
 building_snapshot=1
 chmod 0700 "$snapshot"
 for target in $targets; do
  mkdir -p "$snapshot/previous/$(dirname "$target")"
  if [ -f "$dst/$target" ]; then
   cp -p "$dst/$target" "$snapshot/previous/$target"
  else
   : > "$snapshot/previous/$target.missing"
  fi
 done
 printf '%s\n' "$new_config_sha" > "$snapshot/identity"
 if [ ! -d "$dst/$app/$version" ]; then
  stage_dir="$dst/$app/.installer-stage-$$"
  mkdir "$stage_dir"
  cp "$src/immutable/$immutable" "$stage_dir/$app-install.sh"
  chmod 0755 "$stage_dir/$app-install.sh"
  [ "$(checksum "$stage_dir/$app-install.sh")" = "$installer_sha" ] || die 'staged installer checksum failed'
  chmod 0755 "$stage_dir"
  mv "$stage_dir" "$dst/$app/$version"
  stage_dir=''
 fi
 printf '%s\n' staged > "$snapshot/phase"
 building_snapshot=0
 printf 'Staged %s %s; public entries/config unchanged; snapshot %s\n' "$app" "$version" "$snapshot"
 exit 0
fi
[ -d "$snapshot" ] && [ ! -L "$snapshot" ] || die 'staged snapshot missing'
[ "$(cat "$snapshot/identity")" = "$new_config_sha" ] || die 'snapshot identity mismatch'
[ -f "$dst/$immutable" ] && [ ! -L "$dst/$immutable" ] && [ "$(checksum "$dst/$immutable")" = "$installer_sha" ] || die 'staged immutable installer changed'
if [ "$mode" = rollback ]; then
 [ "$(cat "$snapshot/phase")" = activated ] || die 'release is not active'
 for target in $targets; do
  cmp "$dst/$target" "$src/pointers/$target" >/dev/null || die 'refusing out-of-order rollback'
 done
 restore || die 'rollback failed; snapshot retained'
 printf '%s\n' rolled-back > "$snapshot/phase"
 printf 'Restored %s entries/config from %s; immutable installer retained\n' "$app" "$snapshot"
 exit 0
fi
[ "$(cat "$snapshot/phase")" = staged ] || die 'release is not staged'
[ "$(checksum "$dst/zsetup/config.json")" = "$old_config_sha" ] || die 'live config changed after staging'
for target in $targets; do
 if [ -f "$snapshot/previous/$target.missing" ]; then
  [ ! -e "$dst/$target" ] || die 'entry appeared after staging'
 else
  cmp "$snapshot/previous/$target" "$dst/$target" >/dev/null || die 'entry changed after staging'
 fi
done
switching=1
for target in $targets; do
 cp "$src/pointers/$target" "$dst/$target.app-tmp-$$"
 case "$target" in *.sh) chmod 0755 "$dst/$target.app-tmp-$$" ;; *) chmod 0644 "$dst/$target.app-tmp-$$" ;; esac
 mv -f "$dst/$target.app-tmp-$$" "$dst/$target"
done
printf '%s\n' activated > "$snapshot/phase"
switching=0
printf 'Activated %s %s; rollback snapshot %s\n' "$app" "$version" "$snapshot"
