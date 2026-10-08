#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
release_dir=${1:?usage: test_zsetup_integration.sh ZSETUP_RELEASE_DIR [TUNNEL_ROOT]}
tunnel_root=${2:-/projects/workspace-linkease-ubuntu/linkease-vpn/linkease-tunnel}
# Replaces stale hard-coded-launcher assertions with the unified production-path contract.
exec python3 -B "$root/ddnsto/tests/ddnsto_test.py" "$release_dir/zsetup-linux-x86_64" "$tunnel_root"
