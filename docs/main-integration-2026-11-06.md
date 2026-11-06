# DDNSTO 测试分支迁入主线：进行中

## 状态与边界

- 上游基线：`origin/main` 的 `f2d3cdd`。
- 原测试分支：`1945d38`，保存在 `backup/ddnsto-before-main-rebase-20261106`。
- 10 个提交已重放，当前集成检查点为 `68c188a`。这是不完整的迁移检查点，不是可用安装器或发布候选。
- 本地 main 未移动，未推送任何分支，也未部署。
- 保留主线共享框架、其他应用、catalog 和主线回归测试；DDNSTO 新增模块与独立平台实现已保留，但还没有全部接入主线。
- 不得只依据 rebase 成功就合入 main；下述实现和验证通过后，交用户确认，再推送 origin/main。

## 已执行检查

- `git diff --check origin/main...HEAD` 通过。
- `python3 -B scripts/build-entrypoints.py --check` 失败：DDNSTO 生成入口超过 Linux 单参数 131072 字节限制。
- `python3 -B ddnsto/tests/cross_platform_installer_test.py` 失败于第一个 operation-lock suite：5 项失败，主线 business 尚未接入旧分支的 `ddnsto_with_operation_lock`。不能通过直接添加第二套事务锁来掩盖模型冲突。
- 没有执行真实服务安装、设备生命周期操作或上传。

## 待迁移的契约

1. 保持主线 `ddnsto/ddnsto-install.sh` 为唯一生成入口；`install.sh` 仅作为发布兼容副本。保留其他应用生成逻辑及所有共享安全检查。当前导入的旧生成文件不能作为完成集成的证据。
2. 将测试分支的平台约束、只读 plan、Token 输入、4.2.8 pin、Docker/Synology 分流接入主线入口。业务安装与更新沿用受保护的 `/opt/linkease/ddnsto`、版本收据、current/previous、限额下载和 sudo -n 协调器。
3. 将旧 Linux 生命周期的行为与安全检查移植到主线服务模型，不能原样复用 `/usr/local/bin/ddnsto` 的所有权标记。非托管旧安装须拒绝隐式迁移。
4. 修改权限桥接时保留经过校验的 action；当前主线桥接仅传 Token，会丢失 update 语义。更新不得附带 `-u` 或修改设备身份。
5. 健康检查必须在主线服务事务提交和旧版本清理之前完成。所有本地管理操作共用主线事务及回滚；status 不得创建安装状态，失败回滚须保留恢复证据。
6. 离线生命周期使用已有兼容 zsetup；缺失时明确失败，不静默联网。卸载仅删除经所有权验证的托管服务与文件，保留配置和身份。
7. 保留全部 126 条 catalog 记录中的 104 条非 DDNSTO 记录。DDNSTO 新脚本使用新的不可变候选版本，不能覆盖历史 0.2.1 字节或启用生产发布。
8. 合并 standalone packaging 与桌面候选隔离；保留主线 Rust 验证、所有应用和不可变历史。修正旧 publication checker 的 4.2.3/元数据路径假设。
9. 处理入口长度限制：减少生成重复或采用安全的下载文件执行。不能简单删除长度门禁而继续宣传 sh -c 可用。
10. 保留主线 storage/privilege/service/package 测试，将测试分支的行为断言改用主线模型。不得删除失败测试或把未验证状态当通过。

## 验证依赖缺口

仓库记录的权威源码路径
`/projects/workspace-linkease-ubuntu/linkease-vpn/linkease-tunnel/zsetup-rust`
及 `/projects/workspace-linkease-ubuntu/toolchains/` 在当前机器上不存在，PATH 中也没有 zsetup。
已检查 workspace、repos、worktrees 等目录，尚未找到可验证的源码/发布包组合；不能断言其他位置绝对不存在。

需要实际 `ZSETUP_RUST_ROOT` 和对应 `RUST_RELEASE_PACKAGE`，包含：

```text
ZSETUP_RUST_ROOT/Cargo.toml
ZSETUP_RUST_ROOT/scripts/release-preflight.py
ZSETUP_RUST_ROOT/scripts/generate-product-config.py
RUST_RELEASE_PACKAGE/release-manifest.json
RUST_RELEASE_PACKAGE/immutable/zsetup/<version>/zsetup-linux-x86_64
```

还需阅读该源码仓库的产品原则、配置、生命周期和统一发布文档，遵守本仓库 AGENTS 的前置要求。未定位前，不猜测或修改原生协议。

随后执行 `sh scripts/check.sh ZSETUP_RUST_ROOT RUST_RELEASE_PACKAGE`，并补跑未包含在 check.sh 中的真实隔离 sudo/systemd suite。桌面与 NAS fixture 成功不等于真机验收。
