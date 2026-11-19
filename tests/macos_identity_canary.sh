#!/bin/sh
# Explicitly authorized device test; changes only owned identity permissions
# and restarts the existing managed DDNSTO once. Never print account data.
set -eu
set +x
umask 077
export LC_ALL=C LANG=C
entry=${1:?usage: macos_identity_canary.sh ABSOLUTE_CANDIDATE_ENTRY}
[ "$(uname -s)" = Darwin ] && [ "$(id -u)" != 0 ]
config_dir="$HOME/Library/Application Support/DDNSTO"
identity="$config_dir/.ddnsto_boot.cfg"
config="$config_dir/ddnsto.yaml"
[ ! -L "$config_dir" ] && [ ! -L "$identity" ] && [ -f "$identity" ]
[ "$(stat -f '%u %Lp' "$config_dir")" = "$(id -u) 700" ]
[ "$(stat -f '%u %l' "$identity")" = "$(id -u) 1" ]
trap 'chmod 600 "$identity"' EXIT
fingerprint() { shasum -a 256 "$identity" "$config" "$HOME/.local/bin/ddnsto"; }
pid() { launchctl print "gui/$(id -u)/com.ddnsto.client" | sed -n 's/^[[:space:]]*pid = //p'; }
before=$(fingerprint)
before_pid=$(pid)
[ -n "$before_pid" ]
token=$(sed -n "s/^userToken: '\([^']*\)'$/\1/p" "$config")
[ -n "$token" ]
chmod 777 "$identity"
sh "$entry" --action status
[ "$(stat -f '%Lp' "$identity")" = 600 ]
[ "$(fingerprint)" = "$before" ] && [ "$(pid)" = "$before_pid" ]
printf '%s\n' 'PASS: historical 777 status; identity/config/binary and PID unchanged'
chmod 777 "$identity"
sh "$entry" --token "$token"
unset token
[ "$(stat -f '%Lp' "$identity")" = 600 ]
[ "$(fingerprint)" = "$before" ] && [ "$(pid)" = "$before_pid" ]
printf '%s\n' 'PASS: historical 777 default ensure; identity/config/binary and PID unchanged'
sh "$entry" --action restart
sh "$entry" --action status
[ "$(stat -f '%Lp' "$identity")" = 600 ]
[ "$(fingerprint)" = "$before" ] && [ -n "$(pid)" ]
printf '%s\n' 'PASS: restart then status; identity/config/binary unchanged, service running'
