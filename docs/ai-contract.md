# 用户与 AI 调用协议

复用现有 zsetup 命令，未新增服务或网络 RPC。先用 `zsetup context --json` 获取系统事实，`zsetup install --list` 获取配置中的应用标识；列表表示索引声明，不保证当前设备匹配。Product Configuration 中平台匹配由 zsetup 执行，业务脚本再次校验支持范围。

| 标识 | 参数 | 返回与交互 |
|---|---|---|
| fastnet | `zsetup install fastnet --foreground -- ARGS...` | 原样传 ARGS，安装器最终 exec FastNet，退出码继承业务程序；它可能打开菜单，自动化须使用业务已支持的非交互参数，本文不虚构 FastNet 参数 |
| ddnsto | `zsetup install ddnsto --foreground -- --token TOKEN [--force-version lite\|standard] [--verify-status]` | OpenWrt token 可选；Linux 无终端 token 必需。Linux 不支持 lite/verify-status。前台退出码为业务结果 |
| ddnsto/macOS | `sh ddnsto/install-macos.sh --token TOKEN [--version 4.2.1]` | 仅支持 x86_64/arm64；使用用户级 launchd；当前固定客户端归档为 4.2.1，入口会校验归档 SHA256 |
| ddnsto/Windows | `powershell -ExecutionPolicy Bypass -File ddnsto/install.ps1 -Token TOKEN [-Version 4.2.1]` | Windows 10 x64 WOW64 / PowerShell 5.1 验证范围；使用 x86_64 CLI 和 SYSTEM 计划任务；入口会校验归档及二进制 SHA256 |
| linkease | `zsetup install linkease --foreground -- [--version VERSION]` | 无 token/菜单交互；Linux 默认 1.7.5、OpenWrt 默认服务器 VERSION；默认前台，可后台读取最终 result；root/已配置 sudo 与 tar/unzip 或 opkg 要求见模块 README |
| fastpve | `zsetup install fastpve --foreground -- ARGS...` | Debian/apt/x86_64 PVE、root/pveversion 必需；exec FastPVE，默认交互菜单；参数/退出码原样继承，不虚构非交互参数 |

业务入口约定：0 成功；2 参数/平台不支持或缺少必需交互输入；11 业务 metadata 不完整/非法；包管理器、启动程序、zsetup download 的其他错误码原样传播；信号退出 129/130/143。zsetup 自身配置/索引/版本收敛失败通常返回 17；download 的错误类别由其既有命令协议定义，不把一切非零都解释成“业务安装失败”。不要解析人类进度文案作为成功协议。

后台：`zsetup install ddnsto --background -- --token TOKEN` 返回 0 仅表示成功启动，stdout 给出 pid/log/result。等待 result 出现并读取其最终退出码。后台 stdin 关闭，不能回答 token 或 HTTP bootstrap 确认。FastNet 菜单默认使用前台；DDNSTO 默认前台便于直接拿到真实错误。

一键脚本中的 bootstrap 只处理 zsetup 的 HTTPS stable/exact version；直接进入当前脚本的业务函数。安装模式由 zsetup 设置 `ZSETUP_INSTALLER_MODE=1`，提供 ZSETUP_BIN、OS/PACKAGE_MANAGER/ARCH/MEMORY_TOTAL_MB、SOURCE_BASES/SOURCE_FALLBACK、CONFIG_VERSION。AI 正常使用 install，不能伪造这些变量来绕过平台或摘要校验。

zsetup 默认完整本地配置 `/etc/zsetup/config.json` 优先于云端；无本地配置时读云端，故障才使用已验证 last-known-good。配置不按字段合并。SOURCE_GROUP 三个 primary 与 final fallback 顺序保持既有规则。脚本通过 HTTPS 的 VERSION/SHA256SUMS 获取业务发布信息；下载的新包必须由 zsetup 校验 digest。业务缓存复用只信任私有工作目录中已成功校验后写入、与 metadata digest 和文件大小一致的标记；不把该目录用于外部可写内容。

工程测试变量包括 ZSETUP_ROOT/WORK_DIR/BOOTSTRAP_BASES/CA_FILE、DDNSTO_BIN_PATH/SERVICE_PATH/MEM_MB；这些不是面向普通用户的安装参数。token 不写入安装器日志；真实命令行参数和 uci/业务程序如何保存凭据仍遵循业务自身契约。

0.1.6 脚本要求 zsetup >=0.2.4。`context --json` 增加 `memory_total_mb`（整数 MiB，未知为 null）；字段模式为整数或 unknown。`metadata version FILE [KEY]` 与 `metadata sha256 FILE NAME` 仅读取受限本地数据；0 成功、2 参数错误、11 内容错误、12 文件错误，成功 stdout 只有一行值。DDNSTO 的 900 MiB 阈值仍由业务决定；测试可用既有 DDNSTO_MEM_MB，普通用户无需传内存参数。

维护与直接调用入口统一命名为 APP/APP-install.sh：fastnet/fastnet-install.sh、ddnsto/ddnsto-install.sh、linkease/linkease-install.sh、fastpve/fastpve-install.sh。公开 URL 使用 /binary/APP/APP-install.sh；原 /binary/APP/install.sh 为同字节兼容副本。zsetup install 的应用标识和参数协议不变。

LinkEase 只支持 opkg 的 OpenWrt 及已声明 Linux 的 x86_64/aarch64/armv7，不声明 APK/MIPS。--version 原样通过现有 install 参数协议传入；LINKEASE_VERSION 作为默认，命令行优先。Linux 安装/启动失败会恢复旧文件/服务，恢复失败保留备份并报告；opkg 部分安装结果须由包管理器恢复，不解释成完整事务回滚。详见 [LinkEase 协议](../linkease/README.md)。

FastPVE 使用原 version.txt 的 VERSION/FASTPVE_SHA256 与 FastPVE-<VERSION> 协议；默认前台菜单，AI 不能将启动成功解释成 PVE 业务操作完成。PVE 大版本兼容性仍需设备验证。私有缓存 marker/size 不检测同大小的外部篡改，不允许共享可写工作目录。详见 [FastPVE 协议](../fastpve/README.md)。


## Linux storage candidate protocol (scripts-0.1.8 / Rust zsetup0.5.0)

Use `zsetup install APP --foreground -- --installer-prefix /PATH --installer-work-dir /PERSISTENT -- BUSINESS_ARGS`.
Common options precede business arguments. Default user command is ~/.local/bin/APP;
DDNSTO/LinkEase root service payloads use protected /opt/linkease/APP. Existing
foreign commands/units require explicit migration. Do not force-copy into /usr/bin.
Unattended sudo never prompts: missing credentials or command policy returns2;
a human can run sudo -v first. Use supplied token/version flags for noninteractive
business input. Facts and unknowns come from storage JSON; do not infer persistent
storage from overlay name or from available bytes alone. Low/unknown memory-backed
storage returns12 without terminal; no automatic disk scan. See linux-install-storage.md
for measured caps, SHA cache/metadata distinction, cancellation, recovery and native package mapping.
This source candidate must not be deployed against live0.4.0 or old immutable script paths.
