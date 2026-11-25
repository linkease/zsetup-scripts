# zsetup-scripts 冲突合并后完整 apps 发布记录

状态：正式发布完成；源站、发布协调器及四个公开域名复核通过。

## 范围与源代码

- 用户要求先解决 `zsetup-scripts` 的代码冲突，再更新到服务器。
- 冲突来自 `pull --rebase`：KaiPlus 入口提交和上游 DDNSTO 0.3.3 都重新生成了
  `apps/SHA256SUMS`。基于上游最新 apps 树和 KaiPlus 入口重新运行
  `scripts/build.py`，没有选择任一侧的过期摘要。
- rebase 后源提交：`c858679ec73c62ea8794fb9f4d2de8a3d38ac792`，相对
  `origin/main` 保留三个 KaiPlus 测试、实现和历史发布记录提交。
- 本次完整候选包含 10 个应用、108 个清单文件；DDNSTO 标准安装器为 0.3.3。
  旧不可变版本和其他 `/binary` 产品命名空间不属于本次目标。

## 验证

- `sh scripts/check.sh --native-bin .../zsetup-linux-x86_64` 使用已发布 zsetup 0.6.4，
  完整退出 0。生成一致性、发布事务、DDNSTO 0.3.3 进程模式 22 项、macOS 默认流程、
  业务安装器及 native 隔离回归均通过。
- 第一次把整个 Python/Shell 检查放进 SSD 缓存 wrapper 时，wrapper 改写的 `TMPDIR`
  被 zsetup 存储安全检查拒绝；按脚本原有临时目录语义重跑后通过。该检查没有执行
  npm、Go、Rust 或 Zig 构建。
- 实际 GNU Bash 4.2.0 POSIX 模式专项 4 项全部通过，无跳过。
- `scripts/publish-apps.py prepare` 和只读 `plan` 通过，固定公开目标为
  `/mnt/sata3-1/istore-data/public_html/binary/zsetup-scripts/apps`。

## 发布结果

- 发布 ID：`b15faa9bf8656366762e1647fefa54d91c5ae40427e41156ff02bd9885b5ed93`。
- 旧线上发布 ID：`885aa737c6e114cf4fe126c69c622d2213f7575fc06a709a0eead13c30b5fab5`。
- 服务器：`root@192.168.3.1`；完成时间：`2026-11-25T10:46:08Z`。
- 协调器依次完成暂存、激活和验证，100 次不可变文件检查及 432 次最终公开字节检查通过。
- 服务器、本地和四个公开域名的 `SHA256SUMS` 摘要均为发布 ID。
- KaiPlus 固定入口摘要：
  `7d62b6dbeaf55dd5fb4607bd2e41d4aaf6be82c6223c798865d3566879336c88`。
- DDNSTO 固定入口摘要：
  `f402be0953429843544a4dcc974387a8dcd42123eeb1989994186b96efd9c766`。
- `dl.istoreos.com` 对这些路径返回 302 到 `fw.koolcenter.com`；跟随重定向后的常规
  无查询参数 URL 与其余三个域名逐字节一致。协调器只读 `verify` 再次通过。

回退快照：

```text
/mnt/sata3-1/istore-data/public_html/binary/zsetup-scripts/apps/zsetup/.apps-rollback-b15faa9bf8656366762e1647fefa54d91c5ae40427e41156ff02bd9885b5ed93
```

如需回退，只恢复本次管理的入口、配置和清单，不删除不可变历史，也不自动降级设备：

```sh
python3 -B scripts/publish-apps.py rollback \
  --server root@192.168.3.1 \
  --binary-root /mnt/sata3-1/istore-data/public_html/binary \
  --release-id b15faa9bf8656366762e1647fefa54d91c5ae40427e41156ff02bd9885b5ed93 \
  --approve b15faa9bf8656366762e1647fefa54d91c5ae40427e41156ff02bd9885b5ed93
```
