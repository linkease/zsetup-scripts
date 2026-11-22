#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
[ "$#" = 1 ] || {
    printf '%s\n' 'usage: check-zsetup-candidate.sh /absolute/path/to/zsetup' >&2
    exit 2
}
case "$1" in /*) ;; *) printf '%s\n' 'candidate path must be absolute' >&2; exit 2 ;; esac

# This is the stable-promotion gate: run the candidate against every app and
# contract in this repository before changing any platform stable pointer.
exec "$root/scripts/check.sh" --native-bin "$1"
