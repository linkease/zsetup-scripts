#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
zroot=${1:?usage: check.sh --native-bin ZSETUP_BINARY | ZSETUP_RUST_ROOT [RUST_RELEASE_PACKAGE]}
native_only=0
compatible_native_version() (
    value=${1#zsetup }
    [ "$value" != "$1" ] || return 1
    old_ifs=$IFS; IFS=.; set -- $value; IFS=$old_ifs
    [ "$#" = 3 ] || return 1
    for part in "$@"; do
        [ -n "$part" ] || return 1
        case "$part" in *[!0-9]*) return 1 ;; esac
    done
    [ "$1" -gt 0 ] || { [ "$1" = 0 ] && [ "$2" -ge 5 ]; }
)
if [ "$zroot" = --native-bin ]; then
    native_only=1
    native_bin=${2:-}
    [ -f "$native_bin" ] && [ -x "$native_bin" ] || { printf '%s\n' 'executable native binary required' >&2; exit 2; }
    native_bin=$(CDPATH= cd -- "$(dirname -- "$native_bin")" && pwd)/$(basename -- "$native_bin")
    native_version=$("$native_bin" --version) || exit 2
    compatible_native_version "$native_version" || {
        printf '%s\n' 'zsetup >=0.5.0 with a stable semantic version is required' >&2
        exit 2
    }
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
python3 -B "$root/software/build-release-lock.py" --check
mkdir -p "$root/dist"
software_test_tmp=$(mktemp -d "$root/dist/software-tests.XXXXXX")
ZSETUP_TEST_NATIVE="$native_bin" TMPDIR="$software_test_tmp" python3 -B -m unittest discover -s "$root/software/tests"
rmdir "$software_test_tmp"
for software_script in "$root"/software/*.sh; do bash -n "$software_script"; done
python3 -B "$root/tests/module_layout_test.py"
python3 -B "$root/tests/apps/kai-skills/test_builder_bootstrap.py"
python3 -B "$root/scripts/build.py" --check
python3 -B "$root/scripts/check-public-tree.py" "$root/apps"
for contract_test in "$root"/tests/contracts/*_test.py; do
    python3 -B "$contract_test"
done
python3 -B "$root/tests/apps/fastnet/migration_test.py"
python3 -B "$root/tests/apps/ordinary_migrations_test.py"
python3 -B "$root/tests/apps/complex_migrations_test.py"
python3 -B "$root/scripts/build-ddnsto-products.py" --check
python3 -B "$root/tests/ddnsto_release_config_test.py"
python3 -B "$root/tests/ddnsto_apps_standard_test.py"
python3 -B "$root/tests/apps/ddnsto/internal/agent_guide_test.py"
python3 -B "$root/tests/ddnsto_shell_compat_test.py"
python3 -B "$root/tests/publication_test.py"
python3 -B "$root/tests/ddnsto_offline_native_test.py"
python3 -B "$root/tests/ddnsto_autoinstall_test.py"
python3 -B "$root/tests/ddnsto_auto_openwrt_test.py"
python3 -B "$root/tests/ddnsto_auto_synology_test.py"
python3 -B "$root/tests/apps/ddnsto/internal/bootstrap_policy_test.py"
python3 -B "$root/tests/apps/ddnsto/internal/wget_bootstrap_test.py"
python3 -B "$root/tests/apps/ddnsto/internal/macos_default_test.py"
python3 -B "$root/tests/apps/ddnsto/internal/macos_diagnostics_test.py"
ZSETUP_TEST_NATIVE="$native_bin" python3 -B "$root/tests/ddnsto_managed_cli_test.py"
python3 -B "$root/tests/apps/ddnsto/internal/operation_lock_test.py"
if [ "$native_only" = 0 ] && [ -f "$zroot/Cargo.toml" ]; then
    python3 -B "$root/tests/app_release_test.py" "$zroot" "$native_bin"
    python3 -B "$root/tests/windows_app_release_test.py" "$zroot" "$native_bin"
fi
python3 -B "$root/tests/bootstrap_platform_test.py"
python3 -B "$root/tests/minimum_native_test.py"
python3 -B "$root/tests/windows_scoop_contract_test.py"
python3 -B "$root/tests/install_storage_test.py"
python3 -B "$root/tests/managed_remove_test.py" "$native_bin"
python3 -B "$root/tests/apps/jq/jq_install_test.py" "$native_bin"
sh -n "$root/apps/jq/source/business.sh"
sh -n "$root/apps/jq/0.1.0/installer.sh"
for script in "$root"/lib/*.sh "$root"/scripts/*.sh "$root"/tests/*.sh \
    "$root"/apps/*/*.sh "$root"/apps/*/*/*.sh "$root"/apps/*/source/*.sh "$root"/sources/ddnsto/*.sh; do
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
python3 -B "$root/tests/apps/linkspace/linkspace_test.py" "$native_bin"
python3 -B "$root/tests/apps/kspeeder/binary_install_test.py" "$native_bin"
python3 -B "$root/tests/apps/fastpve/fastpve_test.py" "$native_bin"
python3 -B "$root/tests/apps/fastnet/fastnet_bootstrap_test.py" "$native_bin"
python3 -B "$root/tests/apps/fastnet/fastnet_zsetup_test.py" "$native_bin" "$tunnel_root"
python3 -B "$root/tests/apps/ddnsto/ddnsto_test.py" "$native_bin" "$tunnel_root"
python3 -B "$root/tests/apps/linkease/linkease_test.py" "$native_bin"
if [ "$native_only" = 0 ]; then
    python3 -B "$root/tests/package_test.py" "$zroot" "$release"
fi
