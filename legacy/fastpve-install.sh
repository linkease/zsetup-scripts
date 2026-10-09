#!/bin/bash

set -euo pipefail

BASE_URL="https://fw.kspeeder.com/binary/fastpve"
VERSION_URL="${BASE_URL}/version.txt"

if [ -d "/root" ]; then
  TEMP_DIR="/root"
else
  TEMP_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t 'fastpve')
fi

cleanup() {
    rm -f "/tmp/fastpve-install.sh"
}
trap cleanup EXIT

download_nocache() {
    local url=$1
    local dest=$2

    if command -v curl &>/dev/null; then
        curl -fsSL -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' -o "$dest" "$url"
    elif command -v wget &>/dev/null; then
        wget --no-cache --header='Cache-Control: no-cache' --header='Pragma: no-cache' -O "$dest" "$url"
    else
        echo "curl or wget is required." >&2
        exit 1
    fi
}

download_file() {
    local url=$1
    local dest=$2

    if command -v curl &>/dev/null; then
        curl -fL -o "$dest" "$url"
    elif command -v wget &>/dev/null; then
        wget -O "$dest" "$url"
    else
        echo "curl or wget is required." >&2
        exit 1
    fi
}

calc_sha256() {
    local file=$1
    if command -v sha256sum &>/dev/null; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum &>/dev/null; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        echo "sha256sum or shasum is required." >&2
        exit 1
    fi
}

VERSION_FILE="$TEMP_DIR/version.txt"
download_nocache "$VERSION_URL" "$VERSION_FILE"

VERSION=$(awk -F= '/^VERSION=/{print $2;exit}' "$VERSION_FILE")
EXPECTED_SHA=$(awk -F= '/^FASTPVE_SHA256=/{print $2;exit}' "$VERSION_FILE")

if [ -z "$VERSION" ] || [ -z "$EXPECTED_SHA" ]; then
    echo "version.txt is missing VERSION or FASTPVE_SHA256." >&2
    exit 1
fi

BINARY_URL="${BASE_URL}/FastPVE-${VERSION}"
CACHE_FILE="$TEMP_DIR/FastPVE-${VERSION}"

needs_download=1
if [ -f "$CACHE_FILE" ]; then
    LOCAL_SHA=$(calc_sha256 "$CACHE_FILE")
    if [ "$LOCAL_SHA" = "$EXPECTED_SHA" ]; then
        needs_download=0
    else
        rm -f "$CACHE_FILE"
    fi
fi

if [ "$needs_download" -eq 1 ]; then
    TMP_FILE="${CACHE_FILE}.tmp"
    download_file "$BINARY_URL" "$TMP_FILE"

    LOCAL_SHA=$(calc_sha256 "$TMP_FILE")
    if [ "$LOCAL_SHA" != "$EXPECTED_SHA" ]; then
        echo "Checksum mismatch for downloaded FastPVE." >&2
        rm -f "$TMP_FILE"
        exit 1
    fi

    mv "$TMP_FILE" "$CACHE_FILE"
    chmod +x "$CACHE_FILE"
fi

"$CACHE_FILE" version
"$CACHE_FILE"
