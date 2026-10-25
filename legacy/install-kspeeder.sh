#!/bin/sh

set -e

BASE_URL="https://kspeeder.com/bin"
LOCAL_DIR="${1:-}"
TARGET_DIR="/usr/local/bin"
TARGET="${TARGET_DIR}/ks-cli"

force_docker_install() {
  case "${KSPEEDER_INSTALL_FORCE_DOCKER:-}" in
    1|true|TRUE|yes|YES|y|Y|on|ON)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

yes_install() {
  case "${KSPEEDER_INSTALL_YES:-}" in
    1|true|TRUE|yes|YES|y|Y|on|ON)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

append_optional_installer_label_args() {
  if yes_install; then
    printf ' --yes'
  fi
  if [ -n "${KSPEEDER_INSTALL_VERSION_URL:-}" ]; then
    printf ' --version-url '
    shell_quote "$KSPEEDER_INSTALL_VERSION_URL"
  fi
  if [ -n "${KSPEEDER_INSTALL_LISTEN:-}" ]; then
    printf ' --listen '
    shell_quote "$KSPEEDER_INSTALL_LISTEN"
  fi
  if [ -n "${KSPEEDER_INSTALL_ADMIN:-}" ]; then
    printf ' --admin '
    shell_quote "$KSPEEDER_INSTALL_ADMIN"
  fi
  if [ -n "${KSPEEDER_INSTALL_CACHE_PATH:-}" ]; then
    printf ' --cache-path '
    shell_quote "$KSPEEDER_INSTALL_CACHE_PATH"
  fi
}

shell_quote() {
  case "$1" in
    *[!A-Za-z0-9_./:=+-]*|'')
      quoted=$(printf "%s" "$1" | sed "s/'/'\\\\''/g")
      printf "'%s'" "$quoted"
      ;;
    *)
      printf '%s' "$1"
      ;;
  esac
}

installer_command_label() {
  target_path="${1:-$TARGET}"
  shell_quote "$target_path"
  printf ' service install --mode '
  if force_docker_install; then
    printf 'docker'
  else
    printf 'auto'
  fi
  append_optional_installer_label_args
}

run_installer_install_command() {
  set -- "$@"
  if yes_install; then
    set -- "$@" --yes
  fi
  if [ -n "${KSPEEDER_INSTALL_VERSION_URL:-}" ]; then
    set -- "$@" --version-url "$KSPEEDER_INSTALL_VERSION_URL"
  fi
  if [ -n "${KSPEEDER_INSTALL_LISTEN:-}" ]; then
    set -- "$@" --listen "$KSPEEDER_INSTALL_LISTEN"
  fi
  if [ -n "${KSPEEDER_INSTALL_ADMIN:-}" ]; then
    set -- "$@" --admin "$KSPEEDER_INSTALL_ADMIN"
  fi
  if [ -n "${KSPEEDER_INSTALL_CACHE_PATH:-}" ]; then
    set -- "$@" --cache-path "$KSPEEDER_INSTALL_CACHE_PATH"
  fi
  "$@"
}

run_installer_install() {
  if force_docker_install; then
    run_installer_install_command "$TARGET" service install --mode docker
  else
    run_installer_install_command "$TARGET" service install --mode auto
  fi
}

run_sudo_installer_install() {
  if force_docker_install; then
    run_installer_install_command sudo "$TARGET" service install --mode docker
  else
    run_installer_install_command sudo "$TARGET" service install --mode auto
  fi
}

should_run_install_subcommand() {
  if force_docker_install || yes_install || [ -n "${KSPEEDER_INSTALL_VERSION_URL:-}" ] || [ -n "${KSPEEDER_INSTALL_LISTEN:-}" ] || [ -n "${KSPEEDER_INSTALL_ADMIN:-}" ] || [ -n "${KSPEEDER_INSTALL_CACHE_PATH:-}" ]; then
    return 0
  else
    return 1
  fi
}

run_installer() {
  if force_docker_install; then
    echo "已启用 KSPEEDER_INSTALL_FORCE_DOCKER，将使用 Docker Compose 安装 KSpeeder。"
  fi
  run_installer_install
}

run_installer_with_sudo() {
  run_sudo_installer_install
}

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
    size=$(wc -c < "$bin_path" | awk '{print $1}')
    if [ -n "$size" ]; then
      mb=$(awk "BEGIN {printf \"%.2f\", $size/1024/1024}")
      echo "已下载: ${mb} MB"
    fi
  elif command -v wget >/dev/null 2>&1; then
    echo "正在下载 ks-cli: $url"
    wget --show-progress -O "$bin_path" "$url"
    size=$(wc -c < "$bin_path" | awk '{print $1}')
    if [ -n "$size" ]; then
      mb=$(awk "BEGIN {printf \"%.2f\", $size/1024/1024}")
      echo "已下载: ${mb} MB"
    fi
  else
    echo "curl or wget is required" >&2
    exit 1
  fi
fi

chmod +x "$bin_path"

if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    echo "需要管理员权限，正在安装 ks-cli 到: $TARGET"
    sudo mkdir -p "$TARGET_DIR"
    sudo cp "$bin_path" "$TARGET"
    sudo chmod +x "$TARGET"
    echo "ks-cli 已安装到: $TARGET"
    if force_docker_install; then
      echo "正在执行 ks-cli Docker Compose installer..."
      if run_installer; then
        exit 0
      fi
      echo "执行失败，请手动运行: $(installer_command_label "$TARGET")" >&2
      exit 1
    fi
    echo "正在使用 sudo 执行 ks-cli installer..."
    if run_installer_with_sudo; then
      exit 0
    fi
    echo "sudo 执行失败，请手动使用 sudo 运行: $(installer_command_label "$TARGET")" >&2
    exit 1
  fi
  echo "未检测到 sudo，请手动使用管理员/超级用户权限安装 ks-cli 到 PATH 后执行: $(installer_command_label "$bin_path")" >&2
  exit 1
fi

mkdir -p "$TARGET_DIR"
cp "$bin_path" "$TARGET"
chmod +x "$TARGET"
echo "ks-cli 已安装到: $TARGET"
run_installer
