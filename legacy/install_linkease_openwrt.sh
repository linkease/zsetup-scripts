#!/bin/sh

PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

version="1.0"
APP_URL='http://fw.koolcenter.com/binary/LinkEase/Openwrt'
ISTORE_URL='https://istore.linkease.com/repo/x86_64/nas'
app_arm='linkease_arm.ipk'
app_aarch64='linkease_aarch64.ipk'
app_x86='linkease_x86_64.ipk'
app_ui='luci-app-linkease.ipk'
app_lng='luci-i18n-linkease-zh-cn.ipk'
app_linkmount='linkmount.ipk'
app_remux='ffmpeg-remux.ipk'

setup_color() {
    # Only use colors if connected to a terminal
    if [ -t 1 ]; then
        RED=$(printf '\033[31m')
        GREEN=$(printf '\033[32m')
        YELLOW=$(printf '\033[33m')
        BLUE=$(printf '\033[34m')
        BOLD=$(printf '\033[1m')
        RESET=$(printf '\033[m')
    else
        RED=""
        GREEN=""
        YELLOW=""
        BLUE=""
        BOLD=""
        RESET=""
    fi
}
setup_color
command_exists() {
    command -v "$@" >/dev/null 2>&1
}
error() {
    echo ${RED}"Error: $@"${RESET} >&2
}

Download_Files(){
  local URL=$1
  local FileName=$2
  if command_exists curl; then
    curl -sSLk ${URL} -o ${FileName}
  elif command_exists wget; then
    wget -c --progress=bar:force --prefer-family=IPv4 --no-check-certificate ${URL} -O ${FileName}
  fi
  if [ $? -eq 0 ]; then
    echo "Download OK"
  else
    echo "Download failed"
    exit 1
  fi
}

clean_app(){
    rm -f /tmp/${app_x86} /tmp/${app_arm} /tmp/${app_aarch64} /tmp/${app_ui} /tmp/${app_lng} /tmp/${app_remux} /tmp/${app_linkmount}
}

command_exists opkg || {
    error "The program only supports Openwrt."
    clean_app
    exit 1
}

if echo `uname -m` | grep -Eqi 'x86_64'; then
    arch='x86_64'
    ( set -x; Download_Files ${APP_URL}/${app_x86} /tmp/${app_x86};
      Download_Files ${APP_URL}/${app_ui} /tmp/${app_ui};
      Download_Files ${APP_URL}/${app_lng} /tmp/${app_lng};
      opkg remove app-meta-linkease luci-i18n-linkease-zh-cn luci-app-linkease linkease
      opkg install /tmp/${app_x86};
      opkg install /tmp/${app_ui};
      opkg install /tmp/${app_lng}; )

      Download_Files ${ISTORE_URL}/linkmount_1.0.3-x86_64-2_x86_64.ipk /tmp/${app_linkmount};
      Download_Files ${ISTORE_URL}/ffmpeg-remux_4.3.3-1_x86_64.ipk /tmp/${app_remux};
      opkg install /tmp/${app_linkmount};
      opkg install /tmp/${app_remux};
elif  echo `uname -m` | grep -Eqi 'arm'; then
    arch='arm'
    ( set -x; Download_Files ${APP_URL}/${app_arm} /tmp/${app_arm};
      Download_Files ${APP_URL}/${app_ui} /tmp/${app_ui};
      Download_Files ${APP_URL}/${app_lng} /tmp/${app_lng};
      opkg remove app-meta-linkease luci-i18n-linkease-zh-cn luci-app-linkease linkease
      opkg install /tmp/${app_arm};
      opkg install /tmp/${app_ui};
      opkg install /tmp/${app_lng}; )
elif  echo `uname -m` | grep -Eqi 'aarch64'; then
    arch='aarch64'
    ( set -x; Download_Files ${APP_URL}/${app_aarch64} /tmp/${app_aarch64};
      Download_Files ${APP_URL}/${app_ui} /tmp/${app_ui};
      Download_Files ${APP_URL}/${app_lng} /tmp/${app_lng};
      opkg remove app-meta-linkease luci-i18n-linkease-zh-cn luci-app-linkease linkease
      opkg install /tmp/${app_aarch64};
      opkg install /tmp/${app_ui};
      opkg install /tmp/${app_lng}; )

      Download_Files ${ISTORE_URL}/linkmount_1.0.3-aarch64-2_aarch64_cortex-a53.ipk /tmp/${app_linkmount};
      Download_Files ${ISTORE_URL}/ffmpeg-remux_4.3.3-2_aarch64_cortex-a53.ipk /tmp/${app_remux};
      opkg install /tmp/${app_linkmount};
      opkg install /tmp/${app_remux};
elif  echo `uname -m` | grep -Eqi 'mips|mipsel'; then
    error "The program not support mips."
    exit 1
else
    error "The program only supports Openwrt."
    exit 1
fi

echo "The linkease version is:"
linkease showVersion

if [ $? -eq 0 ]; then
  echo "Install OK"
else
  clean_app
  echo "Install failed(安装失败)"
  exit 2
fi

printf "$GREEN"
cat <<-'EOF'
  linkease is now installed!


  安装成功，请到 https://www.linkease.com/ 获取更多帮助

EOF
printf "$RESET"
clean_app
