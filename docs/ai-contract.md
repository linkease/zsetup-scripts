# 用户与 AI 调用协议

0.1.8直接入口更新：Linux固定4.2.3、OpenWrt Standard固定4.2.6/Lite固定4.2.2，摘要嵌入入口；不读取业务VERSION/SHA256SUMS。未知产品返回11，在替换程序/安装包前失败。GitHub固定commit入口不需要索引。以下服务与Token协议保留；历史远端业务元数据描述不适用于当前固定版本路径。

复用现有 zsetup 命令，未新增服务或网络 RPC。先用 `zsetup context --json` 获取系统事实，`zsetup install --list` 获取配置中的应用标识；列表表示索引声明，不保证当前设备匹配。Product Configuration 中平台匹配由 zsetup 执行，业务脚本再次校验支持范围。

| 标识 | 参数 | 返回与交互 |
|---|---|---|
| fastnet | `zsetup install fastnet --foreground -- ARGS...` | 原样传 ARGS，安装器最终 exec FastNet，退出码继承业务程序；它可能打开菜单，自动化须使用业务已支持的非交互参数，本文不虚构 FastNet 参数 |
| ddnsto | `zsetup install ddnsto --foreground -- --token TOKEN [--force-version lite\|standard] [--verify-status]` | OpenWrt token 可选；Linux 无终端 token 必需。Linux 不支持 lite/verify-status。前台退出码为业务结果 |
| ddnsto/macOS | `sh ddnsto/install.sh --token-file FILE [--version 4.2.1]` | 工程候选，原生未验收；自动引导 zsetup；x86_64/arm64 用户级 launchd，校验归档 SHA256 |
| ddnsto/Windows | `powershell -File ddnsto/install.ps1 -TokenFile FILE [-Version 4.2.1]` | 工程候选，原生未验收；自动引导 zsetup；x64 CLI 和 SYSTEM 计划任务，校验归档及 EXE SHA256 |
| fastpve | 不调用 | 尚无源实现、参数或测试，不在索引中 |

Linux/OpenWrt 业务入口约定：0 成功；2 参数/平台不支持、缺少必需交互输入或 Linux 服务环境不可用；11 业务 metadata 不完整/非法；13 Linux 本地服务健康确认失败；包管理器、启动程序、zsetup download 的其他错误码原样传播；信号退出 129/130/143。zsetup 自身配置/索引/版本收敛失败通常返回 17；download 的错误类别由其既有命令协议定义，不把一切非零都解释成“业务安装失败”。不要解析人类进度文案作为成功协议。

0.1.6 Linux 必须具备 root/sudo 和可用 systemd 或已初始化 OpenRC。启动后独立检查服务状态、PID 对应的二进制和真实监听端口的本地 `/healthz`；成功输出 `local_service=healthy cloud_status=unverified`。失败尝试恢复原程序和服务 Token 配置；恢复失败保留备份并提示人工处理。普通无 init 容器或其他 init 暂不属于此系统服务安装路径。工程夹具可用 `DDNSTO_LINUX_CONFIG_DIR` 隔离文件，但它不改变真实客户端固定的服务配置路径，不能当成用户配置参数。

POSIX 可用 `--token-file FILE` 替代直接参数；与 `--token` 互斥。文件权限由调用者保护。桌面首次安装必须提供 Token，后续可省略并保留 YAML/身份文件；不同 Token 拒绝自动覆盖。桌面当前仅承诺 0/非零，不套用 POSIX 完整错误码表。运行状态和设备在线不是同一结果，当前输出 `cloud_status=unverified`，需控制台确认。0.3.0 的索引安装夹具失败尚待定位，不能仅凭 `--list` 成功认定可安装，见 [验证记录](verification-2026-10-13.md)。

后台：`zsetup install ddnsto --background -- --token TOKEN` 返回 0 仅表示成功启动，stdout 给出 pid/log/result。等待 result 出现并读取其最终退出码。后台 stdin 关闭，不能回答 token 或 HTTP bootstrap 确认。FastNet 菜单默认使用前台；DDNSTO 默认前台便于直接拿到真实错误。

一键脚本中的 bootstrap 只处理 zsetup 的 HTTPS stable/exact version；直接进入当前脚本的业务函数。安装模式由 zsetup 设置 `ZSETUP_INSTALLER_MODE=1`，提供 ZSETUP_BIN、OS/PACKAGE_MANAGER/ARCH/MEMORY_TOTAL_MB、SOURCE_BASES/SOURCE_FALLBACK、CONFIG_VERSION。AI 正常使用 install，不能伪造这些变量来绕过平台或摘要校验。

zsetup 默认完整本地配置 `/etc/zsetup/config.json` 优先于云端；无本地配置时读云端，故障才使用已验证 last-known-good。配置不按字段合并。SOURCE_GROUP 三个 primary 与 final fallback 顺序保持既有规则。脚本通过 HTTPS 的 VERSION/SHA256SUMS 获取业务发布信息；下载的新包必须由 zsetup 校验 digest。业务缓存复用只信任私有工作目录中已成功校验后写入、与 metadata digest 和文件大小一致的标记；不把该目录用于外部可写内容。

工程测试变量包括 ZSETUP_ROOT/WORK_DIR/BOOTSTRAP_BASES/CA_FILE、DDNSTO_BIN_PATH/SERVICE_PATH/MEM_MB；这些不是面向普通用户的安装参数。token 不写入安装器日志；真实命令行参数和 uci/业务程序如何保存凭据仍遵循业务自身契约。

0.1.2 脚本要求 zsetup >=0.2.4。`context --json` 增加 `memory_total_mb`（整数 MiB，未知为 null）；字段模式为整数或 unknown。`metadata version FILE [KEY]` 与 `metadata sha256 FILE NAME` 仅读取受限本地数据；0 成功、2 参数错误、11 内容错误、12 文件错误，成功 stdout 只有一行值。DDNSTO 的 900 MiB 阈值仍由业务决定；测试可用既有 DDNSTO_MEM_MB，普通用户无需传内存参数。
