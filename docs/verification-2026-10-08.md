# 2026-10-08 沿用 DDNSTO 既有产物的验证记录

用户明确指出产物已经存在，要求参考旧一键安装脚本继续。本次已纠正此前将远端缺少 SHA256SUMS 误作产物阻塞的判断：旧脚本的 URL/版本/包名继续作为业务来源，通过现有 zsetup 下载真实字节，再自动生成发布摘要，无须用户另行提供清单。

## 已完成

- 复核 `ddnsto_all_in_one_script@13bfb75`：OpenWrt 主包在 Lite/Standard（ipk/apk 各自目录），LuCI/语言包在 OpenWrt 根目录；Linux 默认 archive 为 4.2.3、支持 x86_64/AArch64。这些选择保持不变。
- 现有 CDN 返回 Standard VERSION **4.2.6**、Lite VERSION_LITE **4.2.2**，全部 16 个架构主包、4 个根目录 LuCI/语言包、Linux archive 均可取得。
- 新增 `scripts/collect-ddnsto-artifacts.py`：全部网络下载执行现有 `zsetup download`，保留三个 HTTPS primary 与 fw.koolcenter.com final fallback；没有新下载器、运行时复制或 HTTP 降级。
- 实际执行 23 次下载，输出 27 个发布文件，总字节 **55,004,577**。所有实际下载日志的 Winner 为 **fw20.koolcenter.com**，没有进入 fallback。根目录 UI/语言包只下载一次，在各不可变业务版本目录保存其同字节副本。
- 生成 artifacts.json（27 个真实摘要）和 acquisition.json（来源 URL 组、时间、版本、大小与摘要）。已将精简完整清单提交为 [ddnsto-artifacts-2026-10-08.json](ddnsto-artifacts-2026-10-08.json)，未来无需依赖本地 dist 仍可核对来源及字节。
- `package-release.py --collect-ddnsto` 将采集接入一条维护者构建命令；已有目录可用 `--ddnsto-artifacts` 复用。公网未提供 SHA256SUMS 不再是采集前置条件。打包仍核对采集结果，生成 5 个业务 SHA256SUMS，并保持同版本目录不可变。
- 原 FastNet/DDNSTO 安装入口字节未修改，业务路径与 config_version 继续是 `0.1.1` / `scripts-0.1.1`；zsetup exact stable/min_version 继续是 **0.2.3**，复用原四架构 release，不改变 Race 或 DoH/UDP 行为。

## 验证

`sh scripts/check.sh /projects/workspace-linkease-ubuntu/linkease-vpn/linkease-tunnel/zsetup` 返回 **0**，包括 POSIX 语法、FastNet 原双入口测试、DDNSTO 双入口/平台/cache/参数/错误清理、包一致性与新采集测试。

采集测试验证旧路径与版本、27 文件摘要、三个 primary/最终 fallback、UI 从根目录复制、失败时保留旧目录且回收 staging、同版本字节变化拒绝覆盖，并验证一条命令组合采集与原配置生成器。没有失败项超过三次优化。

真实产物离线检查：8 个 ipk 的 control 中 Package 为 ddnsto，版本分别为 4.2.6/4.2.2，对应旧架构后缀；apk 的文件头为 `41444264`。Linux archive 的两架构成员均为普通文件，原 archive 内 JSON 记录的 hash 与二进制实算 SHA256 相同：

| 架构 | 原 archive 内 JSON 与实算 SHA256 |
|---|---|
| x86_64 | `5f152c691e0acd75055bd65ecfa51a1ac5b4bc8d79908860e6192116f33c9a0e` |
| aarch64 | `57457b72f6f2cdae35dc06e5f58f11840c494b6690735e99f064c3ff0b40bcf6` |

在干净源码提交后执行：

```sh
python3 -B scripts/package-release.py \
  --zsetup-root /projects/workspace-linkease-ubuntu/linkease-vpn/linkease-tunnel/zsetup \
  --ddnsto-artifacts dist/ddnsto-artifacts \
  --require-production-ready
```

返回 0，manifest 为 **artifacts-verified-canary-required**，相关脚本与 zsetup 源码树 dirty 标志均为 false。全部 PACKAGE-SHA256SUMS、5 个 DDNSTO 摘要文件、25 个 installer record 的 path/hash/size，以及 4 个 zsetup Artifact 一致性均通过。

## 产物与提交

- 业务代码/发布工具提交：`386be3bf316ff3769780c8f2b528be3e5173b641`；新增行为测试有独立先行提交。
- zsetup 配置工具复用上轮 `33c8179`，源业务仓库仍为 `13bfb75`，本轮未修改这两个仓库；用户已有 SocksTun-iOS 改动保留。
- 本地采集：`dist/ddnsto-artifacts/`；完整候选：`dist/release/`，均为可再生产物，不提交二进制。
- Linux archive：16,265,464 字节，SHA256 `b982ebd38e8c145d955049eb5b73960c01941bc05f084c3a2115dfca2b6eea6e`。
- 完整传输包：`dist/release/zsetup-scripts-scripts-0.1.1.tar.gz`，57,297,942 字节，SHA256 `b7940505121c6020f210a981a37d37adaf0055bb1de6b0b2cd66ae073e2c2be9`。

没有执行实际 DDNSTO 安装、修改宿主服务、上传公网或替换线上入口。本地完整候选已经具备真实业务产物；设备 canary 和具体公网切换仍按既有发布步骤进行，不能把隔离测试等同于真实设备上线。fastpve 的待接入状态不变。
