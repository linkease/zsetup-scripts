version="1.7.5"
APP_DIR='/usr/sbin'
APP_URL='http://fw0.koolcenter.com/binary/LinkEase/LinuxStorage'
MOUNT_URL='https://fw.koolcenter.com/binary/LinkEase/AutoUpgrade/linkmount'

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
    wget -c --no-check-certificate ${URL} -O ${FileName}
  fi
  if [ $? -eq 0 ]; then
    echo "Download OK"
  else
    echo "Download failed"
    exit 1
  fi
}

clean_app(){
    rm -rf /tmp/linkease-binary /tmp/linkease-binary.tar.gz /tmp/amd64.zip /tmp/arm.zip /tmp/arm64.zip /tmp/amd64 /tmp/arm64 /tmp/arm
}

( set -x; Download_Files ${APP_URL}/linkease-binary-${version}.tar.gz /tmp/linkease-binary.tar.gz;
mkdir -p /tmp/linkease-binary; 
tar --strip-components=1 -zxf /tmp/linkease-binary.tar.gz -C /tmp/linkease-binary; )
rm -f /tmp/linkease-binary.tar.gz

if command_exists systemctl; then
  systemctl stop com.linkease.linkeasedaemon.service || true
elif command_exists service; then
  service com.linkease.linkeasedaemon.service stop  || true
else
  /etc/init.d/com.linkease.linkeasedaemon.service stop || true
fi

if echo `uname -m` | grep -Eqi 'x86_64'; then
    arch='x86_64'
    mount='amd64'
elif  echo `uname -m` | grep -Eqi 'arm'; then
    arch='arm'
    mount='arm'
elif  echo `uname -m` | grep -Eqi 'aarch64'; then
    arch='aarch64'
    mount='arm64'
elif  echo `uname -m` | grep -Eqi 'mips|mipsel'; then
    error "The program not support mips."
    exit 1
else
    error "The program only supports x86_64 arm aarch64 platform."
    exit 1
fi
cp /tmp/linkease-binary/linkease.${arch} ${APP_DIR}/linkease
cp /tmp/linkease-binary/heif-converter.${arch} ${APP_DIR}/heif-converter
cp /tmp/linkease-binary/linkease-media.${arch} ${APP_DIR}/linkease-media
chmod 755 ${APP_DIR}/linkease
chmod 755 ${APP_DIR}/heif-converter
chmod 755 ${APP_DIR}/linkease-media
rm -rf /tmp/linkease-binary/

( set -x; Download_Files ${MOUNT_URL}/${mount}.zip /tmp/${mount}.zip;
rm -rf /tmp/${mount}
cd /tmp ;
unzip /tmp/${mount}.zip;
cd -;
rm -rf ${APP_DIR}/linkmount;
mv /tmp/${mount}/bin ${APP_DIR}/linkmount; )

echo "The linkease version is:"
${APP_DIR}/linkease showVersion

if [ $? -eq 0 ]; then
  echo "Install OK"
else
  clean_app
  echo "Install failed(安装失败)"
  exit 2
fi

echo "Install services"
${APP_DIR}/linkease --serviceControl uninstall || true
${APP_DIR}/linkease --serviceControl install
${APP_DIR}/linkease --serviceControl start
if [ $? -eq 0 ]; then
  echo "Start OK"
else
  echo "Start failed, try /etc/init.d/com.linkease.linkeasedaemon.service start"
  /etc/init.d/com.linkease.linkeasedaemon.service start
fi

clean_app

