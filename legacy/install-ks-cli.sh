#!/bin/sh

set -e

BASE_URL="https://kspeeder.com/bin"
LOCAL_DIR="${1:-}"

os=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m | tr '[:upper:]' '[:lower:]')

case "$os" in
  linux)
    os="linux"
    ;;
  darwin)
    os="mac"
    ;;
  *)
    echo "Unsupported OS: $os" >&2
    exit 1
    ;;
esac

case "$arch" in
  x86_64|amd64)
    arch="amd64"
    ;;
  aarch64|arm64)
    arch="arm64"
    ;;
  armv7l|armv7|armhf)
    arch="arm"
    ;;
  *)
    echo "Unsupported arch: $arch" >&2
    exit 1
    ;;
esac

filename="ks-cli-${os}-${arch}"
url="${BASE_URL}/${filename}"

if [ -n "$LOCAL_DIR" ]; then
  bin_path="${LOCAL_DIR%/}/${filename}"
  if [ ! -f "$bin_path" ]; then
    echo "Local ks-cli not found: $bin_path" >&2
    exit 1
  fi
else
  tmp_dir=$(mktemp -d)
  trap 'rm -rf "$tmp_dir"' EXIT
  bin_path="${tmp_dir}/${filename}"

  if command -v curl >/dev/null 2>&1; then
    echo "正在下载 ks-cli: $url"
    curl -fL --progress-bar -o "$bin_path" "$url"
  elif command -v wget >/dev/null 2>&1; then
    echo "正在下载 ks-cli: $url"
    wget --show-progress -O "$bin_path" "$url"
  else
    echo "curl or wget is required" >&2
    exit 1
  fi
fi

chmod +x "$bin_path"
target_dir="${HOME}/.local/bin"
mkdir -p "$target_dir"
target="${target_dir}/ks-cli"
cp "$bin_path" "$target"
chmod +x "$target"
echo "ks-cli 已安装到: $target"
echo "如果无法直接运行，请将 ${target_dir} 加入 PATH"
