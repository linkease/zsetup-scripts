#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
zroot=${1:?usage: check.sh ZSETUP_ROOT}
tunnel_root=$(CDPATH= cd -- "$zroot/.." && pwd)
python3 -B "$root/scripts/build-entrypoints.py" --check
for script in "$root"/*.sh "$root"/apps/*/*.sh "$root"/lib/*.sh "$root"/scripts/*.sh "$root"/tests/*.sh; do
    sh -n "$script"
done
python3 -B "$root/tests/fastnet_bootstrap_test.py"
python3 -B "$root/tests/fastnet_zsetup_test.py" "$zroot/dist/release/zsetup-linux-x86_64" "$tunnel_root"
sh "$root/tests/test_zsetup_integration.sh" "$zroot/dist/release" "$tunnel_root"
python3 -B "$root/tests/package_test.py" "$zroot"
python3 -B "$root/tests/artifact_package_test.py" "$zroot"
