# FastNet 独立发布

2026-10-16。用户认可分业务目录发布，首期只处理 FastNet，其他业务线上数据不变。
本次完成本地候选、路径登记和部署事务验证；正式服务器全程只读。

## 任务与验收

1. 登记：复用 catalog.json 的 source/path/selectors，release/applications.json 只补充
   FastNet 的运行时能力底线及公开入口。首期其他 application 未启用，明确拒绝打包。
2. 打包：调用 canonical Rust 配置生成器，读取真实线上完整配置，只替换 FastNet
   installer 记录；其他记录原样保留，不从本地多业务 catalog 批量导入。
   不变更 source_groups、stable_zsetup、stable、Windows/macOS 指针或核心文件。
3. 事务：仅允许 FastNet 不可变脚本、两条固定入口及 Linux 完整配置的明确目标。
   单独 stage，保留入口/配置原字节和权限；HTTPS 回读与 canary 后才可 activate。
   中途失败恢复全部指针，rollback 保留不可变文件，拒绝后续发布之后的乱序回滚。
4. 验收：14项本地发布测试、既有 FastNet bootstrap/install 与 persistent launcher
   回归通过。测试使用临时发布目录、真实 Rust CLI、TLS fixture 和业务替身，未改主机服务。
   业务替身通过不能代替真实 FastNet 发布后 canary。

## 实际线上盘点

服务器资源为 SSH root@192.168.3.1；部署实例的 binary 根目录为
`/mnt/sata3-1/istore-data/public_html/binary/`。连接信息与应用相对路径分开，
没有在脚本内硬编码 SSH 或生产目录。生产资源/编排后续归 ops-fleet；
业务发布逻辑继续归本仓库，不复制到编排层。

| 路径 | 当前字节数 | SHA256 |
|---|---:|---|
| fastnet/fastnet-install.sh | 3494 | 982925b5b9474176b57d64c658102b675d1a6e8a674537f51ebdee4bea9b8072 |
| fastnet/install.sh | 10165 | 21aa238f92e491887e9b7d3e7f2845796891844fce035cf4da4cdb8fe5cbc2a1 |
| fastnet/version.txt | 272 | 541b1b2099d9a9179812d69cd78dfa4cf705594174638b2aaba1b50363a12eaf |
| zsetup/config.json | 1648 | ea0ba7758054395a7be830617834fdc9837181b51bbf4bdd8ed9312bb79df5a5 |

两个 FastNet 入口目前字节不同，线上 Linux 配置只登记 fastnet/install.sh，
stable/config 均为核心0.4.0。FastNet业务产品0.7.6的三个架构实文件摘要与
version.txt 一致。四个公开 HTTPS 站点的 version.txt 回读一致；产品回读另见证据。
本地候选入口为33259字节，SHA256
`cb44ee56ebd967b323737af2ca431e0fbe76f3540a62d2a7259a9a29aa937012`。

## 本地准备

先通过只读 SSH 保存实际线上 config.json，再执行：

```sh
python3 -B scripts/package-app-release.py \
  --application fastnet \
  --live-config /path/to/actual-live-config.json \
  --zsetup-root /path/to/linkease-tunnel/zsetup-rust \
  --native-cli /path/to/verified/zsetup-linux-x86_64 \
  --output /path/to/new-fastnet-review
```

默认只有本地输出，没有远程调用。已有输出一律拒绝覆盖。
原始配置保存在 baseline/，完整候选配置经真实 Rust install --list 验证，
包内所有文件有 PACKAGE-SHA256SUMS；manifest 的 files 是唯一拟写入目标清单：

```text
immutable/fastnet/0.1.8/fastnet-install.sh -> fastnet/0.1.8/fastnet-install.sh
pointers/fastnet/fastnet-install.sh      -> fastnet/fastnet-install.sh
pointers/fastnet/install.sh              -> fastnet/install.sh
pointers/zsetup/config.json              -> zsetup/config.json
```

没有业务产品、version.txt、其他业务脚本或核心产物。发布版基于实时配置构建，
不能把完整多业务 aggregate 包直接覆盖线上。FastNet脚本字节变化必须新建版本；
catalog 中其他业务版本无需跟随改变。

## 低层部署事务合同

`install-app-release.sh stage|activate|rollback PACKAGE BINARY_ROOT` 是供受控部署流程
调用的低层原语，本次仅在临时目录测试。它本身不上传、不执行公开 HTTPS 回读或
业务canary，也不证明生产授权；不得把成功 stage 当作已完成上线。

使用前须校验包和授权范围。stage检查 readiness、实际stable和配置基线摘要，
持有现有核心发布锁，拒绝符号链接目标/不可变冲突，并保存两条入口和配置的
原字节、权限或不存在标记。不可变脚本先校验再改名，入口和配置仍保持旧值。

stage之后，部署协调者必须从三个primary与最终fallback通过HTTPS逐一回读不可变
脚本的SHA256/size，在安全测试环境验证直接脚本与zsetup install进入同一业务函数，
再显式调用activate。该原语不自动绕过这两个外部验收步骤。

activate重新验证包、不可变文件、stable、原配置和入口快照，拒绝期间发生的变更；
先逐文件原子替换两个入口，最后替换完整config.json。它不是多文件原子事务；
中间失败/信号触发指针恢复，短暂窗口要求新旧入口均能使用当前核心。
不联网、不中止业务、不改服务和其他业务目录。不要使用同步删除命令。

快照保存在 fastnet/.installer-rollback-<候选配置SHA256>/，供rollback恢复原字节及权限。
新版本文件不删除；后续发布已经改过入口/配置时拒绝旧快照覆盖。
物理I/O或恢复失败会返回错误并保留快照，需人工按证据恢复，不能宣称回滚成功。

## 当前阻塞和下一步决策

本地生产预览为 blocked：新入口需要0.5.0的storage/bounded download能力，线上是0.4.0。
不能只替换FastNet脚本，否则bootstrap和install都会失败；不能降低脚本底线冒充兼容。
现有CLI的min_version是完整字符串精确合同，不是通用semver范围；能力底线只由
发布工具检查，生成的可上线记录仍绑定实际stable完整版本。

需要单独明确是否连带发布**Linux核心0.5.0**：只升级Linux四架构及其完整配置/stable，
保留Windows/macOS指针和其他业务线上数据。此项不是当前打包器的隐式副作用。
0.5.0已有Linux开发验收，但仍需对应发布门禁及安全环境公开FastNet canary；
Windows/macOS未跑新版本原生门禁，不随本次FastNet发布激活。

确认该范围后，先完成Linux核心精确产物门禁/回读与切换，再重新读取实际线上配置
打包FastNet，执行上述stage/readback/canary/activate及最终固定入口/索引回读。
当前blocked候选不得直接上传激活；底层事务同样拒绝blocked计划。
