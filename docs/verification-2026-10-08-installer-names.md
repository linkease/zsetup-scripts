# 业务安装入口命名验证

日期：2026-10-08。用户建议统一使用 fastnet/fastnet-install.sh、ddnsto/ddnsto-install.sh；当前规范为 APP/APP-install.sh。开始时 zsetup-scripts HEAD 为 f1e4a8a，工作区干净。

## 变更

- 每个模块仅维护一个带业务名的生成入口，不保留模块内 install.sh 别名。生成器、catalog、测试、用户/AI 文档与新增业务约定同步更新。
- 索引使用 APP/0.1.4/APP-install.sh，config_version 为 scripts-0.1.4。DDNSTO 用法提示及维护注释同步新文件名；native 仍为 0.2.4，业务安装函数及 bootstrap/download/context/run/install 协议保持原行为。
- 公共发布入口采用 /binary/APP/APP-install.sh；原 /binary/APP/install.sh 及 DDNSTO 历史 URL 为当前脚本的同字节副本。兼容副本只在打包时生成，不重复维护代码。
- 打包延续旧 install.sh 和新 APP-install.sh 两种不可变历史路径，拒绝同路径字节冲突。legacy 快照及源业务仓库保持原字节，不进入索引或发布包。
- 产品仍由业务发布流程提前部署服务器，本仓库不采集或打包产品。权威 zsetup 文档同步新命名，不改动 native 代码或网络策略。

## 验证

先提交行为测试，旧布局失败于 missing fastnet/fastnet-install.sh，记录在 dist/evidence/2026-10-08-installer-names/layout-red.log。

实施后执行：

```sh
sh scripts/check.sh /projects/workspace-linkease-ubuntu/linkease-vpn/linkease-tunnel/zsetup
```

全部通过：POSIX shell 语法、生成入口一致性、规范路径与无旧维护入口、legacy 快照摘要、FastNet bootstrap/双模式/参数/缓存/进度、DDNSTO direct/index 与 opkg/apk 四架构/Linux/token/Lite/Standard/缓存/进度/失败回收/setup 旧文件名兼容、索引与发布文件 SHA256/size/路径一致、公开兼容文件字节一致、旧/新命名不可变历史保留、确定性打包、不可变冲突拒绝、暂存回收、无 legacy/产品文件进入发布包。完整日志位于 dist/evidence/2026-10-08-installer-names/check.log。

没有真实安装、服务修改或公网发布。原源业务仓库未改动，linkease-tunnel 中用户已有 SocksTun-iOS 子模块改动保留。
