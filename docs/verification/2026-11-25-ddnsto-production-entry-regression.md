# DDNSTO 正式入口真机回归

日期：2026-11-25。基线：zsetup-scripts `9c012ef`，安装器 0.3.2。
结论：公开文件 27/27 与仓库一致；四个平台连续两次安装、启动通过；华硕触发防降级保护，不能计为安装成功。

## 正式分发核验

使用正常证书校验的 HTTPS 下载，重定向仅允许 HTTPS，逐文件比较 SHA-256：

- `https://run.ddnsto.com/install.sh`、`install.ps1`、`install.md`，共 3 项。
- `dl.istoreos.com`、`fw.d4ctech.com`、`fw20.koolcenter.com`、`fw.koolcenter.com` 四个镜像的 `/binary/zsetup-scripts/apps/` 下各 6 项：`zsetup/config.json`、`zsetup/config-windows.json`、`zsetup/ddnsto-index.json`、`zsetup/ddnsto-index-windows.json`、`ddnsto/versions/0.3.2/install.sh`、`ddnsto/versions/0.3.2/install.ps1`。

全部下载成功且与基线一致。该检查仅覆盖列出的文件，不是整个 apps 树的发布审计。
完整核验明细见同名 JSON。

## 真机方法

从控制台 `installer-candidate.ts` 以 production 模式生成实际命令，使用正式 `run.ddnsto.com` 入口。
每台设备执行默认安装动作两次，保留原配置中的 Token，不换绑，不强制降级。
未覆盖下载源、配置或 zsetup 根目录；没有回环 HTTPS、测试 CA 或 SSH 下载转发。
保留设备正常缓存，因此不宣称每个底层下载均重新发生。

所有设备已有安装，本轮验证重复安装及启动，不代表空白新装或旧版跨版本升级通过。
只验本地运行，不判断云端在线。未发布或修改任何测试/正式服务器文件。

| 设备 | 客户端版本 | 两次安装退出码 | 最终状态 | 结论 |
| --- | --- | --- | --- | --- |
| OpenWrt 192.168.30.244 | 4.2.8；opkg 4.2.8~8664-r1 | 0 / 0 | ddnstod PID 21128；UCI 配置摘要不变 | 通过 |
| 群晖 192.168.9.121 | 4.2.8-7 | 0 / 0 | synopkg running；配置摘要不变 | 通过 |
| macOS 192.168.9.197 | 4.2.8 | 0 / 0 | launchd running；YAML 和设备身份文件摘要不变 | 通过 |
| Windows 192.168.9.199 | CLI 4.2.8 | 0 / 0 | DDNSTO 任务 Running，进程 PID 10472；配置摘要不变 | 通过 |
| 华硕 192.168.3.247:2222 | 4.2.9，高于推荐 4.2.8 | 2 / 2，E_VERSION | 原版本及 PID 23300/23298 保留；完整 ddnsto dbus 导出摘要不变 | 防降级保护通过，安装成功验收未通过 |

群晖以 sudo 管理员执行，未验证交互式提权提示。macOS 使用 builder 登录用户。
Windows 通过 ScriptBlock 内存执行，执行策略始终为 Restricted；PowerShell CLIXML 进度输出不影响退出码和服务检查。

## 诊断证据

- OpenWrt：`/tmp/ddnsto-result.BJkmEe/events.log`、`/tmp/ddnsto-result.LJnePG/events.log`。
- 群晖：`/tmp/ddnsto-result.Aco0n4/events.log`、`/tmp/ddnsto-result.LEbIAv/events.log`。
- 上述四份日志均核对为 `checking → installed → starting → started`，`exit_code=0`。
- macOS：`~/Library/Application Support/DDNSTO/.diagnostic.X5wRbh/events.log`、`.diagnostic.F3Jt6X/events.log`。
- Windows：`%LOCALAPPDATA%/DDNSTO-install-acb8d1c90cb6493b9f8b7b5c646a349f/events.jsonl`、`DDNSTO-install-12819d8b66da4a93af9f2059dcea66b5/events.jsonl`。
- 华硕：`/jffs/.ddnsto-installer/tmp.7b32f9f59fa872bd54ba11dc/events.log`、`tmp.fdc015c8fc4fd4b0f3488211/events.log`。

本机临时原始记录：`/tmp/ddnsto-production-regression-20261125.qLwQWd/`。
测试包装脚本和设备日志保留用于排查；无新增长期监听或证书信任变更。

## 剩余边界

华硕须另行审核推荐版本、渠道包及摘要后补齐成功安装验收，本次未修改版本策略或降级设备。
Windows GUI、Intel Mac、QNAP、通用 Linux 和其他未提供设备不在本轮真机验收范围。
本轮只新增验证文档，没有修改安装器实现，也没有自动提交或推送。

## 补充：本机 Linux 尝试

用户随后授权使用本机验证。当前 agent 所在环境为 Ubuntu 24.04.1 x86_64 容器，
地址 192.168.98.2，PID 1 为 s6-svscan，无 `/run/systemd/system`，systemctl 无法连接服务管理器。
已有开发客户端由 tmux 启动，PID 1596957，路径为工作区 `clients/ddns-client/bin/ddnsto`。

使用相同正式入口及用户此前提供的测试 Token：

- 普通用户 abc 执行：退出 12，`E_EXECUTOR`；日志 `/tmp/ddnsto-result.dS4Adc/events.log`
  仅有 `stage=checking` 和 `exit_code=12`，具体前置失败原因尚未确定，不能直接归因为缺少 systemd。
- sudo 管理员执行：退出 2，`E_SERVICE_MANAGER`，明确提示当前系统没有可用的 systemd；
  日志 `/tmp/ddnsto-result.7FsF39/events.log`。
- 两次执行后原开发客户端 PID 均保持 1596957，未主动停止或替换该进程。

此项只能证明非 systemd 环境的管理员拒绝路径，不能计为通用 Linux 安装、重复安装或启动通过。
普通用户错误诊断不充分，需另行排查。完整 Linux 正向验收仍需 systemd 宿主机的访问入口；
未借助 Docker socket 操作宿主机、创建特权容器或改造当前 init 环境。
