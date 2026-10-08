# 接入一个新业务

1. 提供业务方维护的已验证安装逻辑、唯一应用标识、系统/包管理器/架构矩阵、参数、退出码与交互要求。明确包、辅助文件和服务权限，不把业务语义写入 zsetup。
2. 在 `apps/APP/business.sh` 定义 `APP_install`，在 `main.sh` 调用同一函数；普通模式先 bootstrap，installer mode 直接执行业务。使用 ZSETUP_BIN download/context；后台使用既有 run/install。业务 Artifact metadata 给出真实 SHA256，下载失败不安装半成品。
3. 扩展 `scripts/build-entrypoints.py` 的应用列表，生成唯一 standalone install.sh；内部 business/main 与 lib/bootstrap 不发布。保持“正在运行的脚本不再下载自身”。
4. 为 catalog.json 增加明确 context selectors、script 源路径、不可变 `APP/VERSION/install.sh`、background。此文件只是生成 Product Configuration 的构建输入，不是新运行时配置协议。scripts 发布版本与 zsetup exact stable 版本各自管理；min_version 的当前实现要求完全相同，不能填写模糊 semver 范围。
5. 加入隔离 HTTPS fixture 测试：直接/index 两入口、架构拒绝、参数/交互、缓存、进度、下载/安装错误与清理。增加 package-release 的公开可变入口与必要兼容 URL；校验 catalog、hash、size 与发布包一致。
6. 修改脚本字节时递增业务不可变版本/config_version；保持已经发布的目录不变，发布顺序见 release.md。先验证产物，再更新入口与配置指针，stable 最后激活。

待接入：

| 应用 | 已知现状 | 必须补齐 |
|---|---|---|
| fastpve | 源仓库无脚本、辅助文件或测试；未加入安装索引 | 权威源码/commit、业务 owner、Proxmox/PVE 版本和 CPU 矩阵、root/服务影响、参数/交互/退出码、安装/升级/回滚逻辑、真实产物 URL/SHA256、隔离 PVE 测试环境 |
| LinkEase/KSpeeder 等 | 本次源仓库没有相应 installer | 相同输入；不能仅凭产品名编造安装逻辑 |
| DDNSTO 泛 ARM/MIPS、其他 Linux | 当前 zsetup ABI 或 context 无法证明覆盖 | 具体 ABI/字节序、可执行发布物与设备测试；不使用 arch=* 掩盖缺口 |

新增业务统一通过 `zsetup context get memory_total_mb` 读取总内存，通过 `zsetup metadata version FILE [KEY]` 和 `zsetup metadata sha256 FILE NAME` 读取已下载的版本与摘要。只读取普通、最多 16 KiB 的数据文件；不要 source/eval 网络元数据，也不要自行复制 awk/sed 解析器。使用这些能力时最低版本为 0.2.4。
