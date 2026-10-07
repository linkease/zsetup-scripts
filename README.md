# zsetup-scripts

FastNet、DDNSTO 的统一业务安装仓库。业务脚本负责包管理、服务和业务参数；可靠下载、系统探测、后台执行与安装选择复用 [zsetup](../../linkease-vpn/linkease-tunnel/zsetup/README.md)，最低版本 **0.2.3**。

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

**当前状态：本地迁移/测试版本，尚未公网发布。** FastNet 原线上入口继续保留。DDNSTO 新索引及脚本需同时发布确认的业务产物和 SHA256 元数据；旧公网目录缺少本契约要求的摘要，新脚本会安全失败，不能提前替换线上脚本。请先看 [发布流程](docs/release.md)。

| 应用标识 | 支持平台 | 架构 | 业务参数与交互 |
|---|---|---|---|
| `fastnet` | Linux/OpenWrt；启动后由 FastNet 管理菜单 | x86_64、aarch64、armv7 | 参数逐项原样传给 FastNet；菜单交互由业务程序决定 |
| `ddnsto` | OpenWrt opkg/apk | x86_64、aarch64、armv7、mipsel | `--token TOKEN` 可选；`--force-version lite\|standard` 可选；低于 900 MB 自动选 Lite；`--verify-status` 检查服务 |
| `ddnsto` | Ubuntu/Debian apt、CentOS/RHEL yum/dnf、其他已识别 Linux | x86_64、aarch64 | 默认 Standard 4.2.3；`DDNSTO_VERSION` 可覆盖已发布版本；无终端必须传 `--token` |
| `fastpve` | 待确认 | 待确认 | 未实现、未加入索引；所需输入见 [新增业务](docs/extension.md) |

默认前台执行，并传播业务退出码。自动化不要把“后台启动成功”当成“安装完成”；后台用 `zsetup install ddnsto --background -- --token TOKEN`，读取命令输出中的日志/result 路径。后台 stdin 已关闭，必须提供 token。细节见 [AI 调用约定](docs/ai-contract.md)。

源码仅有 `apps/`、`lib/`、`scripts/`、`tests/`、`docs/` 五类目录。共享 bootstrap 在构建时嵌入各业务独立的 `install.sh`；业务函数在 `apps/APP/business.sh` 维护，内部文件不发布。运行中的入口不会下载自身。根目录旧脚本名为同一入口的符号链接，兼容旧文件名；原仓库保持不变。

开发与验收：

```sh
python3 -B scripts/build-entrypoints.py
sh scripts/check.sh /path/to/linkease-tunnel/zsetup
python3 -B scripts/package-release.py --zsetup-root /path/to/linkease-tunnel/zsetup
```

第三条只生成开发暂存包；生产候选必须提供确认的 DDNSTO 产物。新增业务步骤见 [接入约定](docs/extension.md)，迁移归属和测试基线见 [盘点](docs/inventory.md)。
