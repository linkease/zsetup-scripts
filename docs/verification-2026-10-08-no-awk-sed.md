# 去除 awk/sed 的验证证据

日期：2026-10-08。用户要求 zsetup 自身提供可靠、精简的版本识别和总内存识别。

## 交付

- linkease-tunnel/zsetup：核心实现 `85a731b`，release source_commit `4ab3102b65648ad70a10579d64435ab1364cba4f`（包含四架构新能力 smoke 测试）。新 native 版本 0.2.4。
- zsetup-scripts：测试提交 `3ffeb59`，业务及版本配置实现 `8e21c9292e8d3485720ac7908358fc721e8d4b5a`。新业务脚本 0.1.2 / config_version scripts-0.1.2，25 个安装记录均指向新脚本，min_version/stable/artifacts 均为 0.2.4。
- 源 ddnsto_all_in_one_script 保持 `13bfb75`，没有修改或删除源入口；父仓库已有 SocksTun-iOS 改动保持原状。

业务版本和 SHA256 的读取统一调用 `zsetup metadata`；内存读取 `ZSETUP_MEMORY_TOTAL_MB` 或 `zsetup context get memory_total_mb`。所有维护源码及生成业务入口没有 awk/sed 调用。首个 native 尚不存在时，shell stable 读取仍用既有 read/case；不要求先有 native 才能自举。

总内存采用整数 MiB 的 MemTotal；899 MiB 选 Lite，900 MiB 或未知选 Standard，政策留在 DDNSTO。DDNSTO_MEM_MB 保留为既有测试输入。下载、SHA256 验证、HTTPS、多源 primary/fallback、缓存、参数传递、进度、包管理和失败回收继续使用原有职责。

## 验证

`sh scripts/check.sh /projects/workspace-linkease-ubuntu/linkease-vpn/linkease-tunnel/zsetup` 退出 0，包含：

- 生成入口一致性与全部 POSIX shell 语法检查；
- FastNet 自举 HTTPS、缓存复用、HTTP 明确拒绝/确认；无外部 SHA 工具和无 sed 的最小 PATH；
- 真实 zsetup install FastNet 的元数据、摘要、参数与缓存；
- 真实 DDNSTO direct/install 两入口、opkg/apk × 四架构、Linux、token、899/900/unknown 内存选择、缓存、进度、启动/停止/校验/包安装/信号失败回收；awk/sed 用必失败程序替代；
- 发布包/索引/平台记录/路径/size/SHA256/兼容入口、确定性打包、不可变冲突拒绝；
- 现有业务产物输入验证及 23 次模拟采集形成 27 文件，版本、摘要、不可变快照、打包组合和失败清理通过。

native 完整回归 53/53 步骤、61/61 Zig 测试及相关集成通过，四架构 QEMU 和 ABI/UPX/摘要/体积检查通过；见 linkease-tunnel/zsetup/docs/evidence/2026-10-08-metadata-memory.md。同一进程各 1000 次元数据成功/内容失败/文件缺失保持 fd 基线，FIFO 立即拒绝。新增发布二进制仅增加 1356–3568 字节。

## 候选包

- 文件：`dist/release/zsetup-scripts-scripts-0.1.2.tar.gz`
- 大小：59563822 字节
- SHA256：`f784d71fd7778470fb52cde0aa8eff7ee7da5af7ad73322503c920dd9c0fb6a8`
- readiness：`artifacts-verified-canary-required`；生成时两个源码树均干净。
- 重新逐文件核对 manifest size/SHA256，通过；旧脚本 0.1.0/0.1.1、native 0.2.3 不可变文件仍在候选树中，旧版本没有被新字节覆写。

新 SHA256SUMS、release-manifest、完整 config.json、stable 指针一致。复用已采集验证的现有 DDNSTO 产物，无需重复公网采集；沿用原路径与版本，没有杜撰新安装包。完整检查日志保存在 ignored `dist/evidence/2026-10-08-no-awk-sed/check.log`。

本轮没有真实业务安装、服务修改、设备 canary、公网上传或 Git push。公网仍需按发布文档完成不可变产物先行、完整配置和指针更新。其他依赖（例如 grep/tr/wc/tar/包管理器）保留，避免扩展本次范围。
