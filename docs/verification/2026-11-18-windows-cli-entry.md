# Windows CLI 入口兼容性与真机验证

日期：2026-11-18。范围：配合测试构建控制台在 GUI 说明下增加折叠 CLI 入口。
开发验收阶段未发布测试站或正式站，未修改 zsetup 核心、执行策略、GUI 程序，未提交或推送。
后续用户授权测试发布后已更新 web.toany.net，公共命令真机成功；见 [测试发布记录](2026-11-18-ddnsto-release-windows-cli.md)。

## 复现与修复

设备：192.168.9.199，admin，Windows PowerShell 5.1，有效执行策略 Restricted。
公网 i.ps1 的无安装 `-Plan` 调用失败，脱敏后的最小探针定位到缓存替换异常。
新增 tests/windows_entry_compat_test.ps1 在真机执行源码中的实际缓存块、执行块及生成文件解析：
修复前缓存、解析、退出码 0 与 23 四项均失败，修复后全部通过。

1. File.Replace 的 `$null` 参数在 Windows PowerShell 5.1 被转换为空字符串，导致非法路径。
   改用 `[NullString]::Value`，保留原子替换，不删除缓存绕过问题。
2. 已通过大小、SHA256、私有路径校验的执行器改为 UTF-8 读取并用 ScriptBlock 调用，
   沿用公共命令的内存执行方式及命名参数 splatting；不更改执行策略。
   保留非零退出码，异常仍走脱敏失败路径，不 dot-source，不拼接 Token 为代码。
3. Windows 产品模板的 BOM 位于新增生成说明之后，导致 PowerShell 解析错误。
   将 BOM 移到文件开头，再生成 install.ps1；补充编译器编码回归断言。

## 真机验证边界

既有安装位于 C:\ProgramData\DDNSTO，版本 4.2.8，测试账号与此前授权一致。
初次紧凑表格输出未完整显示服务状态；后续 CIM 与 Format-List 明确确认原进程 15396、任务 Running。
没有将该设备当作空白机器覆盖安装。

候选文件通过 SSH 放在 C:\Users\admin\ddnsto-validation-20261118。
tests/windows_entry_candidate_harness.ps1 仅替换推荐清单/安装器的下载传输为本地候选文件，
真实执行 wrapper 的权限、大小、摘要、缓存和安装器逻辑；业务下载代码不替换。
这是候选真机验收，**不是公网短地址全链路已通过**。

- ensure：已稳定运行，4.2.8，exit 0。
- update：同版本路径通过，已稳定运行；不声称跨版本升级或全新安装通过。
- restart：启动成功，exit 0，最终 PID 10472，精确程序路径匹配的进程数为 1。
- 计划任务 DDNSTO 为 Running；执行策略仍 Restricted。
- ddnsto.yaml、.ddnsto_boot.cfg、.installer-windows-v1 与测试前 SHA256 比较均一致。
- 备份及任务 XML 留在设备上述验证目录，不含于源码或发布包。
- 没有验证云端在线、重启操作系统、GUI 切换、新安装、跨版本升级。

诊断日志位于 admin LocalAppData 的 DDNSTO-install-* 目录：
ensure 后缀 51f9b675cf8c4a3faa457364d799a480，update 后缀 a8a81852335c44e28f1f6945df6c2665，
restart 后缀 e4f0e1c1f84f4612ab4cdce88619167e。

## 回归

- Python ddnsto* 最终测试 189 项：150 通过、39 跳过；配置专项 10 项通过。
- build-entrypoints.py --check 与 diff --check 通过。
- 前端专项 30 通过、1 跳过；安装流程 Playwright 7 通过；production 构建通过。
- 设备组件扩大回归有一个未改文件的样式断言失败及一个并发超时，专项重跑无超时。

复跑兼容性测试：将 recommended-entry.ps1、install.ps1 放在同一验证目录；
在 Windows PowerShell 中以 ScriptBlock 读取 tests/windows_entry_compat_test.ps1，
传入该目录的 -SourceRoot。测试仅使用随机临时目录和无业务副作用的执行器 fixture。
候选 harness 支持 -Plan；真实 ensure/restart/update 需要设备操作授权和原账号 Token。

## 发布衔接

获授权后按发布 SOP 生成新不可变安装器及匹配清单，发布修复后的 i.ps1 包装器，
保留历史文件和回滚材料；用真实公共命令再次验收，再更新测试前端。
开发验收完成时公网入口未改动；随后已按单独授权完成测试发布及公共命令重复安装验证，未涉及正式环境。
