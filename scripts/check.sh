#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
zroot=${1:?usage: check.sh --native-bin ZSETUP_BINARY | ZSETUP_RUST_ROOT [RUST_RELEASE_PACKAGE]}
native_only=0
if [ "$zroot" = --native-bin ]; then
    native_only=1
    native_bin=${2:-}
    [ -f "$native_bin" ] && [ -x "$native_bin" ] || { printf '%s\n' 'executable native binary required' >&2; exit 2; }
    native_bin=$(CDPATH= cd -- "$(dirname -- "$native_bin")" && pwd)/$(basename -- "$native_bin")
    native_version=$("$native_bin" --version) || exit 2
    case "$native_version" in
        'zsetup 0.'*)
            minor=${native_version#zsetup 0.}; minor=${minor%%.*}
            case "$minor" in ''|*[!0-9]*) exit 2 ;; esac
            [ "$minor" -ge 5 ] || { printf '%s\n' 'zsetup >=0.5.0 required' >&2; exit 2; } ;;
        'zsetup '[1-9].*) ;;
        *) printf '%s\n' 'zsetup >=0.5.0 required' >&2; exit 2 ;;
    esac
    zroot=; release=; tunnel_root=$root
    printf '%s\n' 'Using published native binary; native source and aggregate packaging not checked.'
else
    release=${2:-$zroot/dist/release}
if [ -f "$zroot/Cargo.toml" ]; then
    version=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$release/release-manifest.json")
    native_dir="$release/immutable/zsetup/$version"
else
    # Historical release-fixture compatibility only; future release uses Rust.
    native_dir="$release"
fi
tunnel_root=$(CDPATH= cd -- "$zroot/.." && pwd)
native_bin="$native_dir/zsetup-linux-x86_64"
fi
python3 -B "$root/tests/module_layout_test.py"
if [ "$native_only" = 0 ] && [ -f "$zroot/Cargo.toml" ]; then
    python3 -B "$root/tests/app_release_test.py" "$zroot" "$native_bin"
    python3 -B "$root/tests/windows_app_release_test.py" "$zroot" "$native_bin"
fi
python3 -B "$root/tests/bootstrap_platform_test.py"
python3 -B "$root/tests/minimum_native_test.py"
python3 -B "$root/tests/install_storage_test.py"
python3 -B "$root/tests/managed_remove_test.py" "$native_bin"
python3 -B "$root/jq/tests/jq_install_test.py" "$native_bin"
sh -n "$root/jq/business.sh"
sh -n "$root/jq/jq-install.sh"
for script in "$root"/kspeeder/ks-cli/*.sh "$root"/kspeeder/kspeeder/*.sh "$root"/kspeeder/lib/*.sh "$root"/linkspace/*.sh "$root"/fastnet/*.sh "$root"/ddnsto/*.sh "$root"/linkease/*.sh "$root"/fastpve/*.sh "$root"/lib/*.sh "$root"/scripts/*.sh "$root"/tests/*.sh; do
    sh -n "$script"
done
for script in "$root"/legacy/*.sh; do
    case "$(head -n 1 "$script")" in
        '#!/bin/bash'*) bash -n "$script" ;;
        *) sh -n "$script" ;;
    esac
done
for suite in install_bounds_test install_transaction_test launcher_storage_test privilege_bridge_test; do
    python3 -B "$root/tests/$suite.py" "$native_bin"
done
python3 -B "$root/linkspace/tests/linkspace_test.py" "$native_bin"
python3 -B "$root/kspeeder/tests/binary_install_test.py" "$native_bin"
python3 -B "$root/fastpve/tests/fastpve_test.py" "$native_bin"
python3 -B "$root/fastnet/tests/fastnet_bootstrap_test.py" "$native_bin"
python3 -B "$root/fastnet/tests/fastnet_zsetup_test.py" "$native_bin" "$tunnel_root"
python3 -B "$root/ddnsto/tests/ddnsto_test.py" "$native_bin" "$tunnel_root"
python3 -B "$root/linkease/tests/linkease_test.py" "$native_bin"
if [ "$native_only" = 0 ]; then
    python3 -B "$root/tests/package_test.py" "$zroot" "$release"
fi
