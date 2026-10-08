#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
zroot=${1:?usage: check.sh ZSETUP_ROOT}
tunnel_root=$(CDPATH= cd -- "$zroot/.." && pwd)
python3 -B "$root/tests/module_layout_test.py"
for script in "$root"/*.sh "$root"/fastnet/*.sh "$root"/ddnsto/*.sh "$root"/lib/*.sh "$root"/scripts/*.sh "$root"/tests/*.sh; do
    sh -n "$script"
done
python3 -B "$root/fastnet/tests/fastnet_bootstrap_test.py" "$zroot/dist/release/zsetup-linux-x86_64"
python3 -B "$root/fastnet/tests/fastnet_zsetup_test.py" "$zroot/dist/release/zsetup-linux-x86_64" "$tunnel_root"
sh "$root/tests/test_zsetup_integration.sh" "$zroot/dist/release" "$tunnel_root"
python3 -B "$root/tests/package_test.py" "$zroot"
