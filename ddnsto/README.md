# DDNSTO

2026-11-16：[zsetup 能力复用审查与候选开发任务](../docs/ddnsto-zsetup-reuse-audit-2026-11-16.md)。第一批已收敛现代华硕下载后的重复校验，并增加真实核心契约测试；[验证记录](../docs/verification/2026-11-16-ddnsto-native-reuse-batch1.md)。华硕 SSH 已恢复且身份校验通过，RT-AX86U 上两版核心的候选下载函数验证通过；未部署、未升级核心，完整安装/恢复真机验收仍待完成。

第二批将现代华硕的解包输出捕获交给现用 zsetup 0.5.0（大小、空间与超时限制），保留 tar、包白名单及 armsoft 兼容路径。RT-AX86U 的真实包暂存解包通过；未执行安装或重启。详见上述验证记录。

后续已实现[核心先行入口](../docs/ddnsto-native-first-candidate.md)：打包器显式 `--native-first` 才启用，普通 Linux x86_64/aarch64 先校验固定核心再由核心下载业务脚本，其余平台保持原路径。2026-11-16 经用户授权，完成 OpenWrt/DSM 同版本公网验收、测试站 `/i` 激活及回滚演练；[发布与限制记录](../docs/verification/2026-11-16-native-first-test-release.md)。正式环境未更新，完整真机矩阵仍未齐全；华硕按用户要求跳过。

旧版本正在运行时的更新结果，见 [跨平台升级专项测试](../docs/verification/2026-11-16-running-old-version-upgrade.md)：19 个新增用例通过，明确区分真实文件事务、模拟服务状态和真机证据；不将包部分失败后的配置恢复当作完整客户端回滚。

群晖自动安装、升级和启动已发布至测试站 `/i`：DSM 7 原生 SPK，管理员 sudo 授权，保留配置且不降级。DS220j / DSM 7.1 已验证空白新装、4.2.7-7 升级到 4.2.8-7、停止后启动及重复执行。新装通过 DSM 本机套件中心 API 传递 Token，安装至默认卷；接受已校验摘要的 DDNSTO 第三方包，不改全局信任策略。发现卸载残留或账号不同会拒绝覆盖。其他机型及 DSM 6 尚未完成真机验收。ARM64 仅开放已验证的 DS220j ARM32 兼容路径，不代表全部 ARM64 群晖。正式环境未更新，详见 [群晖验证记录](../docs/verification/2026-11-09-synology-auto.md)。

> 当前测试候选为 0.2.4，默认动作已改为无菜单的 `ensure`，客户端固定 4.2.8。请以 [默认流程说明与验收记录](../docs/verification/2026-11-09-ddnsto-autoinstall.md) 和 `install-rules.json` 为准。下面保留的是历史入口说明，其中版本、可选 Token、在线检查和动态 VERSION 描述不适用于新的默认流程。测试站部署不代表正式入口已更新。

Linux/OpenWrt 的统一入口为 `ddnsto-install.sh`，由本目录 `business.sh`、`main.sh` 和共享 `../lib/bootstrap.sh` 生成；普通执行和 `zsetup install ddnsto` 使用同一业务实现。Windows 和 macOS 使用同目录的原生入口 `install.ps1` 与 `install-macos.sh`，安装已发布的 DDNSTO CLI 归档并注册平台服务。Linux/OpenWrt 入口依赖 zsetup >=0.2.4，不调用 awk/sed。

发布后用户入口：

```sh
zsetup install ddnsto -- --token 'YOUR_TOKEN'
sh -c "$(curl -fsSL https://fw.koolcenter.com/binary/ddnsto/ddnsto-install.sh)" -- --token 'YOUR_TOKEN'
```

OpenWrt 支持 opkg/apk × x86_64/aarch64/armv7/mipsel；总内存低于 900 MiB 自动选 Lite，可传 `--force-version lite|standard`。token 可选；`--verify-status` 请求服务检查。Linux 支持 x86_64/aarch64，默认 Standard 4.2.3，无终端时必须提供 token。Windows 入口支持 x86_64 CLI 4.2.1，在 Windows 10 x64 WOW64 / PowerShell 5.1 验证范围内使用计划任务启动；macOS 入口支持 Intel/Apple Silicon CLI 4.2.1，使用用户级 launchd。Windows/macOS 的 4.2.1 归档 SHA256 固定在入口脚本中，升级新版本前必须更新脚本、测试和发布配置。参数、退出码及交互详情见 [统一协议](../docs/ai-contract.md)。

本模块包含：

- business.sh/main.sh/ddnsto-install.sh：维护源码与唯一生成入口。
- release.py：将同一 ddnsto-install.sh 发布到旧兼容 URL；产品包不在本仓库构建或打包。
- tests/：通过隔离 HTTPS 产品服务器验证双入口、平台、参数、缓存、进度和失败回收。

服务器完整模块目录（产品文件由业务发布流程提前部署，本仓库仅发布 ddnsto-install.sh 及兼容入口）：

```text
binary/ddnsto/
  0.1.4/ddnsto-install.sh
  ddnsto-install.sh
  install.sh          # 原 URL 的同字节兼容副本
  openwrt/VERSION
  openwrt/VERSION_LITE
  openwrt/<standard|lite|standard-apk|lite-apk>/<VERSION>/包与 SHA256SUMS
  linux-binary/ddnsto-standard-4.2.3.tar.gz
  linux-binary/SHA256SUMS
  openwrt/<install_ddnsto.sh|install_ddnsto_business.sh|setup_ddnsto.sh>
  linux-binary/install_ddnsto_linux.sh
```

兼容 URL 发布为与 ddnsto-install.sh 相同的实际文件，无须服务器支持符号链接。旧源仓库与已上线旧文件不得在迁移验证前删除。仓库中的历史源码位于 [legacy/](../legacy/README.md)，不进入发布包；当前入口为 ddnsto/ddnsto-install.sh。business/main、Python 工具、测试和 README 不发布。

模块命令（从仓库根目录执行）：

```sh
python3 -B ddnsto/tests/ddnsto_test.py /path/to/zsetup/dist/release/zsetup-linux-x86_64 /path/to/linkease-tunnel
python3 -B ddnsto/tests/cross_platform_installer_test.py
```

业务发布者从其实际发布字节生成 SHA256SUMS，并先部署 OpenWrt 每个版本目录中的主包、LuCI/语言包和摘要，以及 Linux tar 和摘要，最后更新 VERSION/VERSION_LITE。安装脚本只从服务器读取版本和摘要，再调用 zsetup download 校验产品。完整安装配置仍与 FastNet、native zsetup 一起生成；发布顺序见 [发布文档](../docs/release.md)。


Linux storage candidate scripts0.1.8 requires Rust zsetup0.5.0. Default command
is ~/.local/bin/ddnsto; the system-service payload is root-protected under
/opt/linkease/ddnsto. Systemd is the new raw service adapter; SysV legacy remains
unported. Ordinary users prepare on persistent storage then use sudo -n for
verified root commit (sudo -v beforehand when credentials are missing).
Explicit root invocation also works. Common --installer-prefix/work-dir/scope
options precede business arguments; -- ends common parsing. Unknown existing
installations are migration conflicts. OpenWrt keeps only its proven native
package mappings and explicit root invocation. See ../docs/linux-install-storage.md
for disk bounds, two-version cache, metadata/network behavior and recovery.
This is an unpublished candidate, not a new production pointer.
# 推荐入口依赖优化（2026-11-16，测试站）

Shell 推荐入口默认联网获取推荐清单和不可变安装器，只使用本次运行的私有临时目录；不再读取或写入长期推荐缓存，旧 `DDNSTO_RECOMMEND_CACHE` 参数不再生效，旧缓存不会自动删除。zsetup 自身的受保护二进制缓存、客户端配置与诊断日志不受此项调整影响。

入口不再要求独立 `stat` 或 `cmp`。Linux/OpenWrt 后续引导和配置保护使用同一元数据辅助函数：优先 stat，缺失时严格解析 `LC_ALL=C ls -dn` 的数字所有者、权限与链接数，仅接受无歧义路径和格式；符号链接、ACL 标记或无法确认的权限仍会拒绝。macOS、DSM 原有业务依赖不因此被取消。

保留 SHA-256、字节数、清单严格解析、TLS 证书和下载边界检查；支持 BusyBox 的 wc、mktemp、sha256sum 功能，不创建系统命令链接、不自动安装依赖。缺少 mktemp 且 BusyBox 不提供时仍明确拒绝；未经验证的 BusyBox/uclient wget 仍不开放，使用 curl 或符合要求的 GNU Wget。不修改 zsetup 核心。

本轮只发布测试站；本地隔离测试不代表真机安装验收，设备测试由用户完成。发布记录见 [无 stat 入口验证](../docs/verification/2026-11-16-ddnsto-statless-entry.md)。
