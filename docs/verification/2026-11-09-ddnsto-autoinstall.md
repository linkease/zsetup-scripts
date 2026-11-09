# 无菜单一键安装：0.2.4 本地候选

后续进展：经用户另行授权，已接入测试控制台并发布测试站，见 [测试发布与验收记录](../test-site-2026-11-09.md)。下文保留本地候选阶段的原始验证边界。

日期：2026-11-09。未部署、未切换正式入口、未提交或推送。本次只改脚本、测试与文档，不改前端或 zsetup 核心源码。

## 用户流程

登录后复制包含账号 Token 的命令，在目标设备终端粘贴。用户不选择平台、版本或安装方式。Shell 和 Windows PowerShell 语法不同，保留两个命令入口；控制台接入不在本次范围。

默认 `ensure`：识别平台 → 检查权限和归属 → 安装或升级 → 启用启动 → 连续检查本地进程稳定运行。同版本只启动，较新版本不降级；保留配置和设备身份。账号不匹配、归属不明、缺少可信安装凭据时停止，不自动换绑、卸载重装或切换 Docker。

成功只表示“安装成功，启动成功”，不表示设备在线。不访问云端判断在线状态。不支持或失败返回非零退出码。已识别的错误给出中文原因、阶段和下一步；未知底层失败保留阶段和退出码，不能据此猜测根因，仍需结合本机服务日志。

本地测试（Token 为占位符）：

```sh
sh ddnsto/ddnsto-install.sh --token 'YOUR_TOKEN'
```

```powershell
& .\ddnsto\install.ps1 -Token 'YOUR_TOKEN'
```

安装器自动获取 zsetup 和客户端，无须手动下载。支持 Token 文件。命令内 Token 会进入终端历史，分享截图和故障资料时应删除。

## 默认支持边界

| 平台 | 默认路径 | 前提 |
| --- | --- | --- |
| Linux x86_64/aarch64 | systemd 系统服务 | root 或 sudo；已有安装账号核对需要 jq |
| OpenWrt x86_64/aarch64/armv7/mipsel | opkg/apk、UCI、procd | root、兼容包 ABI、uci/ubus/jsonfilter；低内存自动 Lite |
| macOS Intel/Apple Silicon | 当前用户 launchd | 普通用户图形登录会话，不能 sudo |
| Windows x64 | 系统计划任务 | 管理员 PowerShell |
| 群晖、QNAP、Unraid | 明确拒绝 | 未完成默认自动执行器验收 |
| Docker | 明确拒绝 | 不自动从原生切换到容器 |

这是实现范围，不等于全部真机通过。显式高级生命周期操作保留。群晖下载和 Docker 工程能力见 `install-rules.json`，不进入默认流程。默认 Linux 不支持非 systemd。

## 推荐版本与源码

客户端固定为审核的 4.2.8，不动态追随下载目录的新文件。只依赖已发布 zsetup：Linux/OpenWrt 0.5.0、macOS 0.3.0、Windows 0.4.0。

- `auto-install.sh`：默认编排、版本比较、脱敏阶段记录。
- `auto-linux.sh` / `auto-openwrt.sh`：平台归属、账号及稳定运行检查；复用现有锁、事务、服务管理和恢复逻辑。
- `install-macos.sh` / `install.ps1`：桌面执行器。
- `ddnsto-install.sh`：包含 macOS 分派的生成入口，用 `scripts/build-entrypoints.py` 更新，不手改。
- `recommended-entry.sh` / `.ps1`：稳定薄入口模板；模板未替换前不可直接用于用户安装。
- `scripts/package-ddnsto-recommendation.py`：本地生成严格 HTTPS 数据清单、不可变安装器和审核清单；要求人工提供审核后的两个脚本摘要，不上传。

稳定入口读取数据清单，下载按 SHA256 命名的不可变脚本，校验摘要和大小后执行；客户端和 zsetup 摘要在该脚本内部固定。网络不可用时，只回退到完整且重新验证的私有缓存，并提示无法确认最新推荐。缓存不代表客户端与 zsetup 也已缓存。

发布顺序：审核脚本 → 本地打包 → 发布不可变文件 → 校验实际服务字节 → 原子切换推荐清单。新客户端版本需要更新固定摘要、测试和审核安装器，不只修改服务器 VERSION。稳定入口首次下载仍依赖可信 HTTPS 渠道，不宣称另有独立签名设施。

## 本轮验证

- 默认编排 11 项、OpenWrt 默认决策 5 项通过。
- OpenWrt 原有生命周期 29 项通过；原有安装测试改用显式 `--action install`，新增默认用例独立覆盖。
- macOS 行为 56 项、默认流程 18 项、脱敏诊断 12 项隔离测试通过。
- Linux 默认重复安装/账号冲突/未知配置/保留更高版本：4 项通过，隔离容器、真实已发布 zsetup、模拟 systemd；不是宿主机实际服务安装。
- Linux 原有生命周期 18 项亦在同一隔离环境通过。
- 推荐入口补测 BSD 大小输出、祖先归属、仅继承 ACL 和正文读取超时；指定 PowerShell 运行时后 24 项通过，6 项 Windows 原生测试跳过。
- Windows PowerShell 7.4.13 Linux 运行时的 12 个隔离测试脚本通过（含脱敏诊断）；另一个原生诊断脚本只编译辅助代码，实际 ACL/syscall 验证跳过，不等于 Windows PowerShell 5.1 真机验收。
- 生成入口布局、规范入口打包、桌面打包、CLI 25 项、发布检查 9 项、离线原生查找 4 项通过。
- 总检查执行到权限桥隔离测试时，被环境 `unshare: /proc/self/uid_map: Operation not permitted` 阻断，不能称全量通过。旧跨平台聚合测试还有历史入口/fixture 迁移缺口。

## 未完成的发布门槛

本地已生成两份候选（未上传）：

- `dist/ddnsto-entrypoints-0.2.4-autoinstall-20261109/`：规范入口及兼容副本。
- `dist/ddnsto-recommendation-0.2.4-autoinstall-20261109/`：稳定入口、推荐数据和不可变脚本。计划 URL 填为 `https://web.toany.net/ddnsto-install/0.2.4/recommendation`，只是本地打包配置，不表示该地址已存在。不要将其作为可用命令发给用户。

1. 新默认流程需要 Linux、OpenWrt、macOS、Windows 真机首次安装、重复安装、升级、禁用后启动及失败恢复验收；本次没有改动远端测试设备。
2. 完整权限桥及取消信号进程链需要在支持相应隔离的环境补测。
3. 推荐入口、推荐清单及 0.2.4 不可变文件尚未发布，不能让用户复制未上线 URL；现有正式命令未切换。
4. 控制台接入与设备在线模块不属于本次脚本开发。

因此这是可进入设备验收的工程候选，不是正式上线结论。
