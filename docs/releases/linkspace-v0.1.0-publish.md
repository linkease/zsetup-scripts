# Linkspace v0.1.0 发布记录

2026-10-26 UTC 已发布。产品版本 v0.1.0，安装器独立版本 0.1.0。
本轮由用户明确授权发布 linkspace 二进制、元数据、安装入口及共享索引中的本应用记录。
源码归 apptunnel/cmd/linkspace，业务安装维护源归 zsetup-scripts/linkspace。
原有未提交内容未被纳入提交；聚合 sdkapptunnel 的其他子模块修改保留。

```sh
sh -c "$(curl -fsSL https://fw.koolcenter.com/binary/linkspace/linkspace-install.sh)" linkspace version
zsetup install linkspace --foreground -- version
~/.local/bin/linkspace serve
```

用户级持久目录为 ~/.local/lib/linkease/linkspace，命令入口为 ~/.local/bin/linkspace。
没有注册或修改宿主/发布服务器的业务服务。业务参数与退出码原样传递；缓存通过
canonical zsetup 的 SHA256/size 校验，保留 current/previous，失败或取消清理暂存和锁。

| Linux 产物 | 字节数 | SHA256 |
| --- | ---: | --- |
| amd64 | 18280632 | ce5f57bf9460c1e3a3e7dfed6a57d992877e854a544e4ecc635c5456fd47ed67 |
| arm64 | 16777400 | 75676b377544b18d857d771106f6c5cac4c504e976200a87555cae3410ef25e2 |
| armv7 | 17105080 | 08679b01e6790b87ebd9722df5b762275168aa77c70e1c367d00ebd1d87a3a0f |

全部三裸程序、三归档、校验和、版本元数据、来源清单、安装入口及完整索引的逐文件
大小、SHA256、架构、来源提交和公开回读见 [机器证据](linkspace-v0.1.0-publish.json)。
二进制来源提交 c968f01e190606bb7ba9589f75c56644c141b9be；安装器来源提交
0d7997c036d1bb600a44aa290026b4c71768bdde。测试与实现已分开提交。
共享 helper 支持改动导致其他业务生成文件在本地同步，但没有发布其新字节或修改其线上索引。

构建沿用项目既有 Linux amd64/arm64/armv7 静态流程，Go 1.25.12、CGO_ENABLED=0，
统一 SSD 缓存入口，保留 GOPROXY=off/GOSUMDB=off 及现有本地工作区解析。
参与实际 linkspace 构建的本地 sdklib/fastcdc/sio 提交干净，记录在公开 release-manifest.json。
没有沿用 FastNet 产品版本或增加 MIPS/桌面产物，也没有升级 zsetup/runtime。

实际通过的检查：Go 测试 74 个包；发布元数据/不可变与回滚 3 项回归；独立应用发布
16 项回归；完整 scripts/check.sh（生成一致性、业务回归、隔离存储/包管理器、聚合打包
可重复性/历史保留）；正式 amd64 程序 104 项命令帮助、交互、搜索/快照/备份恢复合同。
安装 fixture 覆盖字面参数、退出码、缓存同长度损坏修复、版本冲突、下载失败/取消与清理。

发布先暂存不可变二进制，四源 40 项回读后原子切换 version.txt；再暂存不可变安装器，
四源回读后在隔离 Ubuntu 容器用真实公开产品与候选索引验收。UID1000、只读根、无
capabilities、独立临时卷，无宿主服务操作。验收通过后持共享发布锁复核完整线上配置
与入口基线，原子替换入口、最后替换完整索引。切换后 12 项指针及 56 项最终公开文件
回读通过，并在另一全新容器使用公开固定入口和实际云端索引再次完成自举/安装、
精确 v0.1.0、默认持久路径、SHA 缓存复用、参数/退出码、localhost Web HTTP 及 TERM 验收。
容器和卷已删除。首次发布时 ARM64/ARMv7 仅完成交叉构建和静态检查；ARM64 后续真机验收见下文。

首次不可变文件回读曾全部404，文件权限与源站摘要正常，后续不改服务器配置/服务即
恢复可见并通过全字节校验；根因未确定，逐URL失败记录保留。前两次候选容器失败发生在
测试驱动对版本 JSON 的解析：安装前版本检查和 --json 结果分别使用裸对象/结果信封。
修正并用真实二进制校验驱动后第三次通过；正式产品/安装器字节没有为此改变。

服务器根为 /mnt/sata3-1/istore-data/public_html/binary，仅更新下列公开文件：

- linkspace/v0.1.0/ 下三个裸程序、三个 .tar.gz、SHA256SUMS、PUBLICATION-SHA256SUMS、version.txt、release-manifest.json。
- linkspace/version.txt。
- linkspace/0.1.0/linkspace-install.sh 与 linkspace/linkspace-install.sh。
- zsetup/config.json：仅新增本应用21条 Linux 发行版/三架构记录和 config_version，脚本 SHA256/size 来自实际字节，min_version 精确为实际 stable 0.5.1。

原有其他应用记录、source_groups、stable_zsetup 全部保留，其他1,251份原有文件的路径、
大小、mtime、权限一致；7项关键文件 SHA256 一致。Windows/macOS 指针及核心没有改变。
上传临时目录 /tmp/linkspace-publish-20261025 已清理，不使用或上传完整多业务 aggregate 包。

回滚使用本仓库 [可执行脚本](rollback-linkspace-v0.1.0.sh)：

```sh
sh docs/releases/rollback-linkspace-v0.1.0.sh
```

脚本持发布锁，核对本次索引/入口/产品指针摘要与 stable，拒绝覆盖后续发布；先恢复
安装入口和完整配置，再移除首次发布的产品版本指针。不可变程序/安装器始终保留。
实际快照位于 binary/linkspace/.binary-rollback-v0.1.0/ 和
binary/linkspace/.installer-rollback-d8839c8dc1efd18a4017962b81caa5addb0cdc294d5bfc540b25c545765731ed/。
精确正式包组合回滚和可执行回滚脚本均在独立沙箱执行成功，未为测试回滚生产。

原始证据在 dist/linkspace-20261025/，包括线上完整基线、前后清单、测试完整日志、失败
记录、逐URL校验、实际命令、容器报告、正式独立包、回滚快照归档和 EVIDENCE-SHA256SUMS。
正式产品另保存在 apptunnel/bin/linkspace-release/v0.1.0/；完整索引与快照摘要已纳入机器证据。
ARMv7 真实设备尚未验证；Windows/macOS 按用户要求留待后续，MIPS 不在发布矩阵。

2026-10-26 后续 ARM64 真机验收已通过，证据见 [ARM64 原生报告](linkspace-v0.1.0-arm64-native.json)。
目标 root@192.168.30.93，iStoreOS24.10.8 / Linux6.6.144 / aarch64（rockchip/armv8）。
从实际公开 HTTPS 获取安装器，在独立 NVMe 目录和隔离 HOME 中直接执行，未使用 QEMU
或以容器结果替代设备进程；设备原本没有 zsetup，本次成功冷自举0.5.1并经真实云端索引
安装正式 linkspace v0.1.0。16777400字节与已发布 ARM64 SHA256 完全匹配；缓存报告
source_tier=cache、attempts=0，安装前后文件 inode/mtime/size 不变。

实际通过104项离线 JSON 帮助、业务参数/退出码2传递、搜索建库与查询、容量快照构建、
空间不足失败后旧 generation 保留、备份/逐字节恢复、源文件不变、localhost Web HTTP
及 TERM/join/stopped 事件。暂存目录为空，测试目录已删除；既有预览 Linkspace PID5252
的 exe/starttime、系统业务入口和现有容器清单前后一致。没有修改或重启真实业务服务，
没有改动固件根目录中的系统命令或正式用户安装，也没有为验收填满磁盘。

仅增加仓库验收记录，不重写线上不可变 v0.1.0 产物或 release-manifest；原始发布时的
验证描述作为历史保留。原始命令、stdout/stderr、设备事实、前后保护清单、驱动与校验和
位于 dist/linkspace-arm64-20261026/。Windows/macOS 按用户要求后续再验证。
