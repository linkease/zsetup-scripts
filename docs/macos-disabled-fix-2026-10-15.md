# 0.1.10：macOS 禁用后重新安装修复

## 问题与行为

用户在真实 Mac 运行 0.1.9 时，下载和摘要校验成功，随后出现 `Bootstrap failed: 5: Input/output error`。用户只读诊断显示 `"com.ddnsto.client" => disabled`、plist 语法 OK、GUI domain 检查返回 0。

旧安装器直接 bootstrap，未处理独立于 plist 持久保存的禁用状态。0.1.10 在持有安装锁、确认文件归属后读取 `launchctl print-disabled`，仅匹配本服务的 `disabled` / `true` 状态；安装意味着重新启用并启动此用户服务。读取失败时停止，不替换客户端或停止原服务。enable 在替换和停止旧服务之前执行，失败则不影响原运行服务；随后安装失败会恢复旧文件、原加载状态及禁用状态。恢复失败保留工作目录并报告失败，不假报成功。

Token、设备身份、客户端版本 4.2.1、zsetup 0.3.0、下载源和摘要不变。不增加 root/sudo 使用方式。手工临时恢复仍可先运行 `launchctl enable gui/$(id -u)/com.ddnsto.client`，但修复版无需用户提前执行。

## 测试入口

固定目录：`https://web.toany.net/ddnsto-install/0.1.10/20261015-6c624972f4c9/`，文件为 `install.sh`、`install.ps1`、`SHA256SUMS`。

```text
62ceb9fe0f753af5a1a742f7255de284c1583db51a1f49240501841f08f7bc5c  install.sh
403288ba109ad9170289d9816fc2e7cb0f06714c1202c3bae806a4864cf3111a  install.ps1
```

本地构建：`python3 -B scripts/package-entrypoints.py --output dist/ddnsto-test-site-20261015-0110-r2`。初次本地候选未发布；最终 r2 包含 enable 失败不停止原加载服务的补充修复。只发布最终摘要对应字节，不把未提交工作区伪装成 Git tag。

沿用已确认的测试站及独立路径：`/home/ddnsto/installer-test/ddnsto-install/0.1.10/20261015-6c624972f4c9/`。先暂存、校验，再原子移动新目录；未修改 Nginx、宿主客户端或官网静态文件。0.1.9 保留原字节。本地官网 `src/install/release.js` 已切换新目录和 SHA256；回退仅恢复该文件中的旧地址与摘要，不删除不可变文件。未提交、推送或部署官网。

## 验证与限制

- 先补 launchctl 边界夹具，执行真实 Shell 安装流程，复现原错误，再修改实现；macOS 22 项行为测试通过，覆盖两种禁用输出、重装保留身份、冷安装、启用失败、启动失败回滚、已加载但禁用的服务及统一公开入口。
- POSIX 输入 5 项、Linux 服务 9 项、产品 pins 3 项、发布检查 4 项、桌面打包、独立入口打包、模块布局与生成一致性通过；canary 输入 4 项通过。
- 新入口 HTTPS 回读 SHA256 与上表一致，摘要文件为 text/plain、nosniff、immutable。Windows 脚本字节未变，PowerShell 行为夹具通过。
- 本地官网 16 项测试、11 项浏览器检查、定向 ESLint 和隔离副本生产构建通过；实际 macOS 页面命令指向新版本，未中断用户运行中的 Next dev。
- 新入口在测试服务器 Alpine/OpenRC 隔离容器中冷安装、重复安装与停止服务通过（退出 0），两次 routerId 一致；输出 `CLOUD_EGRESS_BLOCKED`、`COLD_INSTALL_OK` 和 `REPEAT_INSTALL_OK cloud_status=not_tested`。沿用合成 Token 和容器内出站限制，未在宿主安装客户端。Linux/OpenWrt 业务段与 0.1.9 相同。
- 首次服务器复测在依赖安装输出阶段未收到完整退出结果，随后只读确认容器已不存在，终止本地残留 SSH；不计作通过。第二轮使用 SSH keepalive、180 秒上限并保存远端测试日志后完整通过。另一次摘要文件回读发生连接超时；入口脚本成功回读的摘要及上述安装结果不意味着网络永不超时。
- macOS 测试为 Linux 上隔离系统边界的行为测试，不能替代原生 launchd 验收。真实 Mac 修复后复测、真实账号绑定仍需用户验证；完整 native/index 工具链未运行，本修复不改 native 下载器。

复测方式：刷新本地官网 `/install/?platform=macos`，确认命令含 `0.1.10/20261015-6c624972f4c9`，在当前 macOS 登录用户终端运行（不要加 sudo），观察重新启用提示和 `local_service=running`，最后到控制台确认在线。保留原 disabled 状态可直接验证本次修复，无需先手工 enable。
