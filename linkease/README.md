# LinkEase

维护入口为 `linkease-install.sh`，由 `business.sh`、`main.sh` 与共享 `../lib/bootstrap.sh` 生成。直接执行与 zsetup install linkease 汇合到同一 linkease_install 函数；运行中的脚本不下载自身。依赖 zsetup >=0.2.4，发布脚本版本为 0.1.6。

设备已有 zsetup：

```sh
zsetup install linkease
zsetup install linkease -- --version 1.7.5
```

发布后的一条命令入口：

```sh
sh -c "$(curl -fsSL https://fw.koolcenter.com/binary/linkease/linkease-install.sh)"
```

curl 可换为 wget -qO-。后续下载由 zsetup 执行，使用既有 HTTPS primary 竞速、最终 fallback 和内置 SHA256；不增加 shell 下载器，不调用 awk/sed。命令目前仅在本地 HTTPS fixture 验证，未发布公网。

## 平台、参数及依赖

| 平台 | 架构 | 行为与依赖 |
|---|---|---|
| Ubuntu/Debian、CentOS/RHEL、通用 Linux | x86_64、aarch64、armv7 | 默认 1.7.5；安装 linkease、heif-converter、linkease-media、完整 linkmount/bin（含 lib）；需要 tar 和支持 -Z1/-p 的 unzip，以及 root 或已配置 sudo |
| OpenWrt opkg | x86_64、aarch64、armv7 | 默认从服务器 VERSION 取版本；安装主包及 LuCI/中文包，前两种架构还安装 linkmount/remux；需 opkg 及安装权限 |
| OpenWrt apk、MIPS、未知架构 | 未支持 | 参考脚本没有 APK 实现；不加入相应索引，不套用未经验证的包 |

参数仅 `--version VERSION`（也支持 --version=VERSION）和 --help。LINKEASE_VERSION 可设置默认版本；命令行优先。没有 token 或菜单交互。--version 在 Linux 选择产品快照，在 OpenWrt 覆盖 VERSION 指针。默认前台；后台可用 `zsetup install linkease --background`，必须等其 result 文件中的最终退出码，不能把启动成功当成安装成功。

退出码：0 完成；2 参数、平台、工具或权限要求不满足；11 业务元数据/ZIP 布局错误；zsetup 下载、tar/unzip、opkg 与服务失败保留其非零退出码；HUP/INT/TERM 为 129/130/143。zsetup 索引匹配/配置失败继续沿用既有命令协议（通常 17）。

LINKEASE_APP_DIR、LINKEASE_SERVICE_PATH 为受控测试/运维路径覆盖，默认 /usr/sbin 与 /etc/init.d/com.linkease.linkeasedaemon.service；普通用户无需设置。测试使用隔离目录、伪 opkg/systemctl/服务程序，避免触及宿主服务。

## 产品由服务器提前发布

源参考为 legacy/install_linkease_linux.sh、install_linkease_openwrt.sh。Linux tar 的已核实布局是 linkease-binary-1.7.5/{linkease,heif-converter,linkease-media}.{x86_64,aarch64,arm}；原 linkmount ZIP 布局为 <amd64|arm64|arm>/bin/linkmount_bin 和 bin/lib/。保留这些产品字节与解包布局，不把产品搬回本仓库。

新入口的服务器发布约定如下，位于网站 /binary/。Linux 发布目录是一组产品快照；其版本号同时标识所引用的 tar、三个 ZIP 和摘要，不声称 linkmount 自身的内部版本等于 LinkEase 版本。

```text
LinkEase/LinuxStorage/<VERSION>/
  linkease-binary-<VERSION>.tar.gz
  amd64.zip
  arm64.zip
  arm.zip
  SHA256SUMS
LinkEase/Openwrt/VERSION
LinkEase/Openwrt/<VERSION>/
  linkease_x86_64.ipk
  linkease_aarch64.ipk
  linkease_arm.ipk
  luci-app-linkease.ipk
  luci-i18n-linkease-zh-cn.ipk
  linkmount_x86_64.ipk
  ffmpeg-remux_x86_64.ipk
  linkmount_aarch64.ipk
  ffmpeg-remux_aarch64.ipk
  SHA256SUMS
```

SHA256SUMS 使用 `64位十六进制摘要  文件名`，由发布者从真实产品生成。服务器发布者可引用旧脚本已经在 LinuxStorage、AutoUpgrade/linkmount、Openwrt 和 iStore 发布的产品，准备上述版本快照；OpenWrt 依赖包快照采用稳定的架构文件名，不在设备中再次硬编码 iStore 的历史 URL。主包/UI/语言包/依赖应当一致，版本目录禁止改字节，全部部署后才激活入口及 VERSION。

安装端只读取版本/SHA256，所有新包经 zsetup 校验；缺少摘要安全失败，不能关闭 TLS 或退回无校验旧逻辑。本仓库不生成产品、复制产品、收集产品或替发布者构造摘要。正式服务器文件布局及元数据可用性仍需上线回读和设备 canary。

## 安装与恢复

Linux 先下载/校验 tar 和对应 ZIP，将指定 tar 成员与 ZIP 文件流式写入普通 staging 文件，不让归档定义安装路径或符号链接。检查程序 showVersion 后，在安装目录获取锁、准备同文件系统 candidate 和旧文件 backup，再通过 systemctl/service/init 停止旧服务，替换四项产品并沿用旧脚本的 --serviceControl uninstall/install/start 顺序；保留旧 init 脚本的启动 fallback。

安装/启动失败时恢复原有全部文件及旧服务；首次安装失败会卸载新服务并回收新文件。若恢复旧服务也失败，会报告并保留 `.linkease-backup.PID` 供人工恢复。成功及普通失败清理 transaction/candidate/锁；SIGKILL、断电不会执行 shell trap，遗留锁和 backup 需在确认无安装进程后处理。

OpenWrt 在调用 opkg 前取得并校验本次所需全部包。包管理器执行失败时传播错误并清理 transaction，保留已校验缓存；不承诺将 opkg 已产生的部分安装回滚为旧系统。此边界与业务包管理器自身语义一致。

测试：

```sh
python3 -B linkease/tests/linkease_test.py /path/to/zsetup/dist/release/zsetup-linux-x86_64
sh scripts/check.sh /path/to/linkease-tunnel/zsetup
```

安装入口/配置发布见 [release.md](../docs/release.md)；所有产品提前部署，legacy、business/main、测试不进入发布包。
