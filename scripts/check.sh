#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
zroot=${1:?usage: check.sh ZSETUP_RUST_ROOT [RUST_RELEASE_PACKAGE]}
release=${2:-$zroot/dist/release}
if [ -f "$zroot/Cargo.toml" ]; then
    version=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$release/release-manifest.json")
    native_dir="$release/immutable/zsetup/$version"
else
    # Historical release-fixture compatibility only; future release uses Rust.
    native_dir="$release"
fi
tunnel_root=$(CDPATH= cd -- "$zroot/.." && pwd)
python3 -B "$root/tests/module_layout_test.py"
python3 -B "$root/tests/bootstrap_platform_test.py"
for script in "$root"/fastnet/*.sh "$root"/ddnsto/*.sh "$root"/linkease/*.sh "$root"/fastpve/*.sh "$root"/lib/*.sh "$root"/scripts/*.sh "$root"/tests/*.sh; do
    sh -n "$script"
done
for script in "$root"/legacy/*.sh; do
    case "$(head -n 1 "$script")" in
        '#!/bin/bash'*) bash -n "$script" ;;
        *) sh -n "$script" ;;
    esac
done
python3 -B "$root/fastpve/tests/fastpve_test.py" "$native_dir/zsetup-linux-x86_64"
python3 -B "$root/fastnet/tests/fastnet_bootstrap_test.py" "$native_dir/zsetup-linux-x86_64"
python3 -B "$root/fastnet/tests/fastnet_zsetup_test.py" "$native_dir/zsetup-linux-x86_64" "$tunnel_root"
sh "$root/tests/test_zsetup_integration.sh" "$native_dir" "$tunnel_root"
python3 -B "$root/linkease/tests/linkease_test.py" "$native_dir/zsetup-linux-x86_64"
python3 -B "$root/tests/package_test.py" "$zroot" "$release"
