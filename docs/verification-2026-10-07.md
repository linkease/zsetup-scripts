# 2026-10-07 迁移验证证据

结论：统一仓库的本地迁移、配置接入与隔离验收通过；DDNSTO 公网切换尚未完成。**产物部分的当时阻塞判断已由用户纠正，并在 2026-10-08 通过既有 CDN 实际采集消除，见 verification-2026-10-08.md。**没有安装真实业务包、修改宿主服务、上传公网或推送 Git。

## 仓库与提交

| 仓库 | 开始状态 | 本次变更 |
|---|---|---|
| `linkease-github/zsetup-scripts` | `deef63b`，干净、只有简短 README | `d323f39` 统一入口/业务/发布工具；`9b457e1` 标准化源码边界并递增不可变业务路径为 0.1.1；测试有独立提交；本证据另行提交 |
| `linkease-tunnel` 的 `zsetup/` | `ee0f11a`，zsetup 干净；用户已有 SocksTun-iOS 改动 | `d3f9bfe` 目录清单测试；`33c8179` 扩展既有配置生成器和发布文档；未改 Zig/runtime 源码 |
| `ddnsto_all_in_one_script` | `13bfb75`，干净 | 五个源脚本与所有源测试保留原字节，Git 状态仍干净 |

用户已有 SocksTun-iOS 改动全程保留，未暂存或提交。业务文件名别名与源功能归属详见 inventory.md；没有 fastpve 实现或索引记录。

## 已通过的检查

| 命令/测试 | 证据与边界 |
|---|---|
| `python3 -B scripts/build-entrypoints.py --check`；全部根入口、apps/lib/scripts/tests 的 `sh -n` | 生成文件匹配维护源码，POSIX shell 语法通过；最终提交内容无 diff whitespace 错误 |
| `tests/fastnet_bootstrap_test.py` | HTTPS、精确版本复用、无系统 SHA 工具、坏 metadata 换源、摘要错误、明确 HTTP 拒绝/确认、四阶段输出；新增旧于 0.2.3 拒绝与临时文件清理 |
| `tests/fastnet_zsetup_test.py`，真实 0.2.3 executable + 本地 HTTPS | installer mode、内置 digest 校验、metadata no-cache、参数透传、重复缓存命中不再请求业务二进制；curl/wget trap 未触发 |
| `tests/test_zsetup_integration.sh` → `tests/ddnsto_test.py` | 真实 zsetup download/install + 本地 HTTPS；Linux 直接脚本/索引入口；OpenWrt opkg/apk × x86_64/aarch64/armv7/mipsel 业务分支；Lite/Standard、含空格 token、旧 setup 文件名适配、cache 命中、业务阶段输出 |
| DDNSTO 故障矩阵 | 缺参数/非法平台返回 2；digest mismatch 在包管理变更前失败；包管理器错误 23、启动错误 24、停止错误 25 透传；启动错误恢复旧二进制；SIGTERM 返回 143；transaction/candidate/可清理 backup 均无残留 |
| `tests/package_test.py` | 真实 zsetup 解析生成配置并列出 fastnet/ddnsto；索引 selectors、immutable path、SHA256/size 与文件一致；两次完整 tar 字节相同；改变已生成同版本文件会拒绝打包，旧 config 保持不变 |
| `tests/artifact_package_test.py` | 使用明确标注禁止生产发布的隔离 fixture，覆盖四套 OpenWrt 六包与 Linux 两架构 tar；确认输入 digest 后生成 metadata；坏 digest/缺架构包拒绝且暂存回收 |
| zsetup `tests/scripts_catalog_test.py` | 通用 catalog 与原配置协议一致；真实脚本 hash/min_version；路径穿越、重复 selector 拒绝且不覆盖有效配置 |
| zsetup `tests/s6_staging_test.py apps/fastnet/install.sh` | 原 `--fastnet-script` 构建流程回归通过，保留旧 S6 调用兼容性 |
| zsetup `scripts/run-target-smoke.sh --all` | 既有四目标 x86_64/aarch64/armv7/mipsel QEMU 网络、安全、输出与退出矩阵通过 |
| `dist/release/PACKAGE-SHA256SUMS` | 所有包内业务脚本、兼容入口、四架构 zsetup、配置/指针和 manifest 校验通过；新版配置 install --list 输出 fastnet、ddnsto |

联合命令：`sh scripts/check.sh /projects/workspace-linkease-ubuntu/linkease-vpn/linkease-tunnel/zsetup` 最终返回 0。随后只有源码空行标准化/不可变目录版本递增与文档记录；重新执行 entrypoint check、所有 sh -n、package 测试和实际暂存包 digest/index 检查均通过，业务函数未变。

测试使用模拟包管理器、uci/服务以及临时 Linux 安装路径；OpenWrt 矩阵是业务选择和命令协议验证，不是四架构真实 ipk/apk 安装证明。QEMU 验证的是既有 zsetup executable。未修改 native owner/task/fd/Race/DNS，因此不把这些 shell 测试冒称为新的 Zig 生命周期 1000 次 Gate。

## 修复与失败记录

1. 源 DDNSTO 测试在迁移前就失败：断言历史 hard-coded launcher 内容，而当前源码不存在这些内容。保留名称，替换为当前真实行为的隔离测试。
2. 第一轮 DDNSTO cache 请求计数失败：zsetup `--no-cache` 只处理网络头，不提供本地业务 cache。业务层改为校验提交后才写 digest/size marker，再验证复用；一次实现修复后该项通过。
3. 在较早的 DDNSTO 长测试期间重新生成了脚本，shell 读取中的文件被原地改写，出现无效 `setup_token` 错误。确认不是业务分支错误后，生成器改用临时文件 + atomic replace；后续测试不再改写运行中的 inode。
4. 新 bootstrap 残留断言暴露源 `unlink` 多参数调用错误。改成 POSIX `rm -f`，最小工具 fixture 加入 rm；一次修复后摘要失败路径临时文件回到零。
5. 停止服务失败的 backup 清理与信号退出有确定性检查；Linux replacement 由同一个 EXIT cleanup 执行必要恢复，失败恢复时保留不可安全删除的 backup 并给出路径。没有失败项超过三次优化后继续掩盖。

## 暂存产物

目录：`/projects/workspace-linkease-ubuntu/linkease-github/zsetup-scripts/dist/release`（可再生，Git 忽略）。配置 `scripts-0.1.1`；zsetup exact stable/min_version `0.2.3`；三个 HTTPS primary + fw.koolcenter.com final fallback 未变。

此暂存绑定业务代码 commit `9b457e14553cabf33ddfb7adfd679ada5fb59bf3` 与配置工具 commit `33c8179a028dd1b262f79583f01d3ee7c537b5ad`，生成时两个相关源码树都干净。zsetup 原始 release-manifest 的 build source_commit 为 `fc6309882b2f35b8efd4eafe21e9986ef1fe3e04`，不是声称在本次工具 commit 重新编译了 0.2.3。

| 安装脚本 | 字节 | SHA256 |
|---|---:|---|
| `fastnet/0.1.1/install.sh` | 11405 | `a49c49fd4967c90eea2e4272c12ab375975962cb106181fca9a339676297ecb8` |
| `ddnsto/0.1.1/install.sh` | 22065 | `0a0d51dc24de04e6bf4eb5efab58e85c39412e0a6a54d74b759f412e36c158da` |

传输包 `zsetup-scripts-scripts-0.1.1.tar.gz` SHA256：`d9625852a8619683339c19b75a86e2cb2af3dafead6540f141c3178b4ad313a1`。已生成的 0.1.0 开发快照在此本地树中保留，不覆写其 immutable 文件。

## 未完成的生产验收

- 公网只读检查：DDNSTO OpenWrt VERSION 为 4.2.6，但检查的 OpenWrt 根目录和 Linux 目录 SHA256SUMS 都是 HTTP 404。尚无业务方提供的 approved artifacts.json/产物路径。开发包 manifest 因此标记 `development-ddnsto-artifacts-required`，不是完整可上线的 DDNSTO 安装包。
- 补齐所需产物/真实摘要后，用 `--ddnsto-artifacts DIR --require-production-ready` 构建候选；工具拒绝缺项、digest mismatch、dirty source 与 immutable conflict。还需真实设备双入口 canary、四站点内容/摘要一致性、指针切换/回滚和观察窗口。
- 未授权具体公网发布目标或真实业务安装环境，未上传、未切换 config/stable、未删除源脚本。原 zsetup upload 工具只处理 S6 FastNet，不能直接用于新布局；运维步骤见 release.md。
- fastpve 未接入；没有虚构安装函数。输入清单在 extension.md。
