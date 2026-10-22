# DDNSTO

## 当前快照：0.2.0 本地候选，未发布

本轮 Windows/macOS 完整原生生命周期分项模拟通过：安装、更新、状态、启停、重启、修复、显式配置、卸载保留配置与身份、保留状态重装，以及默认无修改重跑。已报告 macOS 56 项测试、Windows 7 组测试通过；这不是最终全量结果。Linux 提供同类托管流程，但 repair/configure/uninstall 当前仅接受可验证归属的 **systemd**；configure 需要 jq。OpenRC 仅保留 install/update/status，其他写动作 fail closed；legacy marker 不能认证 shell 服务脚本，不能宣称完整管理或生命周期。

OpenWrt 已实现 update 与卸载保留状态重装闭环：临时 UCI `enabled=0` 防止包钩子提前启动，随后恢复原配置和原 enabled 状态。生命周期 29 项、pinned products 5 项测试通过，后者覆盖 16 组合。该保护不提供包级原子回滚；opkg/apk 对应固件、ABI、配置/身份保留及服务行为仍待原生验收。详见 [OpenWrt 集成证据](../docs/openwrt-lifecycle-integration.md)。冻结版全量测试、真实下载夹具及产物均通过，见 [验证报告](../docs/verification-0.2.0.md)。

群晖已实现 SPK 4.2.7-4 固定摘要下载和包中心人工交接：DSM 6≥5940 / DSM 7≥41890，仅 x86_64、armv7。`--method auto|native` 均可；默认下载到 `$PWD/ddnsto-downloads` 的独立子目录，可用 `--output-dir` 指定。`--action download` 返回 0；默认 install 返回 20，表示下载完成、尚需手动安装，不调用 synopkg。拒绝凭据及安装专用选项，导入前须阅读身份迁移提醒。

Docker 仅为通用 Linux amd64、本地非 rootless/非 Desktop 引擎的严格候选；写操作须 root shell。支持首次创建与已有托管容器管理；update 仅同 pin no-op，repair 仅启动已有容器。身份持久化未验证，禁止重建、替换升级和卸载后重装；不支持 configure，不宣称完整生命周期。

DDNSTO 固定 zsetup：Linux/OpenWrt 0.5.0、macOS 0.3.0、Windows 0.4.0。共享独立入口构建/打包无需 zsetup 核心源码，使用 `build-entrypoints.py` 和 `package-entrypoints.py`；固定版本目录附带 `install-rules.json` 审计元数据，各脚本仍独立运行，不依赖运行时获取该文件。不走历史完整索引打包前置流程。最终用户通过已审核候选 HTTPS 入口包装执行，不要求 clone 或预装下载器。

开发者在本仓库根目录使用：

```sh
python3 -B scripts/build-entrypoints.py
sh ddnsto/install.sh --plan
python3 -B ddnsto/tests/cross_platform_installer_test.py
python3 -B scripts/package-entrypoints.py --output dist/ddnsto-entrypoints-0.2.0
```

以上是使用示例，不是本轮最终全量通过记录。生成入口及 catalog 由集成人统一整合；输出目录必须不存在。Windows 示例为 `powershell -File ddnsto/install.ps1 -Plan`。更多动作、最终用户 HTTPS 包装、Docker 限制和逐平台外部验收门槛见 [0.2.0 候选说明](../docs/candidate-0.2.0.md)，构建职责见[架构](../docs/one-command-architecture.md)与[发布流程](../docs/release.md)。

旧 0.1.10 测试 URL 与官网默认保持不变；调试候选 URL 必须显式提供。当前没有 0.2.0 发布回执。本地集成通过不等于真机、云端在线或发布验收。

<details>
<summary>0.1.x 历史记录（下方“当前”、未实现项和命令均指当时版本）</summary>

## 0.1.16 本地开发候选（未发布）

Windows 新增显式本地任务修复，在管理员 PowerShell 中执行：

```powershell
powershell -File ddnsto/install.ps1 -Action repair
```

适用于本安装器安装过、程序和配置/托管标记完整，但计划任务丢失，或需要重新注册计划任务的情况。复用已有 EXE、Token、配置及设备身份，不下载、不升级、不重新询问 Token；重建启动任务并启动客户端。不能修复损坏/缺失的 EXE、配置或网络/云端绑定问题，不接受 Token/TokenFile 或 Plan。

同名任务存在但执行路径/参数/工作目录不匹配时拒绝覆盖；安装锁被占用也会拒绝。修复失败尝试恢复原任务 XML 和原先运行状态；恢复失败保留 `.repair-*/old-task.xml` 并提示人工检查。原先没有任务且修复失败时尝试移除新任务。配置和身份不被重写。

成功输出 `operation=repair local_service=running cloud_status=unverified`，只代表任务运行检查通过，不代表设备云端在线。默认重跑仍仅提供退出/更新，repair 需显式调用。当前仅 Windows 实现 repair；其他平台修复、统一卸载、NAS/Docker 执行器和修改 Token 仍待开发。已做隔离测试，尚未 Windows 真机验收；未提交、推送或部署。

## 0.1.15 本地开发候选（未发布）

Linux/OpenWrt 新增安装、更新和 start/stop/restart 共用的机器级操作锁。两条命令同时运行时，后来的写操作返回 16，不下载业务安装包、不变更服务，也不删除前一个操作的锁。`status`、`--plan` 和默认重跑退出仍不获取写锁；状态查询是瞬时观察，不保证与更新过程一致。

锁覆盖业务下载、安装和失败恢复；恢复/清理结束后才释放。正常结束、失败及可捕获信号退出会尝试释放锁；SIGKILL/掉电可能遗留锁，不自动抢占。默认位置为 `/var/lock/ddnsto-installer.lock`。遇到退出码 16，先确认是否有安装或管理进程正在执行，再检查锁目录权限；不要在操作仍进行时手动删锁。明确确认无相关进程后，才可由管理员用 `rmdir /var/lock/ddnsto-installer.lock` 清理空的遗留锁，非空锁应先检查，不能递归强删。

此保护只协调本版本脚本，不协调旧脚本、手工 systemctl/opkg/apk 或其他管理插件；首次 zsetup bootstrap 在业务锁之外。命令语法不变。macOS/Windows 保持各自已有安装锁。仍未提供统一卸载、NAS/Docker 执行器或修复/改 Token 菜单。未提交、推送或部署。

以下是历史记录；0.1.14 中“Linux/OpenWrt 暂无共享锁”的限制已由本增量替代。

## 0.1.14 本地开发候选（未发布）

Linux（systemd/OpenRC）、OpenWrt 和 Windows 新增 status/start/stop/restart，与既有 macOS 入口对齐。以下命令使用本地候选，不是线上旧脚本的新能力：

```sh
sh ddnsto/install.sh --action status
sh ddnsto/install.sh --action stop
sh ddnsto/install.sh --action start
sh ddnsto/install.sh --platform linux --action restart
```

Windows 在管理员 PowerShell 使用 `powershell -File ddnsto/install.ps1 -Action status`，将 status 换成 stop/start/restart 即可。平台约束仍有效，例如 OpenWrt 可加 `--platform openwrt`。

管理不下载 zsetup/客户端、不要求 Token、不改配置和设备身份；不要同时传凭据或 plan。stop 关闭自启并停止服务，start 恢复自启，restart 恢复自启并重启。Linux 需要 root/sudo，OpenWrt 需要 root。状态返回 `local_service=... cloud_status=unverified`，不表示设备已在云端上线；启动成功目前检查服务状态而非安装阶段的完整健康检查。

Linux/OpenWrt 要求完整既有原生安装及对应服务，否则报错；Windows 要求托管标记及任务执行路径匹配，并复用安装锁。Linux/OpenWrt 暂无安装/管理共享锁，请勿并发运行。命令中途失败可能已改变自启或停止状态，不承诺回滚；解决错误后重新执行 start/status 确认。统一卸载、修复/改 Token 菜单、NAS/Docker 执行器仍未完成。

历史版本记录如下；最新行为以本节和[实施契约](../docs/universal-install-contract.md)为准。

## 0.1.13 本地开发候选（未发布）

四类现有安装器新增重跑保护：检测到完整已有安装时，非交互默认退出；交互菜单默认 `0` 退出、`1` 更新。默认退出不替换程序、不停止服务、不要求 Token；Linux 直接入口也不会先下载 zsetup，可离线退出。已有部分文件但安装不完整时拒绝自动覆盖。

显式更新命令（在目标设备使用本地候选脚本，不是当前公网链接）：

```sh
# Linux / OpenWrt / macOS：复用现有配置和 Token
sh ddnsto/install.sh --action update
```

Windows：`powershell -File ddnsto/install.ps1 -Action update`。更新拒绝同时传 Token/TokenFile，首次安装不能调用 update。Linux 更新通过已有配置启动，不再重新传 `-u` 覆盖 Token。OpenWrt 仍需实机验证包管理器的配置保留和升级行为。

当前菜单只有退出/更新；修改 Token、服务修复菜单、Docker/SPK 执行器、统一卸载尚未完成，不能将此版本当作完整产品交付。0.1.12 及之前为历史增量。

## 0.1.12 本地开发候选（未发布）

- Shell `--plan` / PowerShell `-Plan` 只读预览，不下载 zsetup、不读取 Token、不创建安装目录、不操作系统服务。预览是本地初筛，不代表依赖、权限或云端已验收。
- macOS 增加 `--platform macos --method native`；Windows 增加 `-Platform windows -Method native`。平台/方法不匹配在安装前拒绝。
- Linux/OpenWrt 预览报告 Docker 检查结果；远端 endpoint 不会连接。即使引擎可达，`docker_installable=false`：镜像、网络和执行器仍待接入。
- macOS 可通过同一 Shell 入口执行 `--action status|start|stop|restart`。stop 禁用登录自启并卸载服务，避免 KeepAlive 拉起；start 恢复自启。无需 Token 或下载，保留配置与身份，仅管理已有托管安装。
- Linux/OpenWrt 的交互 Token 输入改为可见，不额外写入日志。Windows 输入行为暂未变更。

本地验证示例（相对本仓库根目录，不是公网已发布命令）：

```sh
sh ddnsto/install.sh --plan
sh ddnsto/install.sh --plan --platform linux --method native
# 以下管理命令仅在 macOS 已有托管安装上运行：
sh ddnsto/install.sh --platform macos --action status
sh ddnsto/install.sh --platform macos --action stop
sh ddnsto/install.sh --platform macos --action start
```

Windows 本地预览：`powershell -File ddnsto/install.ps1 -Plan -Platform windows -Method native`。
Linux/OpenWrt/Windows 暂未提供统一管理 action；NAS/Docker 安装、重复执行菜单、完整版本规则仍待开发。见[实施契约](../docs/universal-install-contract.md)。

## 历史增量

0.1.11 本地开发候选（未发布）：Linux/OpenWrt 增加 `--platform`、`--method` 约束，已识别的群晖/QNAP/Unraid 不再进入普通 Linux 安装。NAS 和 Docker 执行器尚未接入，显式请求会停止并提示，不回退原生安装。桌面参数、线上测试入口及官网生产行为未改。[已确认方案、架构与后续增量](../docs/universal-install-contract.md)。

0.1.10 测试修复版：macOS 安装前读取 launchd 禁用状态，兼容 `disabled` / `true`；安装会重新启用被禁用的 DDNSTO 用户服务，失败时恢复原有禁用状态及旧安装。保留 Token 和设备身份。测试站地址与验收边界见 [0.1.10 修复记录](../docs/macos-disabled-fix-2026-10-15.md)。旧固定 GitHub / 0.1.9 链接不会自动更新。

0.1.9历史变更：按macOS实际使用反馈将Token终端输入改为可见（不额外打印或写入日志），并明确提示客户端为固定4.2.1、未查询最新版。Linux/OpenWrt/Windows交互不变。

## 历史测试：0.1.8 GitHub固定入口

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

</details>
