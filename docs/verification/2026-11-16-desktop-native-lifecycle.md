# macOS 与 Windows CLI 真机验收

日期：2026-11-16。延续[首次检查](2026-11-16-desktop-native-initial.md)。
用户提供本次账号 Token，授权短暂停止 DDNSTO，并明确要求增加 Windows CLI 测试。
本文不记录密码、Token 或配置内容。没有重启设备、退出用户桌面、降级客户端或改动 zsetup 核心。

## 结论与边界

| 目标 | 实际执行路径 | 已验证 | 未验证 |
| --- | --- | --- | --- |
| Mac 192.168.9.197，builder，macOS 26.6.2 ARM64 | SSH 传输本地修复候选，普通用户执行，使用真实下载和 launchd | 4.2.8 全新安装、重复 ensure、status、stop、start、配置及设备标识保持、单进程运行 | 新候选完整公网短地址链路、旧版跨版本升级、注销/重启后的启动、Intel Mac |
| Windows 192.168.9.199，admin，10.0.26200 x64 | 本地 canonical PowerShell 执行器，以内存 ScriptBlock 调用；管理员 SSH 会话 | 4.2.8 全新安装、重复 ensure、status、stop、start、配置及设备标识保持、SYSTEM 任务与单进程运行 | 默认策略下公网 i.ps1 成功、旧版跨版本升级、实际重启自启动、GUI 填写/保存 Token |

两台设备开始时都没有运行中的旧 DDNSTO，所以不能将本轮称为真实跨版本升级通过。
安装成功与本地启动成功已分别检查；不以云端在线或远程链接是否可访问作为安装验收结果。
Windows 默认产品入口仍是 GUI，本轮 CLI 为额外工程验收，不改控制台流程。

## Mac：按真机证据修复

1. **临时目录 sticky bit 丢失**：原 BSD `stat %Lp` 将 1777 读成 777。
   `portable-files.sh` 改用 `%Mp%Lp`，保留特殊权限位；未放宽目录安全判断。
2. **固定核心下载首站重定向**：真机请求 dl.istoreos.com 的 macOS 0.3.0 文件返回 302，
   其余固定镜像返回 200。Mac 改为优先 fw.koolcenter.com，保留原四站及摘要，仍拒绝重定向。
3. **launchd 状态解析**：真实输出除服务状态外包含嵌套 `state = active`。
   改读首个服务状态，避免将嵌套字段拼接成错误值。
4. **首次连接后的正常重拉起**：客户端日志实际记录服务端地址切换后正常退出，
   launchd 暂处于 `spawn scheduled`。增加最多 30 次一秒观察，必须连续三次 running
   且 PID 一致才成功；未运行或 PID 变化重置连续计数，超时仍失败。
5. **客户端身份文件权限**：已发布 4.2.8 会将 `.ddnsto_boot.cfg` chmod 为 0777。
   稳定运行后，仅对 owner-only 配置目录内、本用户所有、非符号链接且单硬链接的
   固定身份文件收紧为 0600，不改内容。没有修改客户端二进制。
6. **bootout 异步卸载**：真机 stop 曾因立即 print 仍可查询任务而误报失败，随后
   进程实际消失。增加最多十次一秒等待；超时仍失败。stop、uninstall 及 restart 使用该等待。

上述新增行为都先用失败测试复现，再修改实现。没有以关闭校验或扩大目录权限绕过问题。

### 真机结果

- 修复候选首次成功诊断：
  `/Users/builder/Library/Application Support/DDNSTO/.diagnostic.UTOrrw/events.log`。
- 最终重复 ensure：PID `43672 → 43672`，配置和身份文件 SHA256 对比不变。
- stop：任务卸载，当前用户 `pgrep -x ddnsto` 无进程。
- start：PID `44310`，服务状态 running，disabled override 为 enabled。
- stop/start 后配置和身份文件 SHA256 对比仍不变，身份权限 0600。
- 最终本机二进制 `-v` 返回 4.2.8。
- 最终重复操作诊断：`.diagnostic.cfOf7o/events.log`（同一配置目录）。

候选是 SSH 传入本地脚本运行，不等于已修复公网 `/i`。修复后的推荐 wrapper 曾通过
临时目录检查，并执行线上旧业务脚本，随后在旧下载镜像顺序处失败；最终业务候选则
单独传输验证。本轮没有发布新推荐清单、不可变目录或修改短地址。

最终源码摘要：

```text
install-macos.sh  f9ffa6f992a8ee6bdff1fdca19b68b7f6781ef18c6d1d58e02301ccaa0a47d9a
ddnsto-install.sh 343758d5785cde6f0f3b02a498f65d201a56b37e98ff4ee597a1ba11a2072105
```

两次失败安装留下的测试目录已移动保留，未删除：

- `~/Library/Application Support/DDNSTO-validation-failed-20261116`
- `~/Library/Application Support/DDNSTO-validation-failed-20261116-r2`

它们包含本轮产生的身份及日志，不应上传公开仓库。最终有效目录仍为
`~/Library/Application Support/DDNSTO`，有效客户端为 `~/.local/bin/ddnsto`。

## Windows CLI：执行器通过，公网入口有策略限制

- 首先停止上一轮在专用测试目录启动的 GUI 进程，仅按精确可执行路径匹配，未覆盖 GUI 配置。
- 公网 `https://web.toany.net/i.ps1` 返回通用 code=1。随后独立调用已传输的脚本文件，
  系统明确报告 PSSecurityException：禁止运行脚本。有效执行策略为 Restricted。
- 推荐 wrapper 下载后通过 `& $scriptPath` 执行文件，受该策略限制。
- 通过 `[scriptblock]::Create([IO.File]::ReadAllText(...))` 调用同一 canonical 执行器，
  下载并校验固定 zsetup 0.4.0、CLI 4.2.8，注册 SYSTEM 计划任务并通过实际进程稳定性检查。
  没有使用 Set-ExecutionPolicy 或 ExecutionPolicy Bypass，没有修改系统策略。
- 后续验收脚本 dot-source 相同内容后调用真实 `Invoke-DDNSTOEntry`，避免入口末尾的
  `exit` 提前终止整份多步骤测试；未替换任务、进程或文件系统 API。
- 执行器 SHA256：`4f044f50a96f215ac2c8fa1b2a106ff1e325bdbc93a48ced4a780a521e773911`。

### 真机结果

- 安装目录：`C:\ProgramData\DDNSTO`。
- 安装成功诊断：
  `C:\Users\admin\AppData\Local\DDNSTO-install-3ad6399b8cd04184ade0256741b73142\events.jsonl`。
- 重复 ensure：PID `8112 → 8112`，配置及身份文件 SHA256 对比不变。
- stop：目标可执行路径的实际进程数量变为 0。
- start：目标进程数量恢复为 1；最终 PID `15396`，SessionId 0。
- 任务 `\DDNSTO` 为 Running，主体 SYSTEM，触发器 MSFT_TaskBootTrigger。
  这只验证启动配置，不等于机器重启验收。
- 配置和身份文件 stop/start 后保持不变，本机二进制 `-v` 返回 4.2.8。
- GUI 保持停止，CLI 保持运行；GUI 下载和配置目录保留。

## 回归与交付

- `python3 -B ddnsto/tests/macos_behavior_test.py`：61 项通过。
- `python3 -B ddnsto/tests/macos_default_test.py`：18 项通过。
- `python3 -B tests/ddnsto_portable_files_test.py`：7 项通过。
- `DDNSTO_TEST_NATIVE=/tmp/ddnsto-zsetup-audit.b6JOZ8/zsetup python3 -B -m unittest discover -s tests -p 'ddnsto*test.py'`：173 项，138 通过、35 跳过、0 失败（28.819 秒）；不是全仓库所有历史测试。
- 新增六个回归用例，先失败后通过；既有 PID 抖动、非运行状态、归属不明、
  符号链接和回滚拒绝场景仍通过。
- 生成入口一致性与 `git diff --check` 通过。
- 未发布测试站、未改正式环境、未提交或推送代码。
