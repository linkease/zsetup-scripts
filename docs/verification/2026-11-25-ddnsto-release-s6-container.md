# DDNSTO 0.3.3：s6-overlay 容器适配

> 已被用户后续决定替代：0.3.3 尚未发布，现改为通用非 systemd 后台进程模式。
> 本文只保留先前实验的历史证据，不是当前实现或发布说明；见同日 process-linux 发布记录。

状态：本地候选，本机安装及维护验证通过；未提交、未推送、未发布。

## 范围与授权

- 用户允许使用当前 Linux 容器测试，明确不新增专用挂载、不保证容器重建后恢复。
- 只适配运行 s6-overlay 的 Docker 容器；不把任意非 systemd 系统判为支持。
- 客户端继续采用平台配置中的 Linux 4.2.8，包和摘要不变。
- 不修改 zsetup 核心、不改其他设备/服务器、不停止工作区已有 tmux 开发进程。
- 独立目录 `/opt/linkease/ddnsto-s6`，独立服务 `ddnsto-zsetup`，不接管未知历史安装。
- 容器可写层可用，不宣称持久化；只在此适配器内允许 native 返回 overlay/unknown。
  只读、noexec、root 所有权、空间和 inode 检查仍保留，其他安装器策略不变。
- 普通用户复用现有校验复制 sudo 协调器；配置和启动脚本仅由 root 修改。
- `/etc/services.d` 定义由 s6-overlay legacy-services 启动阶段加载；运行时使用独立监督目录。
  不重启整个容器或 s6，重建后需重新安装。

## 本地验证

测试先行：新增识别、存储、归属、账号、事务恢复与生成器用例，确认失败后实现。
新增 s6 专项测试 22 项通过。提供 `DDNSTO_TEST_NATIVE` 后，
全体 `ddnsto*test.py` 共 169 项，141 通过，28 跳过；
跳过涉及未配置的原生/隔离平台环境和旧 Shell，不能当作所有平台验收通过。
构建与产品配置检查通过，标准入口测试 5 项通过；Shell 兼容测试主机 sh/Bash POSIX 通过，
实际 Bash 4.2 两项未提供解释器而跳过。
`sh scripts/check.sh --native-bin /tmp/zsetup/rescue/0.6.4/zsetup` 执行到
`privilege_bridge_test.py` 时因容器禁止 `unshare` 写 `/proc/self/uid_map` 而停止；
此前的公开树、发布事务、迁移、平台入口、边界/事务测试已执行通过，
后续未执行项不能视为通过。跨应用完整门禁尚未完成。
原生源码与整体 native 打包检查按 `--native-bin` 模式未执行；未修改核心源码。

## 本机结果（Ubuntu 24.04.1 x86_64 / s6-overlay 3.2.0.2）

使用本地生成的 `apps/ddnsto/versions/0.3.3/install.sh`，以普通用户 abc 执行，
自动走已校验复制的 sudo 提权。zsetup 0.6.4 及客户端包使用正式来源；
客户端归档摘要为平台配置的 `3bf7ada14448b5aa04afa171e497f85d0b8bb4adcf2209991e52ef5826d4e975`。
这不是正式域名的新版安装验收；正式入口没有被本轮修改。

| 场景 | 结果 |
| --- | --- |
| 独立目录新装 4.2.8 | 退出 0；s6 PID 2394206，稳定运行 |
| 同版本重复 ensure | 退出 0；PID 仍为 2394206，没有重启 |
| stop 后重新 ensure | 先确认 down，再退出 0；新 PID 2404129 |
| restart / status | 均退出 0；status 报告 local_service=running |
| 进程被终止后自动恢复 | 只终止受管理进程；旧 PID 2407392 → 新 PID 2410752，稳定 5 秒 |
| 独立服务运行目录重建 | stop/detach 后移走该服务 runtime，通过 start 重建并稳定运行；PID 2506467 |
| 配置与设备身份 | 启停、重复安装和重启前后 SHA-256 均一致 |
| 原有开发进程 | PID 1596957 保留；未删除 /tmp 中的旧锁文件 |

成功诊断：`/tmp/ddnsto-result.5OLw6O/events.log`、`DHhQUT/events.log`、`1cSSTI/events.log`、
`QiPzlI/events.log`。最终复验客户端为 4.2.8，原开发进程 PID 1596957 未变。
配置摘要：`aa79a44bc9c755faf49c1b0d54ff2861002a7a84be0dd126c41aa53950ca6a37`。
设备身份摘要：`ba5d0d5555011a0f08414402ff2e240b97b8aa22817482a9d11502e41e5da2cb`。

未执行整个工作容器的重启/重建、真实跨版本升级、云端在线验收；失败恢复使用隔离测试。
configure/uninstall 尚未支持，会明确拒绝。失败中断导致残留安装目录时保留证据，要求人工检查，
不把未知目录当作空白安装自动覆盖。

## 开发中发现的兼容问题

- DDNSTO 私有提权程序原先缺少最终调度调用；现在实际调用业务安装，不再仅定义函数返回成功。
- 原生 0.6.4 将空的 `ZSETUP_CA_FILE` 当作文件路径，返回误导性的写入错误；提权程序只在空值时 unset，保留显式 CA。
- 生成器逐行删注释会破坏嵌入 heredoc 的服务 shebang；现在保留原文。
- 客户端默认 /tmp 单实例锁与已有开发进程冲突；新服务使用 root 私有 TMPDIR，不修改旧锁。
- s6 的 up 先于启动 wrapper exec 客户端；等待实际可执行文件就位，再验证同一 PID 连续运行 5 秒。

以上问题均增加对应回归检查，未修改 zsetup 核心或客户端二进制。

## 收尾

本机保留已安装且运行的 `ddnsto-zsetup`，没有新增挂载。清理本轮临时下载包与失败安装副本，
保留脱敏诊断日志和本机 `/tmp/ddnsto-s6-tests-final.log`、`/tmp/ddnsto-s6-check.log`。
安装器生成结果、指南和版本清单一致，旧 0.3.2 不可变脚本没有改动。

## 发布与回滚

新不可变安装器版本 0.3.3，保留 0.3.2 原字节。正式发布须另行授权。
本次不修改现有推荐客户端版本。发布前仍需标准构建、回归及公开入口核验。
