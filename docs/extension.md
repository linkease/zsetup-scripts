# 接入一个新业务

1. 提供业务方维护的已验证安装逻辑、唯一应用标识、系统/包管理器/架构矩阵、参数、退出码与交互要求。明确包、辅助文件和服务权限，不把业务语义写入 zsetup。
2. 在 `apps/APP/` 建立 `app.json`、当前版本目录和维护源码；复杂实现放在
   `apps/APP/source/`。使用 ZSETUP_BIN download/context；业务发布流程先把产品和
   版本/SHA256 元数据放到服务器，本仓库不采集或重打包产品。
3. 将审核后的自包含安装器写入 `apps/APP/VERSION/installer.sh` 或 `installer.ps1`。
   `scripts/build.py` 生成标准入口、兼容别名、平台配置和 `SHA256SUMS`。保持“正在运行的
   脚本不再下载自身”。
4. README 放在 `apps/APP/`，测试与夹具放在 `tests/apps/APP/`，不得放入公共 `apps/`。
   catalog 的 `script` 必须指向版本化安装器。`min_zsetup` 声明能力最低版本，不是精确
   核心钉死，也不能填写模糊 semver 范围；平台入口跟随各自最新 stable。
5. 加入隔离 HTTPS fixture 测试：直接/index 两入口、架构拒绝、参数/交互、缓存、进度、下载/安装错误与清理。增加 package-release 的公开可变 APP/APP-install.sh 入口与必要兼容 URL；校验 catalog、hash、size 与发布包一致。
6. 修改脚本字节时递增业务不可变版本/config_version；保持已经发布的目录不变，发布顺序见 release.md。先验证产物，再更新入口与配置指针，stable 最后激活。

核心兼容和 stable 提升门禁见 [zsetup 兼容策略](zsetup-compatibility.md)。

待接入：

| 应用 | 已知现状 | 必须补齐 |
|---|---|---|
| FastPVE 其他 CPU/PVE 版本的兼容证明 | 已按用户补充参考接入 x86_64 launcher；具体 PVE 版本未验证 | 业务 owner 确认的兼容表、已支持的非交互参数、对应产物与隔离 PVE canary；不在 zsetup 中编写 PVE 操作 |
| DDNSTO 泛 ARM/MIPS、其他 Linux | 当前 zsetup ABI 或 context 无法证明覆盖 | 具体 ABI/字节序、可执行发布物与设备测试；不使用 arch=* 掩盖缺口 |

新增业务统一通过 `zsetup context get memory_total_mb` 读取总内存，通过 `zsetup metadata version FILE [KEY]` 和 `zsetup metadata sha256 FILE NAME` 读取已下载的版本与摘要。只读取普通、最多 16 KiB 的数据文件；不要 source/eval 网络元数据，也不要自行复制 awk/sed 解析器。使用这些能力时最低版本为 0.2.4。

LinkEase 已按用户提供的 Linux/OpenWrt 参考脚本接入，模块见
[apps/linkease/README.md](../apps/linkease/README.md)；APK 等未验证平台保持未接入。

FastPVE 已按用户补充的 legacy/fastpve-install.sh 接入，见
[apps/fastpve/README.md](../apps/fastpve/README.md)。它展示“可信下载 + 启动业务程序”的
最小接入方式；没有服务安装逻辑时无需添加服务管理层。
