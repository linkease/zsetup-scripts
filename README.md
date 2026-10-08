# zsetup-scripts

FastNet、DDNSTO 的统一业务安装仓库。业务脚本负责包管理、服务和业务参数；可靠下载、系统探测、后台执行与安装选择复用 [zsetup](../../linkease-vpn/linkease-tunnel/zsetup/README.md)，最低版本 **0.2.4**。

设备已有 zsetup：

```sh
zsetup install fastnet
zsetup install ddnsto -- --token 'YOUR_TOKEN'
```

设备没有 zsetup，发布完成后的一条命令入口：

```sh
sh -c "$(curl -fsSL https://fw.koolcenter.com/binary/fastnet/install.sh)"
sh -c "$(curl -fsSL https://fw.koolcenter.com/binary/ddnsto/install.sh)" -- --token 'YOUR_TOKEN'
```

也可将 `curl -fsSL URL` 换成 `wget -qO- URL`。首先取得入口脚本依赖系统 curl/wget；脚本取得 zsetup 后，业务下载均使用 zsetup 内置 SHA256。HTTPS bootstrap 全部失败时才允许向交互用户询问 HTTP 风险，默认拒绝；zsetup 本身始终只接受 HTTPS。

**当前状态：安装脚本与配置候选，尚未公网发布。** FastNet/DDNSTO 产品包由各业务发布流程提前放到服务器，安装时由 zsetup 下载和校验。本仓库不采集、不缓存、不打包产品包；发布工具仅组装安装入口、权威 zsetup release 与完整配置。原线上入口继续保留；服务器产品文件及版本/SHA256 元数据要求见 [发布流程](docs/release.md)。

| 应用标识 | 支持平台 | 架构 | 业务参数与交互 |
|---|---|---|---|
| `fastnet` | Linux/OpenWrt；启动后由 FastNet 管理菜单 | x86_64、aarch64、armv7 | 参数逐项原样传给 FastNet；菜单交互由业务程序决定 |
| `ddnsto` | OpenWrt opkg/apk | x86_64、aarch64、armv7、mipsel | `--token TOKEN` 可选；`--force-version lite\|standard` 可选；低于 900 MB 自动选 Lite；`--verify-status` 检查服务 |
| `ddnsto` | Ubuntu/Debian apt、CentOS/RHEL yum/dnf、其他已识别 Linux | x86_64、aarch64 | 默认 Standard 4.2.3；`DDNSTO_VERSION` 可覆盖已发布版本；无终端必须传 `--token` |
| `fastpve` | 待确认 | 待确认 | 未实现、未加入索引；所需输入见 [新增业务](docs/extension.md) |

默认前台执行，并传播业务退出码。自动化不要把“后台启动成功”当成“安装完成”；后台用 `zsetup install ddnsto --background -- --token TOKEN`，读取命令输出中的日志/result 路径。后台 stdin 已关闭，必须提供 token。细节见 [AI 调用约定](docs/ai-contract.md)。

业务按根目录模块组织：[fastnet/](fastnet/README.md)、[ddnsto/](ddnsto/README.md) 各自拥有业务脚本、测试和说明；DDNSTO 的兼容入口发布规则也位于 ddnsto/。公共 lib/scripts/tests/docs 仅保留共享 bootstrap、统一构建、跨模块验证与协议文档。

```text
zsetup-scripts/
  fastnet/          # business.sh、main.sh、install.sh、README、tests/
  ddnsto/           # 同上，另有兼容 URL 发布规则 release.py
  lib/              # 共享 shell bootstrap
  scripts/          # 统一生成、打包与验收
  tests/            # 仓库布局与统一发布包测试
  docs/             # 发布、扩展、AI 协议与验证证据
  catalog.json      # 统一安装索引的构建输入
```

共享 bootstrap 构建时嵌入各模块的唯一 install.sh，业务逻辑不复制维护；运行中的入口不会下载自身。根目录旧脚本名继续链接到各模块 install.sh，原业务仓库保持不变。

正式服务器部署 `dist/release/binary/` 中的三个目录：`fastnet/`、`ddnsto/`、`zsetup/`，映射到站点 `/binary/`。仓库源码、测试和维护工具不上传网站。版本化脚本与包保持不可变，共享完整配置在 zsetup/config.json。目录映射、首个新服务器的业务产物要求及发布顺序见 [发布流程](docs/release.md)。

开发与验收：

```sh
python3 -B scripts/build-entrypoints.py
sh scripts/check.sh /path/to/linkease-tunnel/zsetup
python3 -B scripts/package-release.py --zsetup-root /path/to/linkease-tunnel/zsetup --require-clean
```

第三条在干净提交后生成安装脚本、zsetup 和配置候选，不访问产品服务器、不需要本地产品文件。dist/release 是本仓库的发布输出，dist/evidence 是验证日志；不再生成 ddnsto-artifacts。新增业务步骤见 [接入约定](docs/extension.md)，迁移归属和测试基线见 [盘点](docs/inventory.md)。
