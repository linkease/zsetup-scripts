# DDNSTO 0.3.3：通用非 systemd Linux 后台进程

状态：本地候选；未提交、未推送、未发布。替代同日尚未发布的 s6 专用实现。

## 范围与决定

- 用户要求通用非 systemd 兜底：不增加挂载，不保证重启/重建后恢复。
- systemd 可用时维持原服务流程；否则以当前用户启动二进制，不提权，不注册服务。
- 普通 Linux 二进制安装不再要求 apt/yum/dnf 存在；OpenWrt 继续使用其专用包管理器。
- Linux 产品仍是平台配置中的标准版 4.2.8，归档摘要
  `3bf7ada14448b5aa04afa171e497f85d0b8bb4adcf2209991e52ef5826d4e975`。
  当前发布包仅有 x86_64/aarch64；架构、内核或 ABI 不兼容不宣称支持。
- 继续使用 zsetup 的有界下载、SHA-256 校验、解包输出限制和私有事务锁；不修改核心。
- `~/.local/share/ddnsto/` 保存二进制、配置、身份、日志和 PID；不要求新增持久存储。
  拒绝不属于当前用户的目录、宽松权限、符号链接、只读/noexec 路径。
- 私有 TMPDIR 隔离客户端锁。不会接管其他来源的运行进程，不改系统配置。
- PID + `/proc` 启动时间 + 可执行文件校验；启动后连续检查三秒。
  有 setsid 时脱离终端会话；否则重定向标准流、继承忽略 SIGHUP 的直接后台启动。
- 重复执行保留 PID；升级先下载验证再停进程，失败尝试恢复原二进制/记录/运行状态。
  不提供守护重启、开机自启或容器重建后的恢复保证；丢失配置时可能产生新身份。
- 支持 ensure/install/update/status/start/stop/restart/repair；不支持 configure/uninstall。

## 本机验收

以下为先前 `/tmp/ddnsto-process-911` 版本的真实客户端验收记录。随后用户要求改到
`~/.local/share/ddnsto/`；新路径由隔离用户目录测试覆盖，未自动迁移或删除旧测试实例。
新路径专项测试共 22 项通过，包含缺失/相对 HOME 拒绝、自动创建父目录、空格与单引号
路径的配置转义、符号链接父目录拒绝，以及新目录下重复安装保持 PID。已有目录不 chmod，
systemd 分流保持不变；生成产物、产品配置检查、指南检查及 sh/Bash POSIX 语法检查通过。

目标：当前 Ubuntu 24.04.1 x86_64 容器，abc/UID 911，无 systemd。
执行本地生成的 `apps/ddnsto/versions/0.3.3/install.sh`，自动自举已发布 zsetup 0.6.4，
下载已发布客户端，使用此前授权的测试账号 Token（不记录原文）。
这不是正式域名最新版验收，正式服务器未修改。

| 场景 | 结果 |
| --- | --- |
| 普通用户安装 | 4.2.8；退出 0；checking → installing → installed → starting → started |
| 安装 shell 退出 | 进程父 PID 为 1，独立 session；后续命令仍可确认运行 |
| 同版本重复执行 | 退出 0，PID 2539031 保持不变 |
| stop 后 status | stopped；无自动重启 |
| 再次 ensure | 启动成功，新 PID |
| restart / status | 运行正常；最终 PID 2543931 |
| 配置与设备身份 | 多次安装、停止、重启前后摘要不变 |
| 原有开发客户端 | PID 1596957 保留，未停用、替换或修改旧锁 |

诊断：`/tmp/ddnsto-result.CYy0mJ/events.log`、`A4X2m8/events.log`、
`KkBlyw/events.log`、`YY9imU/events.log`。
配置摘要 `7e3f75a14f8a369615f6404efa350327ff3115425c80904364b88b94d0c4c6bc`；
身份摘要 `ba5d0d5555011a0f08414402ff2e240b97b8aa22817482a9d11502e41e5da2cb`。

## 取代 s6 实验

只停用了本轮创建的 `ddnsto-zsetup` 实验服务并退出其 supervisor。
服务入口及定义移至 `/opt/linkease/ddnsto-s6/retired-service-*`；旧配置和客户端保留可恢复，
不再随容器启动加载。未重启整个容器、修改主机或删除任何其他服务。
此前 s6 实验文档保留为历史证据；当前代码不再包含 s6 专用模块或依赖。

保留三个独立的生成器修复：提权程序实际调用业务入口、空 CA 环境变量不作为文件路径、
不剥离 heredoc 中的注释/shebang。共享持久化策略与其他应用不变。

## 自动测试与发布边界

`DDNSTO_TEST_NATIVE=/tmp/zsetup/rescue/0.6.4/zsetup python3 -B tests/ddnsto_process_test.py`：
18 项通过（包括去除 Linux 包管理器限制）。覆盖重复安装、启停、账号/环境冲突、未知架构、目录安全、PID 复用、
下载失败、启动失败、禁止降级、摘要变化、失败升级恢复、独立会话和生成器契约。
fixture 使用独立目录及临时编译的小进程，不操作宿主服务。

产品配置生成、apps 构建及 --check、git diff --check、主机 sh/Bash POSIX 语法检查通过。
旧 0.3.2 不可变文件保持原字节。
改为用户主目录后，全体 `ddnsto*test.py` 共 169 项：141 通过、28 跳过（缺少对应原生/平台环境及旧 Shell）。
另单跑复杂应用迁移验证（10 应用/137 平台记录）、标准入口 5 项和指南 3 项均通过。
完整 `scripts/check.sh --native-bin ...` 在 `privilege_bridge_test.py` 被容器禁止
`unshare` 写 `/proc/self/uid_map` 阻断；此前发布树、事务、迁移、平台和下载边界检查通过。
没有绕过隔离去操作真实宿主服务。原生源码文档路径在此工作区不可用；未修改核心。
未做真实跨版本升级、aarch64/其他发行版、无 setsid 精简系统或重启/重建验收；
不检查云端在线。发布须另行授权，不将本地测试等同正式入口已生效。
