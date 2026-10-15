# DDNSTO

0.1.10 测试修复版：macOS 安装前读取 launchd 禁用状态，兼容 `disabled` / `true`；安装会重新启用被禁用的 DDNSTO 用户服务，失败时恢复原有禁用状态及旧安装。保留 Token 和设备身份。测试站地址与验收边界见 [0.1.10 修复记录](../docs/macos-disabled-fix-2026-10-15.md)。旧固定 GitHub / 0.1.9 链接不会自动更新。

0.1.9历史变更：按macOS实际使用反馈将Token终端输入改为可见（不额外打印或写入日志），并明确提示客户端为固定4.2.1、未查询最新版。Linux/OpenWrt/Windows交互不变。

## 当前测试：0.1.8 GitHub固定入口

下载站保持只读。GitHub分发独立入口，zsetup和客户端包仍从既有站点取得。Linux固定4.2.3，OpenWrt Standard固定4.2.6/Lite固定4.2.2；21个产品路径和实际SHA256由 `product-pins.sh` 嵌入入口，不读取业务VERSION/SHA256SUMS。OpenWrt主包仍在版本目录，LuCI/语言包使用根目录并固定摘要。文件变化会拒绝安装，不跳过校验。

用户命令、版本更新规则与验证边界以[GitHub测试指南](../docs/github-testing.md)为准。下面正式CDN入口及同版本目录元数据布局是历史/未来可选发布方案，**不是本次测试前置条件**。不需要下载站发布权限，不改全局zsetup配置或FastNet；重新运行仅安装已核验版本，不等于自动升级最新版。

用户只需在目标设备执行一条官方命令，无需预装 zsetup、下载脚本仓库或选择二进制。Shell 入口 `install.sh` 自动识别 Linux/OpenWrt/macOS；Windows 使用 `install.ps1`。入口自动取得并校验 zsetup，再执行业务安装。macOS 维护源码 `install-macos.sh` 已嵌入生成入口，不依赖设备上的相邻文件。

[整体架构流程图](../docs/one-command-architecture.md)解释入口、zsetup、平台安装器和云端绑定之间的关系。0.1.6 起 Linux 修复服务启动失败误报：必须有 root/sudo 和可用 systemd/OpenRC，启动后验证服务、进程归属及本地健康接口；失败尝试恢复旧程序与服务 Token 配置，恢复失败保留备份。不以“已安装”代替“云端已绑定”。

0.1.8 直接复用现有 `https://fw.koolcenter.com/binary/zsetup/` 及既有镜像：Linux/OpenWrt 跟随官方 stable（本轮验证0.4.0），Windows 固定0.4.0及其真实摘要，macOS 暂保留0.3.0。无需新建下载服务器或复制一份 native。

发布后用户入口（正式 CDN 当前未部署，以下不能视为可用链接；测试站独立候选已部署，范围及真实验证结果见[测试记录](../docs/verification-2026-10-14.md#测试服务器部署与真实-linux-验证2026-10-14-utc)）：

```sh
sh -c 'entry=$(curl -fsSL --proto "=https" --proto-redir "=https" https://fw.koolcenter.com/binary/ddnsto/install.sh) && test -n "$entry" && sh -c "$entry"'
```

Windows 管理员 PowerShell 的候选命令：

```powershell
$ErrorActionPreference='Stop'; [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; & ([ScriptBlock]::Create((Invoke-WebRequest -UseBasicParsing -MaximumRedirection 0 https://fw.koolcenter.com/binary/ddnsto/install.ps1).Content))
```

首次在终端按提示粘贴控制台 Token（不回显）；桌面重装沿用已有配置，OpenWrt 优先复用 UCI Token，Linux 当前仍需提供 Token。自动化可用 Token 文件。Shell 命令下载失败时停止，不执行空内容；不要使用占用交互输入的 `curl | sh`。macOS 登录后运行，Windows 需管理员终端。最后在控制台确认设备在线。

直接入口不依赖 `zsetup install ddnsto` 索引。索引兼容性与远端业务摘要文件缺失不阻断0.1.8；原生设备验收仍是正式推广条件。

OpenWrt 支持 opkg/apk × x86_64/aarch64/armv7/mipsel；总内存低于 900 MiB 自动选 Lite，可传 `--force-version lite|standard`。token 可选；`--verify-status` 请求服务检查。Linux 支持 x86_64/aarch64，默认 Standard 4.2.3，无终端时必须提供 token。POSIX 支持 `--token-file FILE`，Windows 对应 `-TokenFile FILE`，与直接 Token 参数互斥；文件应限制为当前安装用户可读，允许一个末尾换行，不允许多行 Token。

桌面候选固定 CLI 4.2.1 归档 SHA256，Windows 额外核验 EXE SHA256；更新客户端版本必须同步脚本、测试和发布配置。Windows 使用 SYSTEM 计划任务，macOS 使用用户级 LaunchAgent（登录后运行）。两者首次安装需要 Token，重复安装可省略并保留既有 YAML 和身份文件；传入不同 Token 会拒绝，需显式修改配置。同名非托管安装拒绝自动接管。更新前停旧服务，失败尝试恢复程序、配置及服务；恢复失败保留备份位置。服务运行不等于云端已绑定，输出明确标注 `cloud_status=unverified`。原生行为仍需验收，详见 [验证记录](../docs/verification-2026-10-13.md)。参数、退出码及交互详情见 [统一协议](../docs/ai-contract.md)。

本模块包含：

- business.sh/linux-service.sh/main.sh/install.sh：业务、Linux 服务验证/恢复维护源码与唯一生成入口。
- release.py：将同一 install.sh 发布到旧兼容 URL；产品包不在本仓库构建或打包。
- tests/：通过隔离 HTTPS 产品服务器验证双入口、平台、参数、缓存、进度和失败回收。

服务器完整模块目录（产品文件由业务发布流程提前部署，本仓库仅发布 install.sh 及兼容入口）：

```text
binary/ddnsto/
  0.1.8/install.sh
  0.1.8/install.ps1
  install.sh
  install.ps1
  openwrt/VERSION
  openwrt/VERSION_LITE
  openwrt/<standard|lite|standard-apk|lite-apk>/<VERSION>/包与 SHA256SUMS
  linux-binary/ddnsto-standard-4.2.3.tar.gz
  linux-binary/SHA256SUMS
  openwrt/<install_ddnsto.sh|install_ddnsto_business.sh|setup_ddnsto.sh>
  linux-binary/install_ddnsto_linux.sh
```

兼容 URL 发布为与 install.sh 相同的实际文件，无须服务器支持符号链接。旧源仓库与已上线旧文件不得在迁移验证前删除。仓库中的历史源码位于 [legacy/](../legacy/README.md)，不进入发布包；当前入口为 ddnsto/install.sh。business/main、Python 工具、测试和 README 不发布。

模块命令（从仓库根目录执行）：

```sh
python3 -B ddnsto/tests/ddnsto_test.py /path/to/zsetup/dist/release/zsetup-linux-x86_64 /path/to/linkease-tunnel
python3 -B ddnsto/tests/cross_platform_installer_test.py
python3 -B scripts/package-entrypoints.py --output dist/ddnsto-entrypoints-0.1.8
```

最后一条只生成两种独立入口及摘要/manifest 候选，不下载产品、不需要 zsetup 源码、不改公网或索引。输出目录必须不存在。Windows/macOS 自动引导分别固定 zsetup 0.4.0/0.3.0 的官方 SHA256，只经 HTTPS 获取，校验后才执行；首次引导用系统 curl/PowerShell，业务下载使用 zsetup。`ZSETUP_BIN` 仅供开发调试，普通用户无需设置。

0.1.8维护者核验现有产品后更新内置pins，递增安装器版本并复测；不能只修改版本号或跟随远端指针。服务器元数据模型留作历史发布方案，见[发布文档](../docs/release.md)。
