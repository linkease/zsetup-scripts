# DDNSTO：zsetup 能力复用审查与候选开发任务

日期：2026-11-16。状态：开发与验收进行中；**未部署、未切换核心或推荐入口**。

> 后续进度（同日，用户授权“开始开发”）：已完成第一批局部实现和定向回归，详见[第一批实现与验证](verification/2026-11-16-ddnsto-native-reuse-batch1.md)。下文“未开始”保留方案确认时基线，当前逐项状态以验证记录为准。未部署、未切核心，完整真机验收尚未完成。

代码核验基线：`1621a0db166c35e2669ff3818c593f198a990c49`。负责人、排期和上线日期未指定。本文编号仅为工程任务，不代表员工承诺、经营行动或已启动的 AgentFlow 任务。

产品约束：[一键安装复用边界](https://github.com/linkease/ddnsto-meta/blob/main/13-product-definitions-产品定义/features/add-device/one-click-install-reuse.md)（本轮本地新增，推送前远端可能不可访问）。不修改 zsetup 核心，不改变其他业务的发布物。

## 1. 结论与核验范围

不能把现状描述为“脚本重新实现了整个 zsetup”。Linux/OpenWrt 已大量复用 context、download、storage、capture、run。下一批候选是可信核心启动后的摘要计算、重复下载适配和有界解包；入口顺序调整单列第二阶段。

- 代码事实来自本基线的维护源文件，不以生成文件行数或历史 README 为准。
- 公开发布事实来自 HTTPS stable、配置、SHA256SUMS 和构建报告。
- 本机探针：官方 Linux x86_64 0.6.4 经 SHA256 校验后，`--version`、`--help`、`context --json`、`storage PATH --json`、`checksum FILE` 成功；没有进行完整下载、解包或安装验收。
- 本轮未定位到可读取的权威 zsetup-rust checkout；AGENTS 中历史位置不可用。因此不声称完成核心源码审计，也不从 CLI 帮助推断未验证的安全保证。后续只依赖已发布能力，不以获取核心源码作为前置条件。

### 发布快照

| 查询 | 2026-11-16 结果 | 限制 |
| --- | --- | --- |
| [stable](https://fw.koolcenter.com/binary/zsetup/stable) | HTTP 200，0.6.4 | 不是 DDNSTO 当前固定依赖版本 |
| [stable-windows](https://fw.koolcenter.com/binary/zsetup/stable-windows) | HTTP 200，0.6.5 | 不改变 Windows GUI 方向 |
| [stable-macos](https://fw.koolcenter.com/binary/zsetup/stable-macos) | HTTP 404 | 不证明所有 macOS 发布物不存在 |
| [config.json](https://fw.koolcenter.com/binary/zsetup/config.json) | installers 为 fastnet、linkspace、ks-cli、kspeeder、kai-skills，无 ddnsto | 默认在线配置不能直接承担 `zsetup install ddnsto` |
| [config-windows.json](https://fw.koolcenter.com/binary/zsetup/config-windows.json) | installers 仅 kai-skills | 同上 |
| [0.6.4 构建报告](https://fw.koolcenter.com/binary/zsetup/0.6.4/linux-build-measurements.json) | x86_64/aarch64/armv7/mipsel；native_execution=false，各记录 native_verified=false | 构建报告本身不是原生验收；本轮本机探针独立记录 |

本轮 Linux x86_64 文件摘要为 `9e87c8bf447cc14eb1a8d2ebfc5cfc2377bed4fcb99539c9175b644f5f10a237`，与[官方 SHA256SUMS](https://fw.koolcenter.com/binary/zsetup/0.6.4/SHA256SUMS)一致。构建报告声明 product_commit 为 `d413c46e6a7ba17e50a10847bbe01f2bb2260b50`，不是本地已审查的源码。

当前实际依赖：[bootstrap-policy.sh](../ddnsto/bootstrap-policy.sh) 固定 Linux/OpenWrt 0.5.0 及四架构摘要；[install-macos.sh](../ddnsto/install-macos.sh) 固定 0.3.0；[install.ps1](../ddnsto/install.ps1) 保留的 Windows CLI 固定 0.4.0，但不是本次要恢复的默认入口。[auto-asus.sh](../ddnsto/auto-asus.sh) 的现代渠道复用核心，armsoft 明确保留旧内核下载路径，不是失败后静默降级。

## 2. 逐项替换清单

“已复用”不意味着后续修改可以跳过回归；“候选”不意味着删除旧逻辑已获技术验证。

| ID / 功能 | 维护源与现状 | 原生对应能力 | 判定、风险与保留边界 |
| --- | --- | --- | --- |
| C01 系统事实 | [main.sh](../ddnsto/main.sh)、[business.sh](../ddnsto/business.sh) 已读 context | `context get os/package_manager/arch/memory_total_mb` | 已复用；DSM、华硕渠道、固件、实际包归属仍由业务识别 |
| C02 下载 | [lib/install-bounds.sh](../lib/install-bounds.sh) 的 installer_download；群晖/华硕独立组装调用 | `download` 的 sha256、size、max-bytes、min-free-bytes、多源和超时 | 已复用，可收敛薄适配；保留业务路径、可信元数据、预算、来源与错误策略 |
| C03 文件摘要 | auto-asus.sh 下载后再算摘要；推荐入口/macOS 亦有 shell 校验 | `checksum FILE`、`download --sha256` | 核心启动后的同义操作为候选；核心自身校验、跨权限复制后的复验和执行前复验不能盲删 |
| C04 目录摘要 | 已有文件清单、归属、配置保护逻辑 | `checksum-tree DIRECTORY` | 暂不替代：未核实输出、符号链接、权限、增删项语义；摘要不证明所有权或安装归属 |
| C05 解包 | install-bounds.sh 用 capture 包住 tar；[asus-package.sh](../ddnsto/asus-package.sh) 检查列表并选择性提取；macOS 用 tar | `archive extract -i ... -o ... --root ... --max-bytes ... --max-files ...` | 优先验证；Linux 只取单个架构成员，原生根目录解包可能扩大空间需求；白名单、渠道、版本、架构检查保留 |
| C06 存储 | [lib/install-storage.sh](../lib/install-storage.sh) 已用 storage；[portable-files.sh](../ddnsto/portable-files.sh) 有 stat/受限 ls 兼容 | `storage PATH get FIELD` | 部分已复用；private_directory/system_protected 不等于 owner/mode/link-count 全量接口；DSM 服务用户与受管符号链接单独判断 |
| C07 执行 | install-bounds.sh 的 installer_extract_member/installer_exec_native | `capture`、`run` | 已复用；保留退出码映射、取消、子任务回收、恢复时序；命令退出成功不等于服务成功 |
| C08 元数据 | business.sh 用 metadata sha256；[auto-install.sh](../ddnsto/auto-install.sh) 比较业务版本 | `metadata version`、`metadata sha256` | 通用格式解析可复用；不能替代 APK 3 数据库解析、版本排序、禁止降级和账号一致性决策 |
| C09 引导 | [recommended-entry.sh](../ddnsto/recommended-entry.sh)、bootstrap-policy.sh 先下载校验再执行 | 核心就绪后可调用 download/checksum | 第二阶段候选；核心自身不能自举信任。保留最小 HTTPS、架构分派、固定摘要、私有目录和首次执行前检查 |
| C10 推荐/索引 | recommended-entry.sh 读取三行清单，按摘要不可变路径取入口 | `install` 与配置 | 本期保留独立推荐协议，官方索引缺 ddnsto；推荐解析与发布策略仍需业务实现 |
| C11 平台事务 | [openwrt-adapter.sh](../ddnsto/openwrt-adapter.sh)、[openwrt-lifecycle.sh](../ddnsto/openwrt-lifecycle.sh)、[auto-synology.sh](../ddnsto/auto-synology.sh)、auto-asus.sh、各 lifecycle 文件 | run 只执行命令 | 必须保留 UCI/DSM/dbus、包归属、systemd/launchd/procd、锁、备份、配置、启动验证与恢复 |
| C12 诊断 | auto-install.sh 的 flow_note/flow_error/flow_finish | 通用退出状态 | 保留 checking/installing/installed/starting/started、原因、下一步和脱敏记录；不能以下载日志替代安装结果 |

共仓库 [kai-skills/business.sh](../kai-skills/business.sh) 已调用 archive extract，可参考调用格式，不证明 DDNSTO 包格式或设备兼容。

## 3. 两阶段结构与不变量

第一阶段保持：推荐入口 → 固定业务入口 → 可信核心 → 平台适配，只替换核心可用后的重复逻辑。

第二阶段评估：最小安全引导 → 可信核心 → 下载校验推荐业务入口 → 平台适配 → 安装及本地启动验证。这是获准评估的结构，不是已验证的实现。

- 核心按平台固定版本与摘要，不自动跟随 stable；旧版本平台不得调用不存在的接口。
- 核心首次获取仍需系统下载/校验工具；减少依赖而非跳过校验，不新增另一套通用下载系统。
- DSM noexec 临时目录、华硕 /jffs 与旧内核等最小分派可能仍需在核心启动前处理，不能依赖核心解决它自身的落盘与运行条件。
- 不执行包内脚本，不解包覆盖活动目录，不把摘要或布尔权限字段当作业务归属授权。
- 保留推荐新鲜度、不可变路径、摘要与大小、参数/stdin、退出码、超长入口兼容、取消后等待恢复；运行中的脚本不原地覆盖。
- 保留 armsoft 例外；macOS 未获得升级证据前保持现有路径；Windows GUI 不变，不自动切 Docker。
- 检查现有核心也须先验证可信字节和路径，不能先执行 `--version` 再建立信任。

## 4. 候选开发任务

以下为确认的任务范围；开发已获用户授权。当前状态见任务表后的进度清单，不能把任务描述当作已完成。

| 任务 | 依赖/阶段 | 交付与完成条件 |
| --- | --- | --- |
| A00 | 本轮 | 审查、产品规则、任务和验收计划齐全；校验结果单独报告 |
| A01 | A00，阶段一前置 | 建立现有 0.5.0/候选 0.6.4 与平台能力矩阵，核实摘要、最低运行条件、下载策略、退出码，不改核心 |
| A02 | A01，测试先行 | 用隔离夹具对照下载/checksum/archive/storage；覆盖坏摘要/大小、TLS/重定向、空间不足、链接、穿越、重复成员、设备节点、解压超限、超时与信号 |
| A03 | A02，阶段一 | 收敛核心启动后的下载/摘要薄适配；先验证 checksum 输出；保留可信元数据、预算和取消所有权，只删等价且不跨信任边界的重复操作 |
| A04 | A02，阶段一 | 优先 Linux 解包，再评估现代华硕；核实格式、总预算、文件选择/白名单和权限；不支持就保留旧实现，armsoft 不强切 |
| A05 | A02，阶段一 | 逐条映射存储/权限规则，不能表达的保留；statless OpenWrt 不能重新变成缺依赖失败 |
| A06 | A03—A05，阶段一验收 | 现有回归加三台真机；记录前后配置/版本/服务/恢复，缺场景标未覆盖，不扩大支持声明 |
| B01 | A06，阶段二设计 | 核心先行引导的信任链、版本选择、推荐协议、旧内核/macOS 分派、失败和回退方案；不直接改默认 install ddnsto |
| B02 | B01，阶段二实现 | 新旧入口对照，覆盖无 stat、BusyBox、DSM noexec、旧华硕、短命令/stdin/大脚本、取消；无证据不切入口 |
| B03 | B02，阶段二验收 | 重跑三台设备；准备不可变候选、读回与回滚方案。设备通过不等于授权部署或切推荐别名 |
| F01 | 非本期前提 | 官方 ddnsto 索引接入，有发布权限和正式元数据后单独推进 |

当前进度：

- A00 已完成；A01/A02 已有两版核心、OpenWrt/华硕探针及安全契约测试，完整矩阵仍未闭合。
- A03 已完成现代华硕的局部下载校验收敛；A04 已完成现代华硕 capture 收敛，全面 archive 迁移暂缓。
- A05 逐规则映射完成，见[存储与权限复用取舍](ddnsto-storage-reuse-boundary.md)；没有等价接口的安全检查明确保留，不以删代码为完成标准。
- A06 已完成 OpenWrt 4.2.8 同版本重复执行（配置不变、发生进程重启、稳定运行）和群晖 4.2.8-7 管理员同版本重复执行（配置及 PID 均未变、稳定运行）。华硕完整验收因连接不稳定按用户要求跳过，保留此前下载/暂存解包证据；新装、升级、故障恢复未覆盖，不能标全平台验收完成。
- B01 首批分流设计和 B02 核心先行实现已完成，打包默认不启用；见[第二阶段候选](ddnsto-native-first-candidate.md)。B03 已完成 OpenWrt/DSM 同版本公网验收、测试站 `/i` 激活及回滚演练，HTTPS 重定向差异已按测试环境边界审查。详见[发布记录](verification/2026-11-16-native-first-test-release.md)。完整真机矩阵仍有缺口，测试站完成不等于正式上线就绪；F01 不作为本期前提。

回归至少覆盖既有 statless、APK 3、多管理器共存、推荐入口安全、Linux/macOS 生命周期、群晖和华硕测试；生成文件须通过 `scripts/build-entrypoints.py --check`。缺核心 checkout 时不要声称 `scripts/check.sh` 全量通过；使用已发布核心执行可运行的定向测试，明确未运行项。

## 5. 真机验收计划

用户选择此前提供设备。仅记录定位信息，不保存密码、真实 Token 或配置。本轮未连接设备。

| 对象 | 目标 | 验收前重新确认 | 不可外推 |
| --- | --- | --- | --- |
| OpenWrt/iStoreOS | `root@192.168.30.244:22` | 型号、内核、架构、opkg/apk 记录、版本、配置、服务 | 不假定是用户报错的 aarch64/APK 3 设备；管理器共存需夹具补证 |
| 群晖 | `build@192.168.9.121:22` | DSM、架构、sudo、套件来源、目录/服务用户、服务 | 不代表 DSM 6 或全部 SPK 架构 |
| 华硕软件中心 | `admin@192.168.3.247:2222` | 型号、固件、渠道、架构、内核、软件中心、空间、插件 | 单机不代表六渠道或 armsoft 旧内核 |

顺序：只读盘点 → 确认候选及摘要 → 备份并确认可恢复 → 核心只读探针 → 无变更预检 → 同版本重复执行 → 条件满足时更新/受控启停 → 复核配置、身份、服务 → 脱敏记录。

验收要求：

1. 使用原绑定，不自动换 Token；配置在设备上比较，报告只记保持或变更项，不外传原文。缺凭据/权限即停止该设备验收，不把凭据写进代码、文档、日志或命令历史。
2. 不通过卸载、清配置、降级、断网、填满磁盘或重启路由器制造场景。首次安装仅在未安装且获准的目标做；不满足前置的升级/新装场景标未覆盖。
3. 坏包、权限攻击、空间不足、取消关键阶段、恢复失败等在隔离夹具/容器注入。通用自动测试不得触碰开发宿主服务或真实包管理器。
4. 真机服务写动作仅限本表授权设备的 DDNSTO，先有备份和恢复方案，不影响 SSH、网络及其他插件。
5. 记录安装器摘要、核心版本/摘要、机型/固件/管理器、场景、前后版本、配置和身份保持、服务验证、退出码、诊断与恢复结论。不以删除配置强制转绿。
6. 安装完成和本地稳定运行分别证明；后台任务已启动、进程瞬时出现不等于成功。云端在线另属模块。
7. Linux systemd、macOS、Windows GUI、armsoft 和其他架构需独立补证，不拿测试站服务器临时当客户端安装机。

## 6. 缺口及停止条件

archive/checksum-tree 只有接口与有限调用证据，安全等价性未验收；storage 不是完整 stat 接口；核心旧内核兼容、包格式与平台生命周期仍须验证。因此不能预先承诺删掉 tar/awk/cmp/stat 或所有 shell 哈希实现。

核心不兼容、配置无法备份、归属未知、外部锁存在、恢复无法保证或非预期状态出现时停止写入，保留现场并报告。正式站、测试站、推荐别名、索引更新均需独立发布授权。文档完成不得更新平台验收或线上发布状态。
