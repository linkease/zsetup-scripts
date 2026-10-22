# 0.2.0 本地集成验证（2026-10-21）

状态：工程候选；未提交、推送或部署。只依赖已发布 zsetup，不要求核心源码。服务、包管理器、Docker 操作使用隔离替身，没有在宿主实际安装 DDNSTO。

## 验证命令与结果

```sh
python3 -B scripts/build-entrypoints.py --check
# 两个变量指向本地验证工具，不是最终用户要求预装的依赖。
PWSH_BIN=/path/to/pwsh DDNSTO_TEST_NATIVE=/path/to/zsetup python3 -B ddnsto/tests/cross_platform_installer_test.py
python3 -B ddnsto/tests/ddnsto_test.py /path/to/zsetup . --direct-only
python3 -B tests/module_layout_test.py
python3 -B tests/publication_test.py
python3 -B tests/entrypoint_package_test.py
python3 -B tests/desktop_package_test.py
git diff --check
```

- 冻结版跨平台 runner：18 个 Python 测试文件 **278 项通过**，另有 **7 个 Windows PowerShell 测试脚本通过**，没有跳过。使用 Linux PowerShell 7.4.13；恢复测试中的 WARNING 为预期故障注入。
- 真实 zsetup 0.5.0 独立入口夹具：Linux、opkg/apk × 4 架构、Token、Lite/Standard、缓存、进度、损坏包和下载失败路径通过。**未测试 indexed install 路径**，当前独立入口不使用该路径。
- 布局、发布契约、独立入口/桌面候选打包、生成一致性检查通过。
- 官网：29 项测试、13 项浏览器检查（含候选窄屏）、生产构建与导出隔离检查通过。文案收尾后重跑测试与生产构建；默认 `release.js` 未修改，未改写旧发布目录。
- Meta：Doctor 与仓库校验通过，源码绑定未配置警告保留。既有 PRD 缺 YAML frontmatter，不适用通用 document intake 校验，未迁移历史文档。

真实 zsetup SHA256 为 `9563b8442a75957792bb82a2d98a736142fc52be57dd2dc42005490096897617`；保留执行前固定摘要与真实 UID 校验，没有使用伪造版本信息跳过认证。

## 独立复查已关闭的问题

- 原生/Docker 冲突在写锁内重查，update 不绕过检查。
- systemd/OpenWrt 管理动作验证服务归属；未知 OpenRC 管理写动作拒绝。
- 提前退出与菜单分流仍检查参数适用性。
- HTTPS bootstrap 限制重定向协议；GNU wget 禁止重定向，未知 wget 实现拒绝。
- 每次使用产品缓存均交给 zsetup 验证实际内容；条件调用也传播下载失败，损坏包不进入包管理器。
- 桌面多行 YAML、plist 同名接管、恢复停止失败及 retained 标记恢复均有回归。

## 本地候选产物

目录：`dist/ddnsto-entrypoints-0.2.0/`，含 `entrypoints-manifest.json`、`SHA256SUMS`。五个文件的摘要检查全部通过：

| 版本化文件 | SHA256 |
|---|---|
| `binary/ddnsto/0.2.0/install.sh` | `f2d4b071df0f9fde4e073319ed13eb7dca9116112947f186bca7ced45beca57b` |
| `binary/ddnsto/0.2.0/install.ps1` | `7c3f7431653f6fafc5bf81bd40e5e1b5791b46a2ad753a839f0e00a08e558fb4` |
| `binary/ddnsto/0.2.0/install-rules.json` | `b16cfc3382b57d4d7bc19190f8db89a47697b6c80384eb79f6ae3054047fbc3d` |

另外两个文件是包内 Shell/PowerShell 别名副本，与版本化文件字节相同。打包不激活远端别名，不修改下载站；实际发布须使用获准的新目录。

## 外部验收仍未完成

Windows/PowerShell 5.1、macOS 双架构、Linux 双架构和各 OpenWrt 固件的真实生命周期、重启及设备身份保持；真实 Token 的控制台在线；群晖无人值守向导；Docker 重建身份保持；QNAP/Unraid 原生执行器；获准 HTTPS 发布及端到端安装。具体平台边界见 [候选说明](candidate-0.2.0.md)，不能据模拟通过宣称全平台正式支持。
