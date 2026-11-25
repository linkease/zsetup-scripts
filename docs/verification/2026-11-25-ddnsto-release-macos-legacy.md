# macOS 旧版缺少版本记录的自动迁移

状态：测试服务器候选已部署，未提交、未正式发布、未进行本次真机验收。

## 范围

用户反馈官方 4.2.1 客户端仍在 `~/.local/bin/ddnsto`，有
`.installer-macos-v1`，没有 `.installer-macos-version`。原脚本因此要求人工迁移。
本次将可识别的历史安装纳入正常升级事务，不要求用户补写版本文件。
目标客户端仍为 4.2.8；行为纳入尚未发布的安装器 0.3.3，保留已有 Linux 候选改动。
已发布的 0.3.2 不变。本轮不授权服务器发布或设备降级。

## 官方文件证据

来源：`https://fw.koolcenter.com/binary/ddnsto/macOS/ddnsto_darwin_cli_4.2.1.tar.gz`。
下载后离线解包计算摘要，并对照包内 `version.txt`；未执行包内程序。

| 文件 | 字节数 | SHA-256 |
|---|---:|---|
| 归档 | 16080877 | `46aad0f28da7ad67175cfed1bc973b1eea68bed4242c8779d8cbd1ba57ed31d7` |
| ddnsto_cli.arm64 | 14488354 | `42b1daf64fcbec4b99623d0585ed80b7184d9f7b25772b5929957ba9de37afa6` |
| ddnsto_cli.amd64 | 15203952 | `6bc92030748aed5ec639eddf543c5b68c9a8efdca83147e10db4e30a9f4edb51` |

用户提供的 ARM64 文件大小、摘要与官方包一致。证据不证明版本记录此前被删除还是从未生成。
历史版本与指纹统一保存在 `platform-releases.json`，不改变各平台推荐客户端版本。

## 行为与边界

- 已有所有者、权限、账号、配置和 launchd 检查继续生效。
- 仅在版本记录缺失时，按架构和官方二进制 SHA-256 恢复内存中的历史版本。
- 不执行未知程序的 `-v` 来证明可信，不预先创建版本文件。
- 下载后、取得锁之后重新验证旧文件；成功启动才写入新版本记录。
- 下载失败保留旧安装；启动失败回滚旧程序、配置及原先缺失的版本记录状态。
- 版本记录已存在但损坏、账号不符、未知二进制不绕过检查。
- 本次覆盖上述已识别目录布局下的官方 4.2.1 ARM64/Intel；不代表任意自定义路径、
  Homebrew、未知服务定义、无安装标记等所有历史安装渠道都已支持。
  未识别场景应补充自动适配，不应让用户伪造凭据或盲目覆盖。

## 验证

新增用例首先复现原始缺少版本凭据错误，随后验证自动迁移、账号/配置/身份保留、
下载失败、启动失败恢复、已有坏凭据拒绝、下载期间文件变化拒绝和不执行未知程序。
使用隔离下载与 launchctl 边界，不改变宿主或用户 Mac 服务；指纹识别测试模拟
官方文件的散列输出，真实归档指纹另以上述离线审核确认。

验证结果：

- 两阶段生成及 `--check`、`git diff --check`、源脚本与 0.3.3 Shell 语法检查通过。
- `tests/ddnsto_release_config_test.py`：10/10 通过。
- macOS 专项 `macos*test.py`：181 项，179 通过，2 失败。两个失败为同一继承用例
  `test_cold_bootstrap_prefers_direct_mac_artifact_source`，断言仍期待旧
  `/zsetup/0.6.5/` 路径，当前实现实际使用 `/zsetup/macos/0.6.5/`。
  在 `git archive HEAD` 的独立目录运行原用例同样失败，确认为本轮之前的问题；未修改它。
- `tests/ddnsto_running_upgrade_test.py`：11/11 通过。
- `tests/ddnsto_apps_standard_test.py`：5/5 通过。
- 新增的 7 项历史迁移用例均通过；未知摘要、并发修改及坏凭据仍拒绝覆盖。

不能据此宣称全量测试通过。真机升级及公网入口回归仍需发布前完成。

## 测试分发（用户另行授权）

2026-11-25 用户要求部署到测试服务器供其直接验证。复用 test-toany 已有
`/ddnsto-candidates/` 路由，未修改 nginx、控制台、业务服务或正式安装入口。

- URL：`https://web.toany.net/ddnsto-candidates/20261125-0.3.3-macos-legacy-29f240d5/install.sh`
- 服务端目录：`/home/ddnsto/installer-candidates/20261125-0.3.3-macos-legacy-29f240d5/`
- 正文：当前工作区生成的 `apps/ddnsto/versions/0.3.3/install.sh`，610436 字节。
- SHA-256：`29f240d54ea9fa071dd57c8aa3f11c4ea4f91e873d43626e0a55a25ad6d4d1b6`。
- 临时目录上传、服务端摘要及语法校验后，以目录重命名激活；没有覆盖历史候选。
- 公共 HTTPS 返回 200、text/plain、UTF-8、no-store，与本地正文逐字节一致；控制台 /app/ 返回 200。
- 这是直接执行候选版本的 macOS 复测地址，不验证正式入口索引分发。默认业务环境仍为 production。
- 候选包含工作区已有 Linux 改动；本次分发仅为用户 macOS 回归，不宣称其他平台已验收。
- 完整正文较大，测试命令下载到临时文件后执行，避免 `sh -c` 参数长度限制。
- 撤回只需停用此独立候选地址，不回滚或修改用户设备，不动正式资源。

### r2：macOS UTF-8 成功提示兼容

用户运行后出现 `result_label` 后带异常字节的 unbound variable。测试 Mac 的
`LC_ALL=en_US.UTF-8 /bin/sh -uc` 最小复现退出 127；C locale 不复现。
旧 Shell 将未加花括号的变量后中文冒号字节纳入变量名。
改成 `${result_label}` 后，同机相同 UTF-8 命令退出 0，中文输出正确。
报错行位于稳定启动检查、版本记录写入和 `changed=0` 之后，不能将它解释为安装未完成。

- 新测试地址：`https://web.toany.net/ddnsto-candidates/20261125-0.3.3-macos-r2/install.sh`
- SHA-256：`0a83be1cc1eef281c433c62a1a5ffaca26d4d9d39f66bc21b8de8629a43e042c`。
- 保留此前候选不覆盖；新文件临时上传、语法检查后重命名激活，HTTPS 摘要一致。
- 默认流程测试 26/26，通过两阶段生成检查及 diff 检查。
- 真机仅执行无副作用的 Shell 兼容复现与修复验证，没有操作 DDNSTO 服务。
- 不再建议将这个完整多平台正文直接管道执行：macOS 分支提前退出时，后续非 macOS
  正文可能尚未传完，curl 仍可报写入失败。使用临时文件完整下载后执行。
