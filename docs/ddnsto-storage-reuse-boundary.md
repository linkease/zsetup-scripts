# DDNSTO 存储与权限复用取舍（A05）

核验日期：2026-11-16。对象为固定核心 0.5.0、候选 0.6.4 和当前维护源。
本项交付是逐规则映射，不以删代码数量作为完成条件。不升级核心、不修改其源码。

| 现有规则 | 核心对应能力 | 当前决定 |
| --- | --- | --- |
| Linux 持久存储、只读、noexec、可写、剩余字节/inode | storage 的对应字段 | 已由 lib/install-storage.sh 复用，保留未知值拒绝和业务空间预算 |
| 下载/捕获时空间保留 | download/capture --min-free-bytes | 已复用，不再另造通用探测器；8 MiB 保留不替代整体安装峰值预算 |
| 首次执行核心前的目录和核心文件保护 | 核心尚未可信，不能调用它证明自身安全 | 保留 bootstrap 检查，不能提前执行 --version/storage/checksum |
| 文件 UID、完整 mode、硬链接数、类型 | storage 的 effective_uid/private_directory 不是这些字段 | 保留 portable-files 的 stat/受限 ls；不恢复 stat 硬依赖 |
| 逐层祖先目录、符号链接、ACL/特殊权限拒绝 | 未证明布尔目录结果与整套规则等价 | 保留；不能把目录可写当作来源可信 |
| 华硕 /jffs 挂载来源、子挂载、绑定挂载与固定可信边界 | storage 可读一般挂载事实，但不表达此业务许可策略 | 保留 asus-storage 的挂载和路径规则，禁止扩大到任意可写父目录 |
| 华硕随机私有目录与排他 mkdir | storage 只探测，不负责本业务的占用、重试和清理 | 保留；armsoft 不能依赖未证实兼容的现代核心 |
| 群晖 root/套件服务用户两种所有者、DSM 管理的 target/var 链接 | effective_uid 是执行者而非文件所有者 | 保留 auto-synology 的路径解析和所有者策略 |
| 群晖执行目录避开 noexec /tmp | 核心启动前必须先有可执行落点 | 保留 /var/lib/ddnsto-installer 的安全准备 |
| Windows/macOS 权限与安装生命周期 | 当前 Linux 发布证明不覆盖桌面平台 | 不作替换；Windows GUI 方向不变 |

## 可复现证据

`ddnsto/tests/native_reuse_contract_test.py` 在两版可信核心上分别验证：

- 0700 工作目录被判为 private，0777 被判为非 private。
- 同一私有目录里的文件可有两个硬链接，同时 private_directory 仍为 true；
  portable-files 能返回链接数 2。因此该布尔值不能替代单链接文件约束。
- capture 在不可能满足的空间保留下拒绝，超时不发布部分输出。

statless 回归继续执行 `tests/ddnsto_portable_files_test.py`。这些证据并不证明
抵抗并发 root 写入或挂载变化；锁和平台事务必须继续保留。

## 解包取舍（A04 当前范围）

Linux 已用固定 0.5.0 capture 包住 tar 的单成员提取。0.6.4 archive 的根目录
提取不能直接等价替换“只提取指定架构”，且要求升级固定核心、重算整体展开预算、
验证所有平台兼容。因此本候选保留 Linux 现状，不添加自动能力探测后静默切换。

现代华硕已将 tar 输出捕获交给可信 0.5.0 capture；业务白名单、元数据和架构
继续校验。armsoft 保留旧实现。原生 archive 的全面迁移暂缓，不将接口存在视为
安全等价。本次 A05 映射已完成；A04 全面迁移、A06 整体验收和阶段二不得标完成。
