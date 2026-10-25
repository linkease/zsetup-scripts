# zsetup-scripts

FastNet、DDNSTO、LinkEase、FastPVE 的统一业务安装仓库。业务脚本负责包管理、服务和业务参数；可靠下载、系统探测、后台执行与安装选择复用 [zsetup](../../linkease-vpn/linkease-tunnel/zsetup-rust/README.md)。当前 scripts0.1.8 的存储协议要求 zsetup **>=0.5.0**；安装入口动态读取线上 stable，索引绑定该核心的完整版本。

设备已有 zsetup：

```sh
zsetup install fastnet
zsetup install ddnsto -- --token 'YOUR_TOKEN'
zsetup install linkease
zsetup install fastpve
```

设备没有 zsetup，发布完成后的一条命令入口：

```sh
sh -c "$(curl -fsSL https://fw.koolcenter.com/binary/fastnet/fastnet-install.sh)"
sh -c "$(curl -fsSL https://fw.koolcenter.com/binary/ddnsto/ddnsto-install.sh)" -- --token 'YOUR_TOKEN'
sh -c "$(curl -fsSL https://fw.koolcenter.com/binary/linkease/linkease-install.sh)"
sh -c "$(curl -fsSL https://fw.koolcenter.com/binary/fastpve/fastpve-install.sh)"
```

也可将 `curl -fsSL URL` 换成 `wget -qO- URL`。首先取得入口脚本依赖系统 curl/wget；脚本取得 zsetup 后，业务下载均使用 zsetup 内置 SHA256。HTTPS bootstrap 全部失败时才允许向交互用户询问 HTTP 风险，默认拒绝；zsetup 本身始终只接受 HTTPS。

**当前发布范围：FastNet 已公网发布，其他业务的新入口仍为本地候选。** 产品包由各业务发布流程提前放到服务器，安装时由 zsetup 下载和校验。本仓库不采集、不缓存、不打包产品包；发布工具仅组装安装入口、权威 zsetup release 与完整配置。FastNet 使用独立发布流程，不能用完整多业务候选覆盖线上；服务器产品文件及版本/SHA256 元数据要求见 [发布流程](docs/release.md)。

| 应用标识 | 支持平台 | 架构 | 业务参数与交互 |
|---|---|---|---|
| `fastnet` | Linux/OpenWrt；启动后由 FastNet 管理菜单 | x86_64、aarch64、armv7 | 参数逐项原样传给 FastNet；菜单交互由业务程序决定 |
| `ddnsto` | OpenWrt opkg/apk | x86_64、aarch64、armv7、mipsel | `--token TOKEN` 可选；`--force-version lite\|standard` 可选；低于 900 MB 自动选 Lite；`--verify-status` 检查服务 |
| `ddnsto` | Ubuntu/Debian apt、CentOS/RHEL yum/dnf、其他已识别 Linux | x86_64、aarch64 | 默认 Standard 4.2.3；`DDNSTO_VERSION` 可覆盖已发布版本；无终端必须传 `--token` |
| `ddnsto` | Windows 10 x64 WOW64 / PowerShell 5.1 | x86_64 CLI | `ddnsto/install.ps1`；固定校验的 CLI 4.2.1；使用计划任务随系统启动；必须提供 `-Token` |
| `ddnsto` | macOS | x86_64、arm64 | `ddnsto/install-macos.sh`；固定校验的 CLI 4.2.1；使用用户级 launchd；必须提供 `--token` |
| `linkease` | OpenWrt opkg、Ubuntu/Debian、CentOS/RHEL、通用 Linux | x86_64、aarch64、armv7 | `--version VERSION` 可选；Linux 默认 1.7.5；无菜单/token 交互 |
| `fastpve` | PVE 宿主机（Debian / apt），root、pveversion 必需 | x86_64 | 默认前台菜单；参数原样传给 FastPVE；PVE 大版本兼容性待设备验证 |

默认前台执行，并传播业务退出码。自动化不要把“后台启动成功”当成“安装完成”；后台用 `zsetup install ddnsto --background -- --token TOKEN`，读取命令输出中的日志/result 路径。后台 stdin 已关闭，必须提供 token。细节见 [AI 调用约定](docs/ai-contract.md)。

业务按根目录模块组织：[fastnet/](fastnet/README.md)、[ddnsto/](ddnsto/README.md)、[linkease/](linkease/README.md)、[fastpve/](fastpve/README.md) 各自拥有业务脚本、测试和说明；DDNSTO 的兼容入口发布规则也位于 ddnsto/。公共 lib/scripts/tests/docs 仅保留共享 bootstrap、统一构建、跨模块验证与协议文档。

```text
zsetup-scripts/
  fastnet/          # fastnet-install.sh、business.sh、main.sh、README、tests/
  ddnsto/           # ddnsto-install.sh、Windows/macOS 入口、业务源码、测试、release.py
  linkease/         # linkease-install.sh、business.sh、main.sh、README、tests/
  fastpve/          # fastpve-install.sh、business.sh、main.sh、README、tests/
  legacy/           # 原仓库旧脚本快照与来源说明，仅供历史参考
  lib/              # 共享 shell bootstrap
  scripts/          # 统一生成、打包与验收
  tests/            # 仓库布局与统一发布包测试
  docs/             # 发布、扩展、AI 协议与验证证据
  catalog.json      # 统一安装索引的构建输入
```

共享 bootstrap 构建时嵌入各模块的唯一 APP-install.sh，业务逻辑不复制维护；运行中的入口不会下载自身。旧脚本集中归档到 [legacy/](legacy/README.md)，保存原业务仓库的实际历史源码；根目录不保留旧别名。日常维护与调用使用 fastnet/fastnet-install.sh、ddnsto/ddnsto-install.sh、linkease/linkease-install.sh、fastpve/fastpve-install.sh 或 zsetup install。FastNet仓库仅同步本仓库的生成入口，其他业务仓库保持原状。

当前生产部署只使用 [FastNet 独立发布](docs/fastnet-independent-release.md) 生成的明确文件清单，映射到站点 `/binary/fastnet/` 和共享索引 `/binary/zsetup/config.json`。完整 aggregate 包用于候选验收，不能批量激活其他业务。仓库源码、测试和维护工具不上传网站。版本化脚本与包保持不可变；核心升级使用 zsetup-rust 的独立 Linux 发布流程。

开发与验收：

```sh
python3 -B scripts/build-entrypoints.py
sh scripts/check.sh /path/to/linkease-tunnel/zsetup-rust /path/to/RUST-RELEASE-PACKAGE
python3 -B scripts/package-release.py --zsetup-root /path/to/linkease-tunnel/zsetup-rust \
  --zsetup-release /path/to/RUST-RELEASE-PACKAGE --require-clean
```

第三条在干净提交后生成安装脚本、zsetup 和配置候选，不访问产品服务器、不需要本地产品文件。dist/release 是本仓库的发布输出，dist/evidence 是验证日志；不再生成 ddnsto-artifacts。新增业务步骤见 [接入约定](docs/extension.md)，迁移归属和测试基线见 [盘点](docs/inventory.md)。

跨平台 DDNSTO 入口的当前边界见 [ddnsto/README.md](ddnsto/README.md)。Windows/macOS 入口使用客户端业务发布目录中的 CLI 归档，不把客户端二进制复制进本仓库；归档版本和 SHA256 必须随业务发布物同步更新。

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
