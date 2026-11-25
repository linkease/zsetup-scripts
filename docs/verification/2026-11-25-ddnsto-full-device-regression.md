# DDNSTO 0.3.2 全部既有测试设备回归

时间：2026-11-25，约 02:42–02:45 UTC。
状态：候选真机验证完成，4 台通过，1 台触发防降级保护；不代表正式发布。

## 范围和方法

用户要求在此前全部测试设备重跑完整 DDNSTO 安装。覆盖 OpenWrt、群晖、华硕、macOS、Windows CLI。
每台均从标准入口调用默认安装动作两次，不是只运行 `--plan`、`--help` 或状态查询。
读取设备原配置中的 Token，不修改账号、不删除配置、不强制降级、不更改系统执行策略。
全部设备已有安装，因此本轮验证重复安装/恢复启动，不宣称空白新装或跨版本升级通过。
Windows GUI、Intel Mac、QNAP、通用 Linux 和其他未提供的设备不在本轮真机结果内。

基线为 zsetup-scripts `9b42f3c` 加本地 macOS 发布目录修复；应用版本 0.3.2。
源目录 `/tmp/ddnsto-full-regression-20261125.DhHFYL` 保存固定测试快照和测试包装脚本。
公开标准入口通过同一生成器产生，仅将配置/不可变脚本下载位置改为回环 HTTPS 测试源；
客户端包和 zsetup 仍使用正式 HTTPS 来源。不可变载荷原字节、大小、摘要保持不变：

```text
a1e9c1f31503997bcea86042186f027e07ff2b8263c0715be495eb784852dbcd  versions/0.3.2/install.sh
583feb5dbeb542b43b7e211ebac7fada8397308eb4e2865d3eace065da390d2a  versions/0.3.2/install.ps1
```

OpenWrt、华硕、macOS、Windows 通过 SSH 回环转发访问测试源。群晖不支持该转发，使用其本机
127.0.0.1 上的临时 HTTPS 服务。CA 只传入当前测试进程，不写系统信任库。这是候选完整链路
回归，不是 `run.ddnsto.com` 已发布入口验收，没有更新测试或正式业务服务器。

## 结果

| 设备 | 已装版本 | 第一次 / 第二次退出码 | 本地状态与配置 | 结论 |
| --- | --- | --- | --- | --- |
| OpenWrt 192.168.30.244 | 4.2.8，opkg 4.2.8~8664-r1 | 0 / 0 | ddnstod PID 22555，二进制报告 4.2.8；UCI 配置摘要不变 | 通过 |
| 群晖 192.168.9.121 | 4.2.8-7 | 0 / 0 | 管理员执行；synopkg=running，配置摘要不变 | 通过 |
| macOS 192.168.9.197 | 4.2.8 | 0 / 0 | launchd=running；YAML 配置及 .ddnsto_boot.cfg 摘要不变 | 通过，macOS 新目录链路已恢复 |
| Windows 192.168.9.199 | CLI 4.2.8 | 0 / 0 | DDNSTO 计划任务 Running，ddnsto_cli.x86_64 PID 10472，YAML 配置摘要不变 | CLI 通过 |
| 华硕 192.168.3.247:2222 | 4.2.9，高于当前推荐 4.2.8 | 2 / 2，E_VERSION | 版本仍为 4.2.9，原 PID 23300/23298 保持；未执行降级 | 防降级保护通过，安装成功验收未通过 |

群晖非管理员初查报告 stop；管理员安装后确认 running。初查权限不同，不能据此断言测试前
服务实际停止。Mac 以 builder 登录用户执行；群晖通过 sudo 执行，未验证交互式 sudo 提示。
华硕测试包装器的 `config_unchanged=yes` 仅比较了版本号，不应解释为完整 dbus 配置摘要一致。

Windows 最初通过 `-File` 执行测试包装脚本被 Restricted 策略拦截；这不是标准安装入口失败。
改用与控制台一致的 ScriptBlock 内存执行后，两次原生子进程退出码均为 0。最终执行策略
仍是 Restricted。原生 PowerShell 包装仍输出 CLIXML 进度噪声，但不影响本次安装结果。

## 设备诊断证据

- OpenWrt：`/tmp/ddnsto-result.EdNdjH/events.log`、`/tmp/ddnsto-result.GLpPCF/events.log`。
- 群晖：`/tmp/ddnsto-result.AtiJxM/events.log`、`/tmp/ddnsto-result.C1tmG3/events.log`。
- 以上四份日志均确认 `checking → installed → starting → started`，`exit_code=0`。
- macOS：`~/Library/Application Support/DDNSTO/.diagnostic.cNhii6/events.log`、`.diagnostic.phjxoM/events.log`。
- Windows：`%LOCALAPPDATA%/DDNSTO-install-24e9101170de43d69106f8d77bae73d8/events.jsonl`、`DDNSTO-install-36530b18af044d84abd66b5add495590/events.jsonl`。
- 华硕：`/jffs/.ddnsto-installer/tmp.606a44caa18f47ca433e501e/events.log`、`tmp.cab2ba9e91d536642f196070/events.log`。

## 收尾与剩余条件

已关闭本地及群晖临时 HTTPS 服务，安装 SSH 转发均随执行结束关闭。测试文件和诊断日志
保留用于排查；无永久监听、证书库或执行策略变更。本记录随修复提交，未推送、未发布脚本。

华硕需要先明确客户端推荐版本策略，并审核对应渠道的包及摘要，才能在不降级现有 4.2.9 的
前提下补齐成功安装验收；本轮未擅自改推荐版本或降级设备。上述成功均只表示本地安装/启动，
不以设备在线状态作为判定，也不代表正式域名分发已经通过验收。
