#!/bin/sh
# Rollback only this exact release; refuses later publishers. Immutable files stay.
set -eu
ssh -o BatchMode=yes root@192.168.3.1 sh -s <<'LINKSPACE_ROLLBACK'
set -eu
root=/mnt/sata3-1/istore-data/public_html/binary
app="$root/linkspace"
snapshot="$app/.installer-rollback-d8839c8dc1efd18a4017962b81caa5addb0cdc294d5bfc540b25c545765731ed"
product="$app/.binary-rollback-v0.1.0"
lock="$root/zsetup/.windows-release-lock"
mkdir "$lock" || { echo 'another publisher owns the lock' >&2; exit 1; }
cleanup() { result=$?; trap - 0; rm -f "$root/zsetup/config.json.rollback-$$" "$app/.version-rollback-$$"; rmdir "$lock" || result=1; exit "$result"; }
trap cleanup 0
trap 'exit 1' 1 2 15
checksum() { sha256sum "$1" | cut -d ' ' -f 1; }
[ "$(cat "$root/zsetup/stable")" = 0.5.1 ]
[ "$(checksum "$root/zsetup/config.json")" = d8839c8dc1efd18a4017962b81caa5addb0cdc294d5bfc540b25c545765731ed ]
[ "$(checksum "$app/linkspace-install.sh")" = caa0c486544d498164d55473a7a0e8fabf18818597108c628870ec495d62a022 ]
[ "$(checksum "$app/version.txt")" = e0b6b899263d5963a314b8e7e3c2097f4bc60877b3a2d028181febe781a83a86 ]
[ "$(cat "$snapshot/phase")" = activated ]
[ "$(cat "$product/phase")" = activated ]
[ -f "$snapshot/previous/linkspace/linkspace-install.sh.missing" ]
[ -f "$product/missing" ]
[ "$(checksum "$snapshot/previous/zsetup/config.json")" = a8f79ff43745f1449b17be1cc1c3f293ebd1af3865fdc3235e96f48a53b4596a ]
# Restore the complete reviewed baseline under the publication lock, then remove
# first-release pointers. Keep every versioned script/binary and both snapshots.
cp -p "$snapshot/previous/zsetup/config.json" "$root/zsetup/config.json.rollback-$$"
mv -f "$root/zsetup/config.json.rollback-$$" "$root/zsetup/config.json"
rm "$app/linkspace-install.sh"
printf 'rolled-back\n' > "$snapshot/phase"
rm "$app/version.txt"
printf 'rolled-back\n' > "$product/phase"
echo 'Linkspace v0.1.0 pointers and index rolled back; immutable history retained'
LINKSPACE_ROLLBACK
