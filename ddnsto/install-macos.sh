#!/bin/sh
set -eu

# DDNSTO macOS CLI installer. The archive and hashes are immutable release
# inputs; update them together when a new macOS CLI is published.
VERSION=${DDNSTO_VERSION:-4.2.1}
BASE_URL=${DDNSTO_RELEASE_BASE:-https://fw.koolcenter.com/binary/ddnsto/macOS}
INSTALL_DIR=${DDNSTO_INSTALL_DIR:-$HOME/.local/bin}
CONFIG_DIR=${DDNSTO_CONFIG_DIR:-$HOME/Library/Application Support/DDNSTO}
LABEL=${DDNSTO_LAUNCHD_LABEL:-com.ddnsto.client}
TOKEN=

usage() {
    printf '%s\n' "Usage: $0 --token TOKEN [--version VERSION]" \
        'Installs the DDNSTO CLI and registers a per-user launchd agent.'
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --token)
            [ "$#" -ge 2 ] || { echo 'DDNSTO: --token requires a value' >&2; exit 2; }
            TOKEN=$2; shift 2 ;;
        --token=*) TOKEN=${1#--token=}; shift ;;
        --version)
            [ "$#" -ge 2 ] || { echo 'DDNSTO: --version requires a value' >&2; exit 2; }
            VERSION=$2; shift 2 ;;
        --version=*) VERSION=${1#--version=}; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "DDNSTO: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[ -n "$TOKEN" ] || { echo 'DDNSTO: token is required' >&2; exit 2; }
case "$TOKEN" in *"$(printf '\n')"*|*"$(printf '\r')"*) echo 'DDNSTO: token must be one line' >&2; exit 2 ;; esac
case "$VERSION" in 4.2.1) archive_sha=46aad0f28da7ad67175cfed1bc973b1eea68bed4242c8779d8cbd1ba57ed31d7 ;; *) echo "DDNSTO: no pinned macOS artifact for version $VERSION" >&2; exit 2 ;; esac

command -v curl >/dev/null 2>&1 || { echo 'DDNSTO: curl is required' >&2; exit 2; }
command -v tar >/dev/null 2>&1 || { echo 'DDNSTO: tar is required' >&2; exit 2; }
command -v shasum >/dev/null 2>&1 || { echo 'DDNSTO: shasum is required' >&2; exit 2; }

case "$(uname -m)" in
    x86_64|amd64) binary_name=ddnsto_cli.amd64 ;;
    arm64|aarch64) binary_name=ddnsto_cli.arm64 ;;
    *) echo "DDNSTO: unsupported macOS architecture: $(uname -m)" >&2; exit 2 ;;
esac

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/ddnsto.XXXXXX")
cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT HUP INT TERM
archive="$work_dir/ddnsto_darwin_cli_${VERSION}.tar.gz"
curl -fsSL "$BASE_URL/ddnsto_darwin_cli_${VERSION}.tar.gz" -o "$archive"
actual_sha=$(shasum -a 256 "$archive" | awk '{print $1}')
[ "$actual_sha" = "$archive_sha" ] || { echo 'DDNSTO: macOS archive checksum mismatch' >&2; exit 11; }
tar -xzf "$archive" -C "$work_dir"
[ -f "$work_dir/$binary_name" ] || { echo "DDNSTO: missing $binary_name in archive" >&2; exit 11; }

mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$HOME/Library/LaunchAgents"
chmod 700 "$CONFIG_DIR"
candidate="$INSTALL_DIR/.ddnsto.$$"
cp "$work_dir/$binary_name" "$candidate"
chmod 755 "$candidate"
mv -f "$candidate" "$INSTALL_DIR/ddnsto"
config="$CONFIG_DIR/ddnsto.yaml"
printf 'userToken: %s\nlogPath: %s/ddnsto.log\n' "$TOKEN" "$CONFIG_DIR" > "$config"
chmod 600 "$config"
plist="$HOME/Library/LaunchAgents/$LABEL.plist"
cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>$INSTALL_DIR/ddnsto</string><string>--config</string><string>$config</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>StandardOutPath</key><string>$CONFIG_DIR/launchd.stdout.log</string>
<key>StandardErrorPath</key><string>$CONFIG_DIR/launchd.stderr.log</string>
</dict></plist>
EOF
uid=$(id -u)
launchctl bootout "gui/$uid/$LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$uid" "$plist"
launchctl kickstart -k "gui/$uid/$LABEL"
printf '%s\n' "DDNSTO $VERSION installed at $INSTALL_DIR/ddnsto" "launchd service: $LABEL"
