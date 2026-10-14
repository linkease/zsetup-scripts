# 一条命令自动安装：2026-10-14 工程验证

后续更新：本记录中的 Linux 服务启动误报已在0.1.6增加独立验证并修复客户端错误传播，见[修复与真实复测](verification-2026-10-14-service-fix.md)。以下保留0.1.5历史证据，不覆盖已发布候选。

用户明确要求：在目标设备运行一条命令，不手动下载 zsetup 或脚本仓库。本轮以已发布 zsetup 0.3.0 为依赖，不修改 native 内核。DDNSTO 入口候选升级至 0.1.5，FastNet 保持 0.1.3。未提交、未推送；已按用户要求部署测试站独立目录，未部署正式 CDN，测试范围见文末。

## 本轮实现

- `install.sh` 生成时嵌入 macOS 业务脚本，运行时按系统分流；设备不需要相邻源文件。
- Windows/macOS 没有指定调试用 ZSETUP_BIN 时自动下载 zsetup；官方 0.3.0 SHA256 固定在代码中，先校验再执行。只用 HTTPS，沿用三个 primary 与最终 fallback；Windows 禁止重定向，macOS 禁止非 HTTPS 重定向。失败停止业务安装。
- Linux/OpenWrt 保持已有自动引导链路；增加无预装 native 的回归。桌面及 POSIX 首次终端输入 Token 不回显；OpenWrt 更新前先读取已有 UCI Token，桌面继续保留 YAML/身份文件。Linux 重装仍需提供 Token；OpenWrt 无终端、无 Token 的历史包安装行为保留，不承诺这种模式完成绑定。
- `package-entrypoints.py` 不依赖 native 源码，独立生成两种入口的版本化文件和别名候选、摘要及 manifest；拒绝覆盖输出目录，不激活任何线上入口或索引。
- `check-publication.py --mode direct` 检查两种入口、版本化副本和产品元数据，不要求索引；默认 indexed 模式保留。

## 测试结果

遵循测试先行：先观察无预装桌面引导、统一 Shell 分流、首次 Token 提示、独立入口打包及直接发布模式的失败，再补实现。

| 检查 | 结果与边界 |
|---|---|
| macOS shell 行为 12 项 | 通过；含两种架构选择、校验拒绝、统一入口、PTY Token 不回显、配置保留和恢复；下载/launchd/原生哈希使用隔离替身 |
| POSIX 参数与 Token 5 项 | 通过；文件输入、拒绝多行、UCI 复用、非交互 Linux 拒绝缺失值、PTY 隐藏输入 |
| Windows 两组行为脚本 | 通过；安装/恢复/锁/首次提示及引导校验；Linux PowerShell 7.4.13 执行，原生系统 API 为替身 |
| Linux/OpenWrt 直接入口矩阵 | 真实 zsetup 0.3.0、本地 HTTPS、假包管理器；四架构选择、冷启动、校验/缓存/失败恢复通过；不是真实四架构设备验收 |
| 发布核验 4 项 | 通过；直接模式不依赖索引，但仍拒绝缺失产品摘要 |
| 独立入口打包 1 项 | 通过；无需 native 源码、两种入口字节/摘要一致、拒绝覆盖 |
| 桌面候选隔离 1 项、模块布局、生成文件一致性 | 通过 |
| 产品文档仓库校验 / Meta Doctor | 通过；有既有 source checkout 未绑定警告，不证明原生验收 |

复现（仓库根目录）：

```sh
PWSH_BIN=/path/to/pwsh python3 -B ddnsto/tests/cross_platform_installer_test.py
python3 -B ddnsto/tests/ddnsto_test.py /path/to/zsetup-linux-x86_64 /path/to/tunnel --direct-only
python3 -B tests/publication_test.py
python3 -B tests/entrypoint_package_test.py
python3 -B tests/desktop_package_test.py
python3 -B tests/module_layout_test.py
python3 -B scripts/build-entrypoints.py --check
python3 -B scripts/package-entrypoints.py --output dist/ddnsto-entrypoints-0.1.5
```

本轮实际生成了 `dist/ddnsto-entrypoints-0.1.5/`，属于忽略的本地构建产物，readiness 明确为 `candidate-not-published`。正式用户命令见 [DDNSTO 使用说明](../ddnsto/README.md)，其中 URL 尚不能作为已发布承诺。

## 仍需完成

- 公网只读检查（direct 模式）仍不满足条件：入口及新版本副本未部署，Linux/OpenWrt 产品摘要仍缺失。不能绕过摘要继续安装。
- Windows x64/PowerShell 5.1、macOS Intel/Apple Silicon、Linux/OpenWrt 的实际安装、启动、重启、更新、身份连续性及控制台在线需要真机验收。
- [前轮记录](verification-2026-10-13.md)的索引安装失败尚未解决，完整 native/索引打包也未验证；这是另一条可选管理路径，不再阻塞直接运行入口的代码生成。
- 新入口未改客户端版本选择协议，桌面仍固定4.2.1，Linux默认4.2.3；不宣称同版本重装等于任意版本自动更新。OpenWrt 完整包级回滚仍待实现。

以上是部署前的工程验证结论。后续测试站部署记录如下；正式发布仍需剩余平台和绑定链路验收，而不是要求最终用户准备开发工具或下载依赖。

## 测试服务器部署与真实 Linux 验证（2026-10-14 UTC）

用户授权：先在测试服务器上线，然后测试。按工作区 `.it-runner/meta/servers/test-toany.env` 和既有测试部署约定，目标为 `test-toany / tx-nj-02`，不是正式下载站。

- 公网基址：`https://web.toany.net/ddnsto-install-test/20261014-015/`。
- Shell：基址下 `binary/ddnsto/install.sh`；PowerShell：`binary/ddnsto/install.ps1`。两者均包含同字节 `0.1.5/` 副本，但本轮仅验收 Linux x86_64 安装路径。
- 服务端目录：`/home/ddnsto/shared/ddnsto-static/runtime/homepages/legacy/toany.net/ddnsto-install-test/20261014-015`。
- 先上传私有 staging、校验四份脚本，再以新目录 rename 激活；没有覆盖官网、控制台、正式 CDN、旧安装入口或 nginx 配置，没有 reload。
- 业务服务器自行从官方 HTTPS 下载真实 Linux Standard 4.2.3 tar，生成该测试命名空间的 SHA256SUMS；产品包没有进入脚本仓库或本地发布包。测试目录仅补齐 Linux x86_64 所需 native 和产品，不代表全平台元数据已发布。
- 构建 manifest 保留原始 `candidate-not-published` 字段，记录的是本地打包状态，不把它当作部署验收结论；本节记录实际部署范围。

### 公网回读摘要

四个入口（Shell/PowerShell × 当前/0.1.5）均通过正常 TLS 验证回读，并与本地候选 SHA256 一致。

| 文件 | SHA256 |
|---|---|
| `binary/ddnsto/install.sh` | `13bd479d2c474d49937cfed433efcce2e374ea1e828f210de931f6d145bd3385` |
| `binary/zsetup/0.3.0/zsetup-linux-x86_64` | `67abbda6c92e314c269db8d145b5e87094cf684a2efd5e450c319769f8520489` |
| `binary/ddnsto/linux-binary/ddnsto-standard-4.2.3.tar.gz` | `b982ebd38e8c145d955049eb5b73960c01941bc05f084c3a2115dfca2b6eea6e` |
| 安装后的 `/usr/local/bin/ddnsto` | `5f152c691e0acd75055bd65ecfa51a1ac5b4bc8d79908860e6192116f33c9a0e` |

### 测试隔离及执行方式

使用已有镜像 `linkease/guacd:1.6.0-socks5` 中的 Alpine 3.18.12 用户空间，显式替换 entrypoint；不运行 guacd，不借用现有容器。新建独立 Docker internal 网络，仅映射测试下载域名至宿主 bridge 网关，正常验证 HTTPS。没有 privileged、host network 或宿主服务目录挂载。

使用不属于账号的合成 Token，文件权限 0600；不使用、不发布真实用户 Token。生产连接无法出网，因此这里只验证安装与本地生命周期，不验证设备绑定。特别注意：**测试下载地址不会自动改变客户端的服务端地址**，该官方包仍默认 `tunnel.kooldns.cn:4445`。不能拿测试账号 Token 在普通联网环境直接执行后声称验证了测试后端。

全新容器事先只有系统服务环境（官方 Alpine OpenRC 及运行时目录），确认没有 `/tmp/zsetup` 和 `/usr/local/bin/ddnsto`。自动化执行的单命令如下；Token 文件仅用于无人值守测试，正常用户入口支持终端提示：

```sh
ZSETUP_BOOTSTRAP_BASES=https://web.toany.net/ddnsto-install-test/20261014-015/binary sh -c 'entry=$(wget -q -T 15 -O - "$ZSETUP_BOOTSTRAP_BASES/ddnsto/install.sh") && test -n "$entry" && sh -c "$entry" install.sh --token-file /tmp/canary-token'
```

### 结果与发布阻断项

| 检查 | 实际结果 |
|---|---|
| 无预装 zsetup 的冷安装 | 自动获取真实 zsetup 0.3.0、校验真实 tar、安装客户端4.2.3；退出0 |
| 本地服务启动 | OpenRC `status: started`，真实 ddnsto 进程存在，`GET http://127.0.0.1:18333/healthz` 返回 `ok` |
| 重复安装 | 重用已验证缓存，停止旧服务后安装并启动成功；健康接口正常，设备 ID 保持一致 |
| 服务重启 | OpenRC stop/start 后健康接口恢复，设备 ID 保持一致；不是宿主重启/开机自启验收 |
| 非交互未提供 Token | 明确拒绝，退出2 |
| 真实下载错误 SHA256 | 直接调用真实 zsetup 下载线上 tar，指定错误摘要；退出11，不产生目标文件，已有客户端摘要不变。此项验证下载器拒绝，不等同于整个安装器回滚验收 |
| 云端绑定 | 未执行；状态接口 `connected:false`，符合隔离设计，不可算在线验收 |
| 站点影响 | 原首页继续 HTTP200；宿主无新 `/usr/local/bin/ddnsto`；原 guacd 服务保持运行 |

发现的真实问题：在未提供服务管理器的精简容器中，客户端打印 `rc-update: executable file not found`，但进程返回0，安装器仍输出 `DDNSTO installed; local_service=start-requested cloud_status=unverified`。补 OpenRC 但未初始化运行目录时，同样观察到服务启动报错而返回0。补齐系统环境后实际启动通过，但**不能据此消除误报问题**。

当前安装器只检查启动命令退出码，没有验证服务状态或本地健康接口；当前客户端源码 `cli_ddnsto.go` 的 `installAndStart` 分支也存在仅记录启动错误、未返回失败退出码的路径。下一步应补服务前置检查与启动后健康确认，失败明确返回非零并进入恢复；客户端错误传播需要单独修改和构建验证。本轮仅部署、测试与记录，没有改动客户端源码或发布新二进制。

本轮不构成全平台上线验收：Windows/macOS/OpenWrt 原生安装、Linux systemd/ARM64、机器重启自启、跨版本更新、启动失败恢复和测试控制台真实绑定仍待验证。正式 CDN 的入口及 Linux/OpenWrt 摘要缺失状态不因测试目录上线而改变。

### 收尾与回退边界

已停止并删除本轮两个临时容器 `ddnsto-canary-20261014`、`ddnsto-canary-clean-20261014` 及独立网络；容器中的合成 Token、服务配置与测试安装随之移除，可按记录重建。原 `guacd` 仍 healthy，原首页 HTTP200。测试下载目录保留，服务器私有 staging `/tmp/ddnsto-canary.0oBXMB1U` 保留下载物便于复核，没有真实 Token。

如需撤回测试入口，只需将上述精确的 `20261014-015` 发布目录移到非 Web 根目录留档；不需要修改 nginx，不删除其他版本、官网或控制台。由于原站 `try_files` 存在首页兜底，判断撤回/缺文件不能只看 HTTP200，必须核对响应内容或摘要。
