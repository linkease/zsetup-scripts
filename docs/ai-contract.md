# 用户与 AI 调用协议

## 当前入口：0.2.0 工程候选，未发布

当前能力与限制以 [候选使用与验收说明](candidate-0.2.0.md) 和 `ddnsto/install-rules.json` 为准。下方版本段落均为历史快照，不能用作当前能力清单。

通用 POSIX 入口自动识别设备；Windows 使用 PowerShell 入口，不能把两种 shell 的命令混用。原生平台新增显式 `repair/configure/uninstall`；默认重跑不修改，更新不能夹带新 Token。写操作持锁。Linux/macOS/Windows 卸载保留配置；各执行器的托管判定、恢复和重装限制见当前说明。Linux configure 需要 jq。

Linux/OpenWrt zsetup 固定 0.5.0 并在执行前验证内嵌摘要，不跟随 stable、不允许 HTTP bootstrap；桌面保留其已审查版本。产品缓存每次交给 zsetup 按固定 SHA 校验，不再以“摘要标记+相同大小”跳过校验。

Synology `--action download` 仅下载校验 SPK，返回 0 不表示安装完成；默认 install 下载后返回 20，要求在 DSM 套件中心手动完成。Docker 仅普通 Linux amd64 本地引擎工程候选；容器运行不等于客户端健康/云端在线，替换更新和保留状态重建仍受身份验收限制。不得将 `candidate_executor=available` 升级为正式平台支持。

## 历史记录

0.1.16 本地候选：Windows `-Action repair` 在管理员权限下修复既有托管安装的计划任务，允许任务缺失，但要求 EXE、配置和托管标记完整且非 reparse point；拒绝同名但执行路径/参数/工作目录不匹配的任务。复用现有程序和配置，不下载、不改 Token/身份，拒绝凭据及 Plan。使用安装锁；失败尝试恢复原任务 XML/运行状态，恢复失败保留备份并提示。成功输出 `operation=repair local_service=running cloud_status=unverified`，并非云端在线证明。其他平台和默认重跑菜单尚不提供 repair；统一卸载仍未实现。

0.1.15 本地候选：Linux/OpenWrt 安装、update、start/stop/restart 使用同一机器级写锁，获取失败返回 16（已有操作、残留锁或目录权限等）；不得把它当作操作成功或自动删除锁重试。原有业务错误码保持不变。锁覆盖安装事务和失败恢复，正常/异常结束后尝试释放；SIGKILL/掉电遗留锁需管理员确认无相关进程后处理。只读 status/plan 与默认无修改退出不拿写锁，status 不保证更新过程中的一致快照。zsetup bootstrap 不在此锁范围。锁不协调旧版本脚本、手工包管理器或服务命令。下方 0.1.14 的“Linux/OpenWrt 尚无共享锁”已过时，其余接口不变。

0.1.14 本地候选：Shell `--action status|start|stop|restart` 和 PowerShell `-Action status|start|stop|restart` 在既有 Linux/OpenWrt/macOS/Windows 原生安装上可用。管理不 bootstrap、不下载、不读 Token，拒绝凭据与 plan 组合；Shell 也拒绝 force-version/verify-status。stop 同时关闭自启，start/restart 恢复自启。平台/方法约束仍有效，不提供 NAS/Docker 管理。Linux 要求 root/sudo，OpenWrt 要求 root，Windows 要求管理员。

输出 `local_service=running|stopped|... cloud_status=unverified`，不把运行等同于云端在线或完整健康。Linux systemd 可报告 failed/过渡状态，Windows 可报告 starting；查询错误非零退出。缺失安装/服务拒绝自动修复。Windows 管理校验任务路径且使用安装锁；Linux/OpenWrt 尚无共享安装锁，调用方不得并发安装/管理。管理中途失败不保证原状态恢复，应检查 status。未提供统一卸载。最新能力以本段为准，下面为历史记录。

0.1.13 本地候选：Shell `--action install|update`、Windows `-Action install|update`，默认 install。已有完整安装在默认调用中不自动重装：非交互返回 0 和 `operation=none installation=existing cloud_status=unverified`；交互菜单 `0`/空输入退出、`1` 更新，其他输入非零失败。退出是无操作，不是更新或健康检查成功。

显式 update 必须有已有完整安装且不能同时提供 Token/TokenFile；更新保留配置，不隐式迁移安装方式。Linux 用 `-daemon` 复用旧配置，不传 `-u`；OpenWrt 保留既有 UCI/包安装路径，尚需真机验收。Linux/OpenWrt 使用主程序与配置路径判断存在性，尚非完整的包所有权/多实例检测；缺失或符号链接文件拒绝覆盖。Linux 直接默认退出发生在 bootstrap 前，安装模式仍在 zsetup context 之后再次检查。macOS 原有 status/start/stop/restart 保留。

目前只实现退出/更新菜单，未实现修改 Token、修复菜单、统一卸载或 Docker/SPK 执行器。下面各版本说明为历史记录。

0.1.12 本地候选新增：Shell `--plan` 与 PowerShell `-Plan` 只读预览，拒绝同时传 Token/TokenFile；只做本地初筛，无下载、服务变更或云端验证。Linux/OpenWrt 预览返回 `facts_source=local-preflight`、`platform`、`arch`、`native_status`、`client_version`、`docker_probe`、`docker_installable=false`、`installation_performed=false`；不可用目标/显式 Docker 返回 2。桌面也提供平台、版本、本地前置检查要求和未安装标记。0 只表示预览成功，不表示可安装。

macOS 支持 `--platform auto|macos --method auto|native`、`--action install|status|start|stop|restart`；Windows 对应 `-Platform auto|windows -Method auto|native`，暂未提供管理 Action。macOS 管理操作拒绝凭据，不能与 `--plan` 组合；只处理托管安装，使用安装锁避免与安装并发。stop 禁用自启并 bootout，start 重新 enable；这些不是 kill 进程操作。status 报告本地运行/停止/未安装，云端始终独立确认。

Shell 交互 Token 可见，但不额外记录凭据；Windows 仍是既有隐藏输入。安装重复执行菜单、统一卸载、推荐版本清单及 NAS/Docker 执行器尚未实现。以下旧版本记录仅用于历史兼容。

2026-10-21 / 0.1.11 本地候选：Linux/OpenWrt 支持 `--platform auto|linux|openwrt|synology|qnap|unraid` 与 `--method auto|native|docker`。平台是约束，不覆盖检测结果；已识别的 NAS 和所有 Docker 安装请求当前返回 2，未接入执行器。桌面参数未变。下述 `zsetup install ddnsto` 仅适用于已配置相应索引的环境，不能用于当前只含 FastNet 的公共配置；用户交付采用独立直接入口，不要求 zsetup 核心源码。完整目标与当前差异见 [实施契约](universal-install-contract.md)。

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
