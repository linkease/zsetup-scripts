# 0.2.0 本地候选：能力与验收边界

状态日期：2026-10-21。**本地集成完成，未发布**。冻结版全量测试、真实 zsetup 下载夹具与候选打包均已通过，完整证据见 [验证报告](verification-0.2.0.md)。没有本候选的部署回执或真机验收结论。

冻结版：278 项 Python 测试及 Windows 7 组脚本通过，其中 macOS 56 项、Docker 32 项、bootstrap 17 项、rules 8 项、OpenWrt 生命周期 29 项、pinned products 5 项（覆盖 16 个包组合）。这些仍是隔离测试，不是真机验收。

旧 0.1.10 测试目录 `https://web.toany.net/ddnsto-install/0.1.10/20261015-6c624972f4c9/` 与官网默认行为保持不变。调试页面必须显式设置审核后的独立候选 HTTPS URL；不得让默认命令悄悄指向 0.2.0，也不得覆写旧目录。

## 当前能力

| 平台 | 本轮源码能力 | 验证状态与限制 |
|---|---|---|
| Windows x64 | install/update/status/start/stop/restart/repair/configure/uninstall；卸载保留配置和身份，随后 install 复用；默认无操作重跑和交互菜单 | 7 组测试通过；管理员权限、SYSTEM 任务和真实重启仍需 Windows 验收 |
| macOS Intel / Apple Silicon | 同组动作；保留配置重装、离线修复 plist、显式 Token 配置及失败恢复 | 56 项测试通过；用户登录域 launchd，保留 disabled override 修复；仍需两种架构真机验收 |
| Linux x86_64 / aarch64 原生 | systemd 托管生命周期、配置保留、修复和失败恢复 | 分项模拟通过；configure 需要 jq。OpenRC 仅 install/update/status，其他写动作 fail closed |
| OpenWrt | opkg/apk 安装、更新、服务管理、配置、修复、卸载保留状态重装；临时 UCI 禁用防止包钩子提前启动，恢复原配置和原 enabled 状态 | 生命周期 29 项、pinned products 5 项通过，后者覆盖 16 组合；包回滚非原子，固件原生待验收 |
| Synology | SPK 4.2.7-4 固定 SHA256 下载后交给包中心手动导入 | helper 隔离测试通过；不是自动安装或身份迁移工具；仅 DSM 6 build≥5940 / DSM 7 build≥41890，x86_64、armv7，不含 arm64 |
| Docker | 通用 Linux amd64 上严格受限的首次创建及已有托管容器管理 | 工程候选，非完整生命周期；身份持久化和原生验收未验证，详见下节 |

原生 install/update/管理不等于自动升级最新版。完整既有安装默认重跑退出不修改；卸载保留的原生安装通过 `install` 恢复，不带 Token。`configure` 才是显式更换本地 Token 的动作，不代表服务端提供 Token 重置。归属不匹配、锁冲突或恢复不完整时停止并报告，不能自动接管同名服务。各平台恢复失败时应按输出检查保留的备份。

macOS configure 仅处理安装器格式的单行 `userToken`；仍加载但缺失 plist 的作业须先 repair 再 uninstall。Linux 的托管标记与有效 systemd 定义都要通过检查，不能只根据二进制文件名认领历史安装。

Linux OpenRC 仅保留 install/update/status；legacy marker 不能认证可执行的 shell 服务脚本，start/stop/restart/repair/configure/uninstall 均 fail closed，不能宣称完整管理或 full 生命周期。

OpenWrt update 与保留状态重装先核验/下载固定包，再备份完整 UCI 配置、临时提交 `enabled=0`，停止并确认旧服务。包钩子仍可能调用 start，但受禁用配置及已核查包默认值保护；包操作后恢复原配置字节，包括 Token、index、身份与 enabled，并按原 enabled 恢复服务，原禁用状态保持停止。失败传播错误并尝试恢复配置，恢复不安全时保留备份；包可能部分变更，**不提供原子包回滚**。旧 `config global` 格式不自动迁移；更换包 pin 或厂商修改 init/hooks 必须重新审查。详见 [OpenWrt 集成证据](openwrt-lifecycle-integration.md)。

## Docker 的严格边界

仅接受通用 Linux x86_64 主机和 Linux amd64 引擎、本地 Unix socket、非 Docker Desktop、非 rootless 环境。写操作要求直接在 root shell 中运行；仅为操作锁提权不够。不会安装或启动 Docker 引擎，不接入远端 daemon，不适用于 OpenWrt、群晖、QNAP 或 Unraid。

首次安装需 Token、设备名以及明确选择 `bridge` 或 `host`；只有确认无原生安装、无已有/冲突容器和无残留状态后才允许交互补齐。固定镜像是 `linkease/ddnsto@sha256:f70d2afbb0da6b21ff8865a4f3d9869775360bfbec1fff03474e5478a702ad30`，规则记录客户端 4.2.6。容器 ID、镜像、执行配置、环境、标签、挂载、网络及私有状态必须匹配，不能仅凭名字接管。

- `install` 重跑和 `update` 仅对同 pin 的已有托管容器返回 no-op，不拉取替换、不升级、不重建。
- `status/start/stop/restart` 管理已有容器；`repair` 仅启动该容器，不重建丢失的容器或配置。
- `uninstall` 停止并移除托管容器，保留全部私有状态。**卸载后重装、残留状态重建及替换升级均被阻止**，直到发布镜像的身份持久化路径获得证据并完成相应实现与验证。不要删状态目录绕过保护。
- 不支持 configure。已有容器拒绝新的 Token、设备名及网络参数。`container_running=true` 不是客户端健康或云端在线；仍输出 `client_process=unverified`、`cloud_status=unverified`、`identity_persistence=unverified`。plan 的 `docker_installable=false` 表示尚未获生产验收，不等于无候选执行器。

## 使用方式

以下本地命令供开发者在 `scripts/zsetup-scripts` 仓库目录、隔离环境或获准测试设备上使用。最终用户不需要 clone、不需要预装 zsetup，也不需要其核心源码；由发布者提供单文件候选 HTTPS 入口的包装命令。

```sh
# 只读预览
sh ddnsto/install.sh --plan
# 按上表支持范围选择动作；OpenRC 仅 install/update/status
sh ddnsto/install.sh --action status
# 显式改 Token；文件须由调用者保护
sh ddnsto/install.sh --action configure --token-file /private/new-token.txt
# 原生卸载保留状态后恢复，不重新提供 Token
sh ddnsto/install.sh --action install
# 群晖：允许 auto/native；默认输出到当前目录 ddnsto-downloads 下的独立子目录
sh ddnsto/install.sh --platform synology --method native --action download
sh ddnsto/install.sh --platform synology --action download --output-dir /volume1/downloads
```

群晖 `download` 成功返回 0；默认 `install` 同样下载，但返回 **20** 表示人工交接，输出 `installation_performed=false` 和 `manual-required`。plan 返回 0 且不下载、不创建目录。拒绝 Token/TokenFile、force-version 和 verify-status；不会调用 synopkg。导入前按包说明备份旧 Token、配置与设备身份，升级/迁移后核对身份和控制台设备，不把下载完成当作安装或迁移成功。

Windows 管理员 PowerShell：`powershell -File ddnsto/install.ps1 -Plan`、`-Action status`、`-Action configure -TokenFile C:\private\new-token.txt`。原生卸载后使用 `-Action install` 恢复保留状态。

Docker 示例仅供获准的通用 Linux amd64 测试机：先 `sudo -i` 进入 root shell，再定位到本地源码目录执行。首次安装会改变容器状态，不能作为普通文档检查命令运行。

```sh
sh ddnsto/install.sh --platform linux --method docker --plan
sh ddnsto/install.sh --platform linux --method docker --device-name test-device --network bridge --token-file /root/ddnsto-token.txt
sh ddnsto/install.sh --platform linux --method docker --action status
```

最终用户的 HTTPS 包装模板如下。候选未发布时没有可填写的 0.2.0 URL；由发布者审核入口摘要、回读字节并提供准确 URL 后使用。环境变量只是这个示例的显式 URL 输入，不是自动发现发布地址的机制。

```sh
: "${DDNSTO_CANDIDATE_SH_URL:?请先设置审核后的候选 install.sh HTTPS URL}"
case "$DDNSTO_CANDIDATE_SH_URL" in
  https://*) entry=$(curl -fsSL --proto '=https' --proto-redir '=https' "$DDNSTO_CANDIDATE_SH_URL") &&
    test -n "$entry" && sh -c "$entry" ddnsto --plan ;;
  *) printf '%s\n' '需要 HTTPS 候选 URL' >&2; exit 2 ;;
esac
```

预览后按设备能力替换末尾 `--plan` 为所需参数；群晖也可用默认 install 做人工交接。包装不使用 `curl | sh`，为交互输入保留终端。Docker 写操作仍须 root shell。Windows 对应模板：

```powershell
$ErrorActionPreference = 'Stop'
if (-not $env:DDNSTO_CANDIDATE_PS_URL -or ([uri]$env:DDNSTO_CANDIDATE_PS_URL).Scheme -ne 'https') { throw '请设置审核后的 install.ps1 HTTPS URL' }
$entry = (Invoke-WebRequest -UseBasicParsing -MaximumRedirection 0 $env:DDNSTO_CANDIDATE_PS_URL).Content
if ([string]::IsNullOrWhiteSpace($entry)) { throw '候选入口为空' }
& ([ScriptBlock]::Create($entry)) -Plan
```

## 固定依赖与本地构建

DDNSTO 的 zsetup 固定为 Linux/OpenWrt **0.5.0**、macOS **0.3.0**、Windows **0.4.0**，不是跟随 stable，也不是客户端版本。Linux bootstrap 要求可用 SHA256 工具，拒绝 HTTP 降级；桌面保留既有 HTTPS/摘要策略。具体产品、架构与摘要见 [install-rules.json](../ddnsto/install-rules.json)、`product-pins.sh` 和各平台源码；规则声明不能覆盖执行器更严格的拒绝条件。FastNet 不随本候选变更。

```sh
# 开发者生成与检查；不需要 zsetup 核心源码
python3 -B scripts/build-entrypoints.py
python3 -B scripts/build-entrypoints.py --check
python3 -B ddnsto/tests/cross_platform_installer_test.py
# 输出必须是全新目录；目录名本身不会设置 catalog 中的版本
python3 -B scripts/package-entrypoints.py --output dist/ddnsto-entrypoints-0.2.0
(cd dist/ddnsto-entrypoints-0.2.0 && sha256sum -c SHA256SUMS)
```

本候选只使用 `package-entrypoints.py` 打包共享独立入口。它检查生成入口一致性，按 catalog 生成两个入口及不可变版本副本、SHA256SUMS、manifest，并在 `binary/ddnsto/0.2.0/install-rules.json` 附带固定版本审计元数据，纳入摘要和 manifest。该 JSON 不作为运行时远程策略，各脚本仍独立执行。产物不包含 zsetup 或客户端产品，不部署、不改全局索引。集成人须先确认 catalog 为 0.2.0 并重建入口；不能用输出目录名掩盖旧版本。历史 `package-release.py --zsetup-root ...` 完整索引流程不是此交付的前置条件。

跨平台 runner 缺少 pwsh 时会跳过 Windows，不能计作 Windows 通过。本次提供了 PowerShell 与真实 zsetup，冻结版无跳过；各类证据详见验证报告。

## 发布前外部验收门槛

| 门槛 | 必须记录的证据 |
|---|---|
| 本地集成（已完成） | 冻结版测试、真实下载夹具、生成入口与候选 manifest 已核验，见验证报告；不替代下面的外部验收 |
| HTTPS 发布 | 经授权部署到独立不可变目录；两入口及摘要回读一致；错误/空响应不执行；旧 0.1.10 字节和官网默认不变；调试 URL 仅显式启用 |
| Linux | systemd 两架构冷安装、健康接口、重启、自启禁用、锁冲突、失败恢复、保留配置重装及身份对比；OpenRC 单独验已有能力，不扩大生命周期支持 |
| Windows / macOS | Windows 管理员/SYSTEM 与 macOS 两架构用户登录域；重启/重新登录、停止后不自启、disabled 覆盖恢复、任务/plist 缺失修复、凭据更换失败回滚、卸载重装身份一致；真实 Token 的控制台在线核对 |
| OpenWrt | 实机 opkg/apk、宣称支持的 CPU/ABI 和内存档位；包更新/卸载的 UCI 与身份保留、procd、自启、LuCI 兼容、包失败后的可恢复路径；不把模拟当包事务回滚证明 |
| Synology | 四个固定 SPK 的下载摘要和 DSM 最低版本检查；对应 DSM/架构包中心手动导入、安装/升级权限、服务启停及旧设备身份迁移；下载退出 0 不代替这些验收 |
| Docker | 实际 pin 镜像的 Linux amd64 内容/启动配置，root 引擎 bridge/host 连通性、容器重启与宿主重启、客户端进程/控制台在线；定位并验证身份所有持久化输入，完成重建/升级实现及回归后才能解除当前禁止项 |

每项须带日期、设备/环境、入口与产品摘要、实际命令、退出码和脱敏证据。真实 Token 不进入源码、日志归档或发布包。缺设备、权限、已审核 URL 或身份迁移证据时保留候选状态；不能写成“全部平台完成”。

最终候选：`dist/ddnsto-entrypoints-0.2.0/`，含 manifest、审计规则和摘要。冻结版及真实下载夹具结果见 [验证报告](verification-0.2.0.md)。发布回执与原生验收：**未提供**。
