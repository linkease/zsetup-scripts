# macOS 历史身份文件权限兼容验证

日期：2026-11-19。范围：安装器兼容修复及授权测试 Mac 验证，不修改客户端或 zsetup 核心，不发布公网入口。

## 原因与修复边界

4.2.8 客户端可能在后续启动时将 `.ddnsto_boot.cfg` 设为 0777。安装器原有启动后收紧权限逻辑无法覆盖下一次执行：`check_state` 会先以文件可被其他用户写入为由退出。

模板 `apps/ddnsto/source/templates/install-macos.sh.in` 将该文件的归属验证与权限收紧分开：

- 仍验证所有父目录；身份文件必须位于当前用户的私有配置目录内，属于当前用户、为普通文件、不是符号链接且只有一个硬链接。
- 配置、程序、安装标记、版本凭据、plist 保持原来的权限检查；安装标记及已有 launchd job 也必须通过归属验证。
- 上述检查通过才对唯一身份文件执行 `chmod 600`，不递归处理日志或其他文件，不改 Token、身份内容或服务配置。
- 状态检查也会收紧此已确认归属的文件权限；修改失败不能报告运行正常。无归属文件仍拒绝接管。
- 启动后的权限收紧保留。该修复不改变客户端自身行为，也不是后台权限监视器；客户端自行重启后再次产生宽权限时，下次安装器检查可安全收敛。

生成文件由 `python3 -B scripts/build-entrypoints.py` 更新，未手改：

| 产物 | SHA-256 |
| --- | --- |
| `ddnsto/ddnsto-install.sh` | `a19c7b2a30cd8f0762c9149b4cd11c6c4f5e1af208df6e59ac40eaa7d154347d` |
| `ddnsto/install-macos.sh` | `d0728926215d70a5fb0d542bc0a03122664832c51bcd30ec78122d380ac08e88` |

## 自动化验证

先增加历史 0777 的 status / 默认 ensure 行为测试，确认旧实现两项均以“安装文件可被其他用户修改”失败，再修改模板。

- macOS 行为、默认流程、诊断测试：94 项通过。
- 分平台推荐配置测试：10 项通过。
- 推荐入口测试：48 项，37 通过、11 跳过；跳过项不视为验收通过。
- Shell 兼容测试：4 项，2 通过、2 跳过。
- 生成文件一致性 `build-entrypoints.py --check`、两份 Shell 语法检查、`git diff --check` 通过。

新增拒绝用例覆盖符号链接、硬链接、非私有目录、错误或缺少安装标记、可写配置、外来 launchd job、错误文件所有者，以及 chmod 失败；拒绝时身份内容和权限不变。

## 真机验证

设备：`builder@192.168.9.197`。使用真实生成的一体化入口，不是摘取函数的模拟执行。
用户已授权验证和短暂停止 DDNSTO。测试脚本为 `tests/macos_identity_canary.sh`，只供显式授权设备使用，不属于普通单元测试；不打印 Token。

候选上传至设备私有临时目录 `/tmp/ddnsto-macos-compat.vNDvXO/`，执行：

```sh
sh /tmp/ddnsto-macos-compat.vNDvXO/macos_identity_canary.sh \
  /tmp/ddnsto-macos-compat.vNDvXO/ddnsto-install.sh
```

1. 将已有身份文件恢复为 0777，执行 `--action status`：成功，权限变为 0600，身份/配置/客户端摘要及 PID 均未改变。
2. 再次置为 0777，用既有配置中的同账号 Token 执行默认安装：启动成功，权限变为 0600，三个文件摘要及 PID 均未改变。
3. 执行 `--action restart`，再执行 `--action status`：成功，权限 0600，三个文件摘要不变，服务为 running。

重启前 PID 44310，验证后 PID 75018。最终回读所有者 builder、硬链接数 1、权限 600。
首次验收 SSH locale 引发 Perl 的 locale 回退警告，未影响检查结果；测试工具随后显式设置 `LC_ALL=C LANG=C`。

未验证云端在线、系统重启、全新安装或跨版本升级；`cloud_status=unverified` 属于预期结果。

## 发布状态

本次仅本地候选和真机验证，尚未提交或推送，也未更新 `ddnsto-static` 的推荐清单/不可变执行器或测试站 `/i`。
后续发布必须按现有 SOP 新增摘要寻址的执行器并更新匹配清单，不能覆盖已发布的不可变脚本；不能将本报告等同于公网新版本生效。
