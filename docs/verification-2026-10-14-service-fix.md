# 0.1.6：服务启动误报修复与验证

日期：2026-10-14 UTC。用户要求修复当前能解决的问题，并给出整体架构流程图。未提交、未推送、未发布正式客户端或正式 CDN。

## 修改范围

- 安装器 `ddnsto/business.sh` 与新增 `ddnsto/linux-service.sh`：Linux 服务环境前置检查、root/sudo 检查、独立停止旧服务及状态确认、启动后进程归属和 HTTP 健康确认。
- 不再把旧客户端退出0当作启动成功：健康失败返回13；没有可用 systemd/已初始化 OpenRC 返回2，不写客户端或服务。
- Linux 失败恢复保留旧程序与原服务 Token 配置；恢复不使用本次新 Token 覆盖旧配置；恢复失败保留私有备份并提示人工恢复。
- `clients/ddns-client/cmd/cli_ddnsto/cli_ddnsto.go`：有 serviceLogger 时 `fatal()` 仍必须非零退出；`installAndStart` 失败走 fatal；`status` 遇到错误或非运行状态非零退出。
- 维护源码嵌入独立 `install.sh`，不新增设备上的相邻脚本依赖。版本升级0.1.6，FastNet仍0.1.3；保留已部署0.1.5不可变副本。
- 架构及职责边界见 [一键安装流程图](one-command-architecture.md)。

## 测试先行证据

先新增测试并运行旧实现，看到失败后才修改实现：

| 检查 | 修复前 | 修复后 |
|---|---|---|
| Linux 业务交易8项 | 8项失败，包括旧程序未恢复、服务失败仍报成功、停止失败被忽略 | 8项通过 |
| Go 服务退出码7种场景 | fatal、install/start/stop错误、status错误/停止共6项失败；运行状态正例通过 | 全部通过 |

Linux 夹具执行真实维护源码和真实 tar 解包/文件备份恢复，仅替换下载与系统服务边界；场景包括缺少管理器、首次安装失败、更新失败恢复旧 Token、恢复失败保留备份、非默认本地端口健康确认、错误 PID、HTTP 不健康、停止失败。不把夹具通过称为完整真机回滚验收。

其他回归：

- macOS12项、POSIX Token5项、Linux服务8项通过。
- Windows行为与自动引导两组通过（Linux pwsh7.4.13，系统 API 是夹具，不是 Windows 原生验收）。
- 真实 zsetup0.3.0 + 隔离 HTTPS：Linux、OpenWrt opkg/apk × 四架构选择、冷引导、缓存和失败路径通过；包管理器是夹具，索引模式未验证。
- 发布核验4项、独立入口打包1项、桌面隔离1项、模块布局及生成入口一致性通过。
- Go 专项服务退出码测试通过，`CGO_ENABLED=0 go build` 成功。
- **`make test` 未全通过**：既有 `TestGoUpdateVersionParityCorpus` 读取 `../../../ddnsto-rust/crates/ddnsto-rust/tests/fixtures/go-update-version-parity.json`，当前工作区缺此文件。未伪造数据、未修改或删除该测试；显式排除此项后，`./cmd/cli_ddnsto ./easyexplorer` 其余测试通过。
- 完整 `scripts/check.sh ZSETUP_ROOT` 未运行：本轮没有可用的权威 native 源码/完整构建目录；执行了上述直接入口相关检查，不把它标为完整索引发布通过。

主要复现命令（安装脚本仓库根目录）：

```sh
python3 -B ddnsto/tests/linux_service_test.py
PWSH_BIN=/path/to/pwsh python3 -B ddnsto/tests/cross_platform_installer_test.py
python3 -B ddnsto/tests/ddnsto_test.py /path/to/zsetup-linux-x86_64 /tmp --direct-only
python3 -B tests/publication_test.py
python3 -B tests/entrypoint_package_test.py
python3 -B tests/desktop_package_test.py
python3 -B tests/module_layout_test.py
python3 -B scripts/build-entrypoints.py --check
```

客户端仓库：

```sh
go test ./cmd/cli_ddnsto -run '^TestServiceCommandExit$' -count=1 -timeout 30s
make test
# 只有确认上述已知缺失夹具后，另行验证其余测试；不能代替完整通过：
go test -count=1 -timeout 30s -skip '^TestGoUpdateVersionParityCorpus$' ./cmd/cli_ddnsto ./easyexplorer
```

## 测试站更新与真实程序复测

沿用已授权的 `test-toany / tx-nj-02` 测试目标，新建隔离发布目录，不覆盖0.1.5或正式站点文件：

- 基址：`https://web.toany.net/ddnsto-install-test/20261014-016/`。
- 服务端：`/home/ddnsto/shared/ddnsto-static/runtime/homepages/legacy/toany.net/ddnsto-install-test/20261014-016`。
- Shell SHA256：`86757d25416bebc20bbd0808740adac48068391a770995438edd6f570bc2c6f2`。
- PowerShell SHA256：`425a1b7a481e369d88a5ef2cecb4ac91be714c0310e43578420752c7cfce41bc`。
- 当前/0.1.6共四份入口正常 TLS 公网回读校验通过。native与业务包仍为已校验的官方 zsetup0.3.0 / Linux4.2.3，产品包由测试服务器留存及提供，不进入脚本仓库。

在 Docker internal 网络内验证，只有测试下载站可访问，使用合成非账号 Token，不连接生产或测试绑定服务，不在共享宿主安装客户端：

1. **无服务管理环境**：入口自动引导 zsetup 后明确返回2。没有生成 `/usr/local/bin/ddnsto`、服务脚本或业务下载缓存。0.1.5 的错误成功提示不再出现。
2. **真实 OpenRC 冷安装**：补齐容器系统环境，使用全新 `ZSETUP_ROOT`；一条命令自动下载 native、校验真实客户端 tar、安装并启动，输出 `local_service=healthy cloud_status=unverified`，返回0。
3. **重复安装**：复用下载缓存，停止并启动真实服务，健康确认通过，设备 ID 前后相同。OpenRC `status: started`、`/healthz` 返回 `ok`。
4. **新客户端错误传播**：从修复源码编译独立工程二进制，仅传到服务器私有临时目录；在另一个无 OpenRC 工具的隔离容器执行，出现明确的 `rc-update: executable file not found` 后返回1。不是把其他原因的失败算作此项通过。这个工程二进制**没有替换**公网 Linux4.2.3 安装包。

测试 Shell 下载源选择方式仍为：

```sh
ZSETUP_BOOTSTRAP_BASES=https://web.toany.net/ddnsto-install-test/20261014-016/binary sh -c 'entry=$(wget -q -T 15 -O - "$ZSETUP_BOOTSTRAP_BASES/ddnsto/install.sh") && test -n "$entry" && sh -c "$entry" install.sh --token-file /tmp/canary-token'
```

仅用于上述隔离 canary。下载源选择不会改变客户端默认连接后端；不得直接套用真实测试账号 Token 到普通联网机器后声称已验证测试绑定。

收尾：停止并删除本轮 `ddnsto-fix-20261014` 容器与同名网络；测试安装、合成 Token 和容器内服务配置随之移除，可按上述步骤重建。公网候选和服务器私有复核材料保留。原 `guacd` 继续 healthy，原首页 HTTP200，宿主未安装 DDNSTO。

## 尚未完成

- 客户端源码修复尚未发布成新的正式客户端版本；旧4.2.3包的退出码问题由新安装器独立检查规避，不能宣称旧包字节已修复。
- 系统开机自启、Linux systemd/ARM64、OpenWrt/macOS/Windows真机、真实云端绑定、跨版本更新以及全平台失败恢复仍待验收。
- OpenWrt/macOS/Windows没有在本轮同步宣称具备与 Linux 一致的 HTTP/PID 健康确认。
- 正式 CDN 产品元数据、入口部署以及完整索引安装仍待处理。候选存在不代表所有平台已上线。
