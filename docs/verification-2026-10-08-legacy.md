# 历史脚本归档验证

日期：2026-10-08。用户要求旧脚本放在 legacy/ 供未来参考，不放根目录。开始时 zsetup-scripts 为 aa5613e，工作区干净。

根目录五个文件原为当前安装入口的符号链接，没有保存原始实现。现移除根目录别名，在 legacy/ 保存源仓库 ddnsto_all_in_one_script@13bfb7580416487fda17d3d93d72bf6d25eb9800 的五份实际源码。归档来源、职责、SHA256 和当前入口见 legacy/README.md。源仓库不改动，线上入口不改动。

维护源码 fastnet/、ddnsto/、共享 bootstrap、生成安装入口和 catalog 没有字节变化，脚本版本仍为 0.1.3/native 0.2.4。legacy 不参与构建、索引或发布；仅做语法和摘要验证，不执行历史业务。服务器兼容 URL 仍由当前 ddnsto/install.sh 生成。旧 setup TOKEN 适配测试改为在隔离目录保存当前安装入口的同字节兼容文件，保持对发布行为的验证。

先提交行为测试，原布局失败于“legacy names must not occupy the root”，见 dist/evidence/2026-10-08-legacy/layout-red.log。实施后执行：

```sh
sh scripts/check.sh /projects/workspace-linkease-ubuntu/linkease-vpn/linkease-tunnel/zsetup
```

通过：五份快照 SHA256、无根目录旧入口、POSIX shell 语法（包含 legacy）、生成入口一致性、FastNet bootstrap/安装/参数/缓存/进度、DDNSTO direct/index 与平台/包管理器/架构/token/Lite/Standard/缓存/进度/失败回收、当前 setup 文件名兼容行为、配置/发布文件 size/SHA256/路径一致、确定性重建、不可变冲突和失败回收、公开文件及 tar 无 legacy。完整日志见 dist/evidence/2026-10-08-legacy/check.log。

没有真实安装、服务变更、公网发布或产品采集。
