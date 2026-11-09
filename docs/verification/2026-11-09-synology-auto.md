# 群晖自动安装候选与真机验证

## 范围

当前结论：DS220j / DSM 7.1 的空白安装、升级、重复启动已验证；下文首次失败及临时禁用新装是排障历史，最终由本机套件中心 API 解决。用户随后授权加入添加设备并更新测试服务器，发布回执见末节；正式站未变。

授权设备 192.168.9.121，DS220j，DSM 7.1-42661 update 3，aarch64，kernel 4.4.180+。现有 SPK 4.2.7-7 使用 ELF32 ARM 客户端。复用线上 4.2.8-7 SPK 和已有 zsetup 0.5.0，不改核心、不重打产品包、不修改套件中心信任策略。

默认 ensure 自动识别群晖，独立调用 DSM 套件适配器，不进入通用 Linux systemd 安装路径。管理员从交互式 SSH 执行时自动请求 sudo；未授权时明确 E_PRIVILEGE，不修改套件。DSM 7 候选支持 x86-64、ARMv7；ARM64 只允许此次验证的 DS220j。DSM 6 保持手动安装。

## 实现

- auto-synology.sh：账号和权限校验、包版本比较、更新、启动及稳定 PID/可执行文件验证。
- synology-download.sh：共用 SPK 选择和现有 digest，原手动下载入口保留。
- main.sh / auto-install.sh：默认群晖分发与管理员授权；生成器嵌入新模块，不下载第二份脚本。
- auto-synology-fresh.sh：新装使用 DSM 自身的 `SYNO.Core.Package.Installation`，先 check 默认卷，再 install；`extra_values` 使用与设备 PkgManApp.js 相同的 JSON 字符串编码。接口 `.success`、安装版本、配置账号及稳定进程分别检查。
- 已安装账号必须一致；保留 Token、routeridx、供应商及扩展配置。未知版本、权限异常、下载失败、安装失败或进程不稳定均不能显示成功。
- 版本比较包含套件修订号，较新版本不降级。下载前备份配置，下载后再次检查配置及版本；升级后配置不同则停止自动操作并提示备份位置。
- 不自动卸载，不改原生/容器安装方式，不把进程运行当作云端在线。

## DSM 环境差异

- DSM 的 jq 为 1.5，不支持 --rawfile。使用 raw stdin + --slurpfile 比较 Token，不把 Token 放到 jq 命令参数中；补回归测试。
- /tmp 是 noexec；已下载且 digest 正确的 zsetup 在此执行返回 126。仅群晖适配使用受保护的 `/var/lib/ddnsto-installer/native`，不改挂载、不降低 TLS 或 SHA256 校验。
- /var/tmp 是 world-writable 且无 sticky bit，自动适配的 SPK 和配置备份使用 `/var/lib/ddnsto-installer/package.*`，不复用不安全目录。
- DSM jq 1.5 未编译 ONIGURUMA，不能用 test/match 正则函数；卷号由 shell 校验，JSON 只负责读取和结构检查。
- 本机 API 的 check_codesign=true 对第三方 SPK 返回 4532，设备套件中心 JS 将其解释为第三方安装确认。仅在原生 zsetup 已校验固定摘要后，对当前 DDNSTO SPK 使用 check_codesign=false，force=false、installrunpackage=false；不改变全局信任策略，不跳过 HTTPS/SHA256，不执行未经确认的其他包。
- synowebapi 只能通过命令参数接收 extra_values，Token 在调用期间可能被本机有权限查看进程的用户看到；不宣称进程参数无凭据。屏蔽原始 stderr/响应，诊断仅含固定错误码，不写公共临时 Token 文件。实测系统 messages 未检出测试 Token；这不保证所有 DSM 审计组件都不记录参数。

## 真机结果

1. 原版本 4.2.7-7、状态 running。完整备份最终移至 `/var/lib/ddnsto-installer/before-auto.Yc8I3v`（私有目录；内含 target.tgz、data.tgz、INFO；含敏感配置，不上传仓库）。初次两个失败分别是 jq 参数和 noexec，均未修改套件。早期失败的配置备份也移至受保护目录 failed-package.AH0HUS。
2. 候选通过真实 HTTPS、原生 zsetup 校验、synopkg 安装，升级为 4.2.8-7，返回 0，状态 running。配置 SHA256 前后一致。诊断 `/tmp/ddnsto-result.9Eoj4j/events.log`。
3. 主动停止套件后，用管理员的真实 SSH TTY 执行候选，输入 sudo 密码，返回 0 并重新启动。诊断 `/tmp/ddnsto-result.Bd38L9/events.log`。用 su 模拟的会话没有可用控制终端，不能代替真实 SSH 验证。
4. 最终 sudo -v / sudo -n 候选再次从真实 SSH 验证成功，诊断 `/tmp/ddnsto-result.JPzpHk/events.log`；使用不同的测试账号字符串返回 E_ACCOUNT / 2，服务及配置不变，诊断 `/tmp/ddnsto-result.jPLJfW/events.log`。测试用临时 Token 文件已删除。
5. 用户另行授权备份、卸载、重装。新备份 `/var/lib/ddnsto-installer/before-fresh.lr4BRX` 包含完整 data.tgz、target.tgz、INFO、原配置。卸载后 DSM 保留 appdata，且 `/tmp/.ddnsto` 有旧配置；两者均移入此私有备份，确保测试不借用旧配置。
6. 真正空白安装失败，诊断 `/tmp/ddnsto-result.hYgQ0W/events.log`。DSM 日志明确 postinst 返回 1，`Invalid or missing DDNSTO Token`；传入 synopkg 的 wizard 环境变量没有到达 postinst。旧 fixture 模拟了变量透传，不能代表 DSM 实际行为。
7. 恢复原配置，使用已校验 SPK 修复安装并启动，版本 4.2.8-7，原配置字节比对一致。随后停止服务恢复原应用数据，再重新启动；失败现场数据也单独归档保存。没有改动其他套件或共享文件。
8. 新增先失败后通过的回归：空白设备在下载/安装前返回 E_MANUAL_INSTALL，提示套件中心手动新装；去掉无效的 wizard 环境传参。当前仅开放已有套件的自动升级与启动，不通过共享 /tmp 预置 Token，也不自动卸载修复半安装。
9. 最终生成入口在恢复后的真机执行返回 0，诊断 `/tmp/ddnsto-result.eUTkX5/events.log`。原配置和 `.ddnsto_boot.cfg` 均逐字节一致，4.2.8-7 稳定运行。单独的测试 Token 文件已删除，恢复用私有备份保留。最终自动适配 8、SPK 16、默认流程 11、OpenWrt 6 项通过；入口生成一致性、shell 语法和 diff 检查通过。未发布公网。
10. 继续开发后新增备份 `/var/lib/ddnsto-installer/before-api.xgEuh9`。再次隔离卸载保留数据，验证本机安装 API 成功将原 Token 写入新配置，默认 routeridx=0，无需修改 SPK 或 zsetup。接口试验后恢复原状态。
11. 最终生成脚本 `/tmp/ddnsto-syno-api.Ev5r00/install.sh` 在空白状态完整执行通过，退出 0；诊断 `/tmp/ddnsto-result.lUQ0iE/events.log` 包含 checking → installing → installed → starting → started、exit_code=0。Token 和默认设备编号通过只输出布尔结果的检查。首次候选因 jq 正则能力返回 E_STORAGE，未修改套件，修复后通过。
12. 完整新装验收后停止套件、保存新装现场、恢复原应用数据并重新启动。再次执行候选返回 0，诊断 `/tmp/ddnsto-result.utq0zs/events.log` 无 installing 阶段，证明同版未重装；原 config.json 与 `.ddnsto_boot.cfg` 字节一致，4.2.8-7 状态 running。删除单独的 test-token，私有恢复备份保留。模块布局检查、生成一致性、语法及 diff 检查通过。

## 验证边界

- 自动适配测试覆盖账号冲突、配置保留、旧版升级、同版/新版不重装、安装/启动失败、启动分发、缓存位置、sudo 拒绝、新装 API/空响应失败、参数编码、日志遮盖、卷校验和残留文件/悬空链接拒绝；手动 SPK 测试覆盖机型白名单及原平台规则。
- 最终自动适配 8 项、手动 SPK 16 项通过，自举 19 项、下载 35 项及 OpenWrt 默认流程回归通过；生成入口一致性和 diff 检查通过。全仓检查仍在 privilege_bridge_test.py 因 unshare 无法写 uid_map 中断，不能计作全量通过。单独运行历史 entry_dispatch_test.py 仍因旧 harness 缺少 installer_dispatch 失败，未改写该历史测试来掩盖失败。
- 首次安装已通过上述生成入口真机验收；不把后续恢复配置的操作计入安装成功条件。自动适配现为 12 项，SPK 16、默认流程 11、OpenWrt 6 项通过。其他机型及不同 DSM 构建仍需验收。
- 未做重启 NAS、断电恢复、新装失败恢复、DSM 6、其他机型验收。需额外设备或明确授权后补齐，不能据此宣布全群晖上线。
- 未发布测试站或正式站；公网 `/i` 仍是前一次 OpenWrt 修复版。未提交、推送。临时 token 文件验证后删除，私有升级备份保留供恢复。

## 后续授权测试发布

- 控制台添加设备测试流程明确展示“Linux / macOS / 路由器 / 群晖命令安装”，沿用统一短命令，不新增平台选择；说明 DSM 7 管理员 SSH、sudo、默认卷、DS220j 验收及残留配置拒绝。手动下载兜底保留，高级调试仍是显式下载操作。
- `/i` 薄入口和 Nginx 均不变。Shell 推荐清单原子更新至 `bde55c2ee88dd7325d0556945ef6dc47dc3948aef7856096e8ae9f65e43428e5`，398498 字节；最终变更包括帮助文本同步。此前业务真机验收字节为 31ec90649e0e，新版仅修正帮助说明。
- 推荐目录仍为 `/ddnsto-install/0.2.4/recommendation-short-20261109`；高级固定目录 `/ddnsto-install/0.2.4/20261109-bde55c2ee88d`。旧不可变产物保留，Windows 脚本和推荐数据未替换。
- 更新前 Shell/review 备份为推荐目录内 `.recommended-shell.txt.pre-synology-31ec90649e0e`、`.review.json.pre-synology-31ec90649e0e`。前端更新前备份 `/home/ddnsto/shared/ddnsto-static/.backups/console-2026/20261109-120918`；回退需先确认后续发布，仅恢复本次范围。
- 使用现有 test-toany 发布流程更新桌面和移动控制台。production 与 staging 构建通过；production 产物不包含新入口/群晖候选说明。既有大 chunk 提示不影响构建。
- 前端相关单元测试 33 项通过、1 项 PowerShell 测试跳过；测试站浏览器 4 项通过（API 夹具，不修改真实账号），包含群晖提示、命令、明暗模式、手动兜底和高级操作。新增帮助回归后群晖脚本测试 13 项通过。
- 公网不可变脚本回读 SHA256 一致；通过全新私有缓存执行公网 `/i --help` 成功，确认新群晖说明。不把此只读检查作为新的真机安装验收。未提交、推送或部署正式环境。
