# zsetup-scripts

DDNSTO 推荐版本更新、验收、发布和回滚统一遵循 [发布 SOP](docs/ddnsto-release-sop.md)，
每次使用其链接的发布记录模板留存证据。

2026-11-20 本地迁移方案：[独立安装域名与业务环境](docs/ddnsto-install-deployment.md)。
DDNSTO 安装站点由本仓库单独打包；控制台固定引用 install.ddnsto.com，
测试参数只切换客户端业务环境，不切换脚本推荐渠道。域名尚未部署。

DDNSTO 原生一键安装的推荐版本和产品摘要现统一维护在
[`apps/ddnsto/source/platform-releases.json`](apps/ddnsto/source/platform-releases.json)，支持各平台独立版本。
修改后执行 `python3 -B scripts/build-ddnsto-products.py` 和 `python3 -B scripts/build.py`，
再审核发布；设备端不增加配置解析依赖。带有对应
`apps/ddnsto/source/templates/*.in` 的文件为生成副本，维护规则见
[分平台推荐配置](docs/ddnsto-platform-releases.md)。以下旧版平台表中的固定版本不是当前推荐配置。

FastNet、DDNSTO、LinkEase、FastPVE、Linkspace 及 KSpeeder 项目的统一业务安装仓库。业务脚本负责包管理、服务和业务参数；可靠下载、系统探测、后台执行与安装选择复用 [zsetup](../../linkease-vpn/linkease-tunnel/zsetup-rust/README.md)。应用分别声明 zsetup 能力最低版本；安装入口读取平台最新 stable，较新的兼容核心不会被旧配置降级。规则和提升门禁见 [zsetup 兼容策略](docs/zsetup-compatibility.md)。

[`apps/ks-cli`](apps/ks-cli/README.md) 与
[`apps/kspeeder`](apps/kspeeder/README.md) 的 0.1.2 已支持 Linux、macOS
和 Windows。它们从四站点的不可变 KSpeeder 发布 ID 目录下载并校验产品，只安装
用户级二进制，不自动注册或启动服务。全平台产品镜像和完整 apps 已于 2026-11-22
发布并通过四站点校验；未来最新版发现、资产锁定、apps 验证及产品发布统一使用
[`scripts/release-kspeeder.py`](scripts/release-kspeeder.py)，服务器同步和回滚方案见
[产品镜像说明](docs/kspeeder-product-mirror.md)。

既有全局配置已经收录的应用仍可直接使用 zsetup：

```sh
zsetup install fastnet
zsetup install ddnsto -- --token 'YOUR_TOKEN'
zsetup install linkease
zsetup install fastpve
```

zsetup-scripts 整体业务发布完成后，统一入口会自行取得 zsetup 核心和本项目配置：

```sh
sh -c "$(curl -fsSL https://fw.koolcenter.com/binary/zsetup-scripts/apps/fastnet/fastnet-install.sh)"
sh -c "$(curl -fsSL https://fw.koolcenter.com/binary/zsetup-scripts/apps/ddnsto/ddnsto-install.sh)" -- --token 'YOUR_TOKEN'
sh -c "$(curl -fsSL https://fw.koolcenter.com/binary/zsetup-scripts/apps/linkease/linkease-install.sh)"
sh -c "$(curl -fsSL https://fw.koolcenter.com/binary/zsetup-scripts/apps/fastpve/fastpve-install.sh)"
```

也可将 `curl -fsSL URL` 换成 `wget -qO- URL`。首先取得入口脚本依赖系统 curl/wget；脚本取得 zsetup 后，业务下载均使用 zsetup 内置 SHA256。HTTPS bootstrap 全部失败时才允许向交互用户询问 HTTP 风险，默认拒绝；zsetup 本身始终只接受 HTTPS。

**完整 `apps/` 已于 2026-11-22 通过统一协调器发布到
`/binary/zsetup-scripts/apps/`。当前 Release ID 为
`417dbd781529dffbbf41f638d7871fa2c8ed7d35da589c0f9a35babb7a9c4902`。**
FastNet、Linkspace、ks-cli、KSpeeder 等既有独立入口属于兼容/冗余实现，不再作为整体发布状态的判定依据。
产品包继续由各业务发布流程提前放在现有 `/binary/APP/` 目录，安装时由 zsetup 下载和校验；
本仓库只把完整 `apps/` 目录作为一个 zsetup-scripts 业务命名空间发布，不采集或复制产品包。
整体候选以后只使用 [apps 发布协调器](docs/apps-release.md)：它强制从 `binary` 根派生
`binary/zsetup-scripts/apps`，按 release ID 打包完整 `apps/`，执行暂存、切换、回滚和
四站点逐字节回读，避免人工命令把目录映射到错误位置。服务器产品文件及版本/SHA256
元数据要求见 [发布流程](docs/release.md)。

| 应用标识 | 支持平台 | 架构 | 业务参数与交互 |
|---|---|---|---|
| `fastnet` | Linux/OpenWrt；启动后由 FastNet 管理菜单 | x86_64、aarch64、armv7 | 参数逐项原样传给 FastNet；菜单交互由业务程序决定 |
| `ddnsto` | OpenWrt opkg/apk | x86_64、aarch64、armv7、mipsel | `--token TOKEN` 可选；`--force-version lite\|standard` 可选；低于 900 MB 自动选 Lite；`--verify-status` 检查服务 |
| `ddnsto` | Ubuntu/Debian apt、CentOS/RHEL yum/dnf、其他已识别 Linux | x86_64、aarch64 | 默认 Standard 4.2.3；`DDNSTO_VERSION` 可覆盖已发布版本；无终端必须传 `--token` |
| `ddnsto` | Windows 10 x64 WOW64 / PowerShell 5.1 | x86_64 CLI | 标准入口 `apps/ddnsto/ddnsto-install.ps1`；使用计划任务随系统启动；必须提供 `-Token` |
| `ddnsto` | macOS | x86_64、arm64 | 标准入口 `apps/ddnsto/ddnsto-install.sh`；使用用户级 launchd；必须提供 `--token` |
| `linkease` | OpenWrt opkg、Ubuntu/Debian、CentOS/RHEL、通用 Linux | x86_64、aarch64、armv7 | `--version VERSION` 可选；Linux 默认 1.7.5；无菜单/token 交互 |
| `fastpve` | PVE 宿主机（Debian / apt），root、pveversion 必需 | x86_64 | 默认前台菜单；参数原样传给 FastPVE；PVE 大版本兼容性待设备验证 |
| `ks-cli` | Linux、macOS、Windows | Linux x86_64/aarch64/armv7；macOS/Windows x86_64/arm64 | 只安装用户级 CLI，不执行业务命令或安装服务 |
| `kspeeder` | Linux、macOS、Windows | Linux x86_64/aarch64/armv7；macOS/Windows x86_64/arm64 | 只安装用户级二进制，不注册或启动服务 |

默认前台执行，并传播业务退出码。自动化不要把“后台启动成功”当成“安装完成”；后台用 `zsetup install ddnsto --background -- --token TOKEN`，读取命令输出中的日志/result 路径。后台 stdin 已关闭，必须提供 token。细节见 [AI 调用约定](docs/ai-contract.md)。

`apps/` 是唯一业务源码树，也是整体发布时原样复制到服务器的目录。每个应用由
`apps/<id>/app.json` 声明身份和当前版本，`apps/<id>/<version>/installer.*` 是配置索引引用的
版本化安装器；复杂应用的可维护源码放在 `apps/<id>/source/`。所有测试和测试夹具位于
`tests/`，不会随 `apps/` 发布。公共 `lib/`、`scripts/`、`tests/`、`docs/` 只保留共享能力、
发布工具、验收和协议文档。

```text
zsetup-scripts/
  apps/             # 唯一业务源码和完整发布树
    APP/app.json    # 应用身份、当前版本、平台和兼容别名
    APP/VERSION/    # 配置索引引用的不可变 installer.sh / installer.ps1
    APP/source/     # 可选的复杂应用维护源码；不含测试
  legacy/           # 原仓库旧脚本快照与来源说明，仅供历史参考
  lib/              # 共享 shell bootstrap
  scripts/          # 统一生成、打包与验收
  tests/apps/       # 应用测试和夹具，不复制到服务器
  tests/contracts/  # 目录、构建和发布契约
  docs/             # 发布、扩展、AI 协议与验证证据
  catalog.json      # 统一安装索引的构建输入
```

共享 bootstrap 只用于生成 `apps/APP/install.*` 及兼容别名；真正被索引和校验的是版本化
`apps/APP/VERSION/installer.*`。业务逻辑只在所属 `apps/APP/` 内维护，运行中的入口不会下载自身。
旧脚本集中归档到 [legacy/](legacy/README.md)，根目录不再保留业务目录或旧别名。日常调用使用
`apps/APP/APP-install.*` 或 `zsetup install APP`。

既有生产部署使用 [FastNet 独立发布](docs/fastnet-independent-release.md) 等历史流程，映射到
`/binary/APP/` 和共享 `/binary/zsetup/config.json`；这些路径继续保留，不能用完整 aggregate
包覆盖。新的整体 `apps/` 候选使用独立 `/binary/zsetup-scripts/apps/` 命名空间，只能通过
上述协调器发布。仓库测试和维护工具不会进入该公共树；版本化脚本保持不可变，核心升级仍
使用 zsetup-rust 的独立发布流程。

开发与验收：

```sh
python3 -B scripts/build-entrypoints.py
sh scripts/check.sh /path/to/linkease-tunnel/zsetup-rust /path/to/RUST-RELEASE-PACKAGE
scripts/check-zsetup-candidate.sh /absolute/path/to/zsetup
python3 -B scripts/package-release.py --zsetup-root /path/to/linkease-tunnel/zsetup-rust \
  --zsetup-release /path/to/RUST-RELEASE-PACKAGE --require-clean
```

第三条在干净提交后生成安装脚本、zsetup 和配置候选，不访问产品服务器、不需要本地产品文件。dist/release 是本仓库的发布输出，dist/evidence 是验证日志；不再生成 ddnsto-artifacts。新增业务步骤见 [接入约定](docs/extension.md)，迁移归属和测试基线见 [盘点](docs/inventory.md)。

跨平台 DDNSTO 入口的当前边界见 [DDNSTO 应用说明](apps/ddnsto/README.md)。Windows/macOS
入口使用客户端业务发布目录中的 CLI 归档，不把客户端二进制复制进本仓库；归档版本和
SHA256 必须随业务发布物同步更新。

维护者和 AI 使用的共享编译工具链位于 `/projects/workspace-linkease-ubuntu/toolchains/`，
由原生 zsetup 仓库锁定版本、准备和复用，设置 `LINKEASE_TOOLCHAIN_ROOT` 即可指定。
目录用途和平台状态见原生仓库 `zsetup/docs/plans/2026-10-09-desktop-portability.md`，
工具链根目录也提供 README；业务安装脚本不需要这些编译依赖。

2026-10-14：后续 zsetup 统一 Rust，脚本候选为 scripts-0.1.7。`--zsetup-release`
接收 Rust 的完整 platform package，复用其不可变原生产物和字节校验；配置生成
由 zsetup-rust 唯一实现。POSIX bootstrap 按 Linux/Darwin 选择 OS 文件/stable，
Windows 使用 canonical PowerShell win32 bootstrap。Mac bootstrap 支持不代表
已有 Mac 业务；catalog 仍只声明实际已验证的 Linux 业务，Windows/Mac 不虚构映射。
0.4.0 本体已激活 Linux/Windows、Mac仍候选；本体包不发布本仓库的新业务脚本，保留原线上业务 hash/path；本仓库0.1.7
后续独立发布/业务设备 canary仍需完成。core原生证据/发布阻塞见
[统一Rust记录](../../linkease-vpn/linkease-tunnel/zsetup-rust/docs/2026-10-14-unified-rust-release.md)。
