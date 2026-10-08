# 迁移盘点与任务树

日期：2026-10-07。开始时目标仓库 `deef63b`、源业务仓库 `13bfb75` 都干净；zsetup 所在工作区 `ee0f11a` 仅有用户已有的 `SocksTun-iOS` 子模块改动，禁止覆盖。

读取了三个仓库 README、适用 AGENTS、zsetup CONTEXT/需求/产品原则、S6 配置协议、生命周期、Roadmap/里程碑/实施计划、发布与 0.2.3 Race 修复证据。当前 stable 0.2.3，默认 Race 30 秒覆盖 DoH/UDP/system 解析链；此迁移不修改 Zig 下载内核、runtime 或解析行为。

| 原文件 | 原调用与依赖 | 新职责与入口 |
|---|---|---|
| `fastnet-install.sh` | 独立 bootstrap，直接调用 FastNet 业务函数；zsetup 下载 version.txt 与二进制；不调用 DDNSTO | `apps/fastnet/business.sh` +共享 bootstrap，生成 `apps/fastnet/install.sh`；旧文件名为别名 |
| `install_ddnsto.sh` | 完整 OpenWrt opkg/apk，内存选择 Lite/Standard，远程 VERSION/VERSION_LITE，架构包、LuCI/语言包；旧 curl/wget 使用 HTTP/忽略 TLS；生成升级脚本，start-stop-daemon 执行后等待，uci/token/service | `apps/ddnsto/business.sh` 的 OpenWrt 函数保留业务选择/包安装/配置；使用 zsetup 下载和摘要，前台报告实际失败；后台统一交给 zsetup install/run；不再产生第二份业务脚本 |
| `install_ddnsto_business.sh` | 独立较早的 zsetup 集成；只支持 opkg，三包下载，无摘要，生成后台升级脚本；不是完整 OpenWrt 脚本的辅助依赖 | 合并到同一 DDNSTO 入口，废除重复包安装实现；旧名称别名；新默认前台，后台使用现有命令协议 |
| `install_ddnsto_linux.sh` | 独立脚本，fw0 HTTPS/跳过 TLS，tar/临时目录，交互 token、sudo、stop/mv/daemon；不调用 setup_ddnsto | 同一 DDNSTO Linux 函数，版本默认 4.2.3、两架构；先校验/解包后停止服务；失败尝试恢复旧二进制；支持非交互 --token |
| `setup_ddnsto.sh` | 下载并执行线上 OpenWrt install_ddnsto.sh，再写 uci/token/restart、pgrep、ddnsto -w；曾未传 token 给安装脚本 | 同一入口的文件名适配器，`setup_ddnsto.sh TOKEN` 转成 `--token TOKEN --verify-status`；不再二次取自身/另一安装脚本 |

没有其他本地辅助文件。源仓库五个脚本都保留原字节，未修改线上入口。根目录五个同名入口都落到新代码；发布兼容 URL 的字节等于唯一 DDNSTO install.sh。`sh setup_ddnsto.sh TOKEN` 的文件名适配保留；把旧 setup 内容当 `sh -c` 字符串执行时无法保留文件名，应改用公开 `--token --verify-status` 参数。

测试盘点：`fastnet_bootstrap_test.py`、`fastnet_zsetup_test.py` 原样迁入，仅修改目标路径，迁移前通过；`test_zsetup_integration.sh` 在源 HEAD 已失败，因为断言历史硬编码 zsetup digest/launcher 内容，但 install_ddnsto.sh 实际没有这些内容。迁移后保留测试名称，改为执行真实 zsetup + HTTPS fixture 的 DDNSTO 行为测试。没有把原失败测试标为通过。

依赖：首次 zsetup bootstrap 需要 curl/wget；系统 SHA256 工具仅可选附加校验。后续下载不依赖这些程序。FastNet 需要基础 POSIX 工具并启动自己的菜单。DDNSTO OpenWrt 需要 opkg/apk、awk/tr、uci（传 token 时）、init 脚本、pgrep（请求状态检查时）；Linux 需要 tar、基础文件工具、root 或 sudo（目标目录不可写时）。首次脚本获取和安装权限不能凭空消除。

公网只读检查：`https://fw.koolcenter.com/binary/ddnsto/openwrt/VERSION` 返回 4.2.6；同目录 SHA256SUMS 与 `ddnsto/linux-binary/SHA256SUMS` 返回 HTTP 404。2026-10-08 复核旧脚本的实际产物路径均可取得；用户明确要求延续已有来源，现已通过 zsetup HTTPS 采集现有产物并计算/记录摘要。没有远端 SHA256SUMS 不表示缺少产物；完整记录见 verification-2026-10-08.md。

执行顺序：盘点 → 迁移及双入口 → 配置/不可变发布包 → AI/扩展文档 → 自检/证据。验收包括 POSIX 语法、原 FastNet 测试、新 DDNSTO 业务矩阵、真实 zsetup install、本地缓存复用、失败前不改业务、临时目录清理、参数/进度、索引与文件 digest/size、可重复打包和不可变冲突拒绝。每个失败项最多三次修复，有证据后才继续。

源旧 `mips` 无条件匹配改成检查 `/bin/sh` ELF 的 EI_DATA（需要 od），确认 little-endian 后才选择 **mipsel**；zsetup 只发布 little-endian ABI，未知/大端 MIPS 不能安全安装。旧任意 `arm`/未知 Linux 的支持声明也不能替代已确认 ABI。此类目标、真实四架构 OpenWrt 安装与公网四站点切换仍需设备/发布验证。

2026-10-08 依赖精简更新：脚本 0.1.2 要求 zsetup >=0.2.4；FastNet/DDNSTO 已去除 awk/sed，业务版本/SHA256 使用 native metadata，总内存使用 native context。上述迁移初期依赖段落中的 awk 描述已被此版本替代。完整证据见 [去除 awk/sed 验证](verification-2026-10-08-no-awk-sed.md)。


2026-10-08 模块目录更新：唯一维护目录改为根 fastnet/、ddnsto/；原 apps/ 已移除。各模块收拢 business/main/install、README 和 tests；DDNSTO 同时拥有 collect-artifacts.py、release.py。共享 lib/scripts、统一 catalog 和跨业务 tests 保留在根目录。旧根文件名继续链接到唯一模块入口，线上 URL 不变；当前脚本版本为 0.1.3，native 复用 0.2.4。此前盘点中的 apps/... 与旧 tests/... 是历史路径，当前命令见各模块 README。
