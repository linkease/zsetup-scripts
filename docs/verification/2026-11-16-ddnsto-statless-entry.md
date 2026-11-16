# 无 stat 的一键入口优化与测试站发布

日期：2026-11-16。

## 已确认边界

用户报错已明确为独立 stat 和 BusyBox stat 均未识别到。用户确认：默认联网、移除长期推荐缓存、保留 HTTPS 与 SHA-256、不自动安装系统依赖、不修改 zsetup 核心；跳过真机验收，更新测试服务器后交给用户测试。

## 实现

- 推荐入口不再要求 stat、cmp；在受检查的系统临时目录创建本次运行私有目录。macOS 允许系统 `/tmp` 解析到 `/private/tmp`；华硕保留原 `/jffs` 受保护存储边界。
- 不再使用 HOME 下的推荐缓存、不复用离线脚本、不使用推荐缓存锁。旧 `DDNSTO_RECOMMEND_CACHE` 不再生效，也不自动删除旧缓存。并行安装的业务锁仍由平台执行器持有。
- 下载清单仍必须是受限 ASCII 三行字段，以精确字节数拒绝额外内容、NUL、CRLF 和缺失末尾换行；无需 cmp。安装器继续校验 SHA-256 和字节数，执行前再次检查。
- `portable-files.sh` 同时供入口、Linux/OpenWrt zsetup 引导及 OpenWrt 配置保护使用。优先使用系统 stat；没有时通过 `LC_ALL=C ls -dn` 严格读取数字所有者、模式及硬链接数。仅接受无歧义路径、普通文件或目录；拒绝符号链接、ACL 标记与异常格式。不安装 stat 替代程序，不放宽权限检查。
- BusyBox wc/mktemp/sha256sum 可在入口使用，并通过私有临时转接命令传递给子脚本。zsetup 引导本身也支持 BusyBox SHA-256 和 shasum，不能在入口通过后再次因哈希工具识别不同失败。
- 保留正常退出、失败及取消时先等待子进程结束再清理工作目录的规则。
- zsetup 自身原有私有二进制缓存、客户端配置、诊断日志与 Windows GUI 不变；macOS/DSM 的平台业务依赖不因此取消。

限制：mktemp 和对应 BusyBox 功能均不存在时仍拒绝。BusyBox/uclient wget 没有满足当前传输契约的验证证据，本次不放开；继续使用 curl 或支持所需参数的 GNU Wget。没有关闭证书验证、HTTP 降级或调用旧安装脚本。

## 本地验证

先新增并观察到无 stat/cmp、BusyBox-only 哈希、禁止离线复用等测试在旧实现失败，再实现优化。业务测试使用隔离文件、模拟包管理器或本地 HTTPS，不执行真实客户端安装。

| 检查 | 结果 |
|---|---|
| `python3 -B -m unittest discover -s tests -p 'ddnsto*test.py'` | 143 项，110 通过，33 因 Windows/专用隔离环境缺失跳过 |
| `ddnsto/tests/bootstrap_policy_test.py`，提供已发布 0.5.0 native | 21 项通过，包含无 stat 的首次引导与仅 BusyBox 哈希 |
| `ddnsto/tests/wget_bootstrap_test.py`，提供已发布 native | 48 项通过，含真实本地 HTTPS、证书、重定向、响应限制及完整下载链 |
| `ddnsto/tests/macos*test.py` | 86 项通过（隔离模拟，不是真实 launchd 验收） |
| `ddnsto/tests/asus*test.py` | 97 项，95 通过，2 跳过 |
| `ddnsto/tests/entry_cancellation_test.py` | 5 项通过，含取消等待、实际工作目录清理、stdin/argv/退出码 |
| `tests/ddnsto_portable_files_test.py` | 6 项通过，含所有权/权限/链接数与异常格式拒绝 |
| Alpine 3.20 断网容器 | 隐藏 stat，真实 BusyBox ls 解析 `/tmp` 为 `0 1777 1` |
| `build-entrypoints.py --check`、Shell 语法、`git diff --check` | 通过 |

native 来源：`https://fw.koolcenter.com/binary/zsetup/0.5.0/zsetup-linux-x86_64`，下载后先核对固定 SHA-256 `9563b8442a75957792bb82a2d98a736142fc52be57dd2dc42005490096897617`，未编译或修改核心。全仓其他产品发布检查未运行；当前工作区缺少 AGENTS 引用的 owning zsetup 源码路径。按用户要求没有 OpenWrt 真机验收。

## 测试站发布及回滚

服务器：`tx-nj-02.kooldns.com:2233`。目录：

`/home/ddnsto/installer-test/ddnsto-install/0.2.4/recommendation-short-20261109/`

只发布新 Shell 不可变安装器，然后原子替换 `recommended-shell.txt` 和 `recommended-entry.sh`。不覆盖旧不可变目录、不改 Nginx、不改 PowerShell、不发布正式下载站。源码原 HEAD 的安装器摘要与发布前线上一致，候选差异属于本次优化。

- 旧入口：`c2274f29ee907c7c4818ef22cb5dfa632d75b3dc5308b23eb7a18e29497008a5`
- 新入口：`c13ae6d0c87ff8179ec955300a2a3f3b9ed0425d719cb1a613e3d4438f21885e`
- 旧 Shell 安装器：`bc7c349c95a623dfaf2431e1cd53b0648e1b03bad1f49b9d073362201be829ad`，500716 字节。
- 新 Shell 安装器：`5c3eaad0eac55b0c44c3b32536a7dcf2ddfa9b6ab5ac3cfac482036224d0af9e`，505785 字节。
- 新推荐清单 SHA-256：`769455e5ba3b0540ae896091230101ed55c654e529d1a41ac496cd831fbe3792`。
- 备份目录：`/home/ddnsto/installer-test/.backups/statless-20261116/`，保存旧入口和旧 Shell 清单。

公网 `/i` 与对应长地址回读均返回新入口摘要；新不可变安装器回读摘要匹配。下载公网入口并执行 `--help` 成功；在 PATH 中同时排除 stat、cmp、BusyBox 后再次执行同一公网入口 `--help`，完整下载及校验成功。未安装本机客户端。额外移除所有哈希工具时按预期以 code=2 拒绝。

用户继续执行控制台现有 `/i` 命令即可，不需要额外安装 stat。用户设备结果尚待反馈。

回滚：检查线上摘要仍为本次版本后，将备份中的入口和清单复制到同文件系统的暂存位置，核验摘要并原子替换。保留新旧不可变安装器；不要直接覆盖正在被读取的脚本。
