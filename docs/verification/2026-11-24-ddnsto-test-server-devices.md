# 测试服务器分发与真机验证（2026-11-24）

状态：测试候选已部署；部分平台安装通过，华硕阻塞，OpenWrt 待确认主机身份。不是正式发布。

## 范围和候选

用户要求恢复通过测试服务器在既有真机验证安装流程。仅分发 DDNSTO 候选、验证默认安装和重复执行；
不提交或推送，不更新正式安装域名，不改控制台，不换绑、降级、卸载或切换业务环境。
源提交 `8e83153` 加当前工作区未提交变更（含 sources/apps 分离），不能仅凭提交号复现候选。

- 目录：`https://web.toany.net/ddnsto-candidates/20261124-8e83153-worktree/`
- Shell：`recommended-entry.sh`；Windows CLI：`recommended-entry.ps1`。
- 使用已有 `package-ddnsto-recommendation.py --source-url` 生成，shell-first，无新下载协议。
- Shell 正文 SHA256：`50d04954ccb5a5dd7d035730ff09ee6716ae1df31288e1487ea07aa66259e42f`。
- PowerShell 正文 SHA256：`04d98cf8f84bf54bc5d2b07c9b4d212ead933bba479f828eb8013999e00b19f7`。
- 正文与 apps 候选相同；包装入口和清单来源指向测试目录，不修改正式产物中的域名。
- 本地候选及 review：`/tmp/ddnsto-device-test.ciVSnl/20261124-8e83153-worktree/`。
- `build.py --check` 通过。此前回归为 165 通过、43 跳过；本轮没有重跑完整回归或旧 Shell 兼容环境。
- 六个入口、清单及正文经公共 HTTPS 回读与本地逐字节一致；404、text/plain、UTF-8、no-store 已核验。

## 测试服务器变更

复用 test-toany 的 nginx，仅增加 `/ddnsto-candidates/` 静态路由到
`/home/ddnsto/installer-candidates/`，不写 ddnsto-static、不改网关实现。
候选存入独立版本目录；没有覆盖任何已有候选，没有上传 review.json。
上传完成后才激活新路由；nginx 配置检查和 reload 成功，未重启业务服务。

配置原文件 SHA256：`675983723072328c5468ee14c053d161057ae533bed248bfa3adc8dd37f6e335`。
修改前做摘要比较，备份在 `/home/ddnsto/backups/installer-candidate-20261124/web.toany.net.conf`。
结束时 nginx、ddnsserver、deviceserver 均 active，公网 /app/ 返回 200。
回滚时须先核对配置没有后续修改，再仅撤回本次路由、nginx -t 与 reload；保留候选文件。
未演练回滚。该路由是本次测试站上的独立配置，后续整站 nginx 部署需显式保留；
未新增长期自动化发布任务，也未修改既有 nginx 部署模板。

## 实机结果

| 设备 | 默认安装/重复执行 | 验证和限制 |
|---|---|---|
| macOS 192.168.9.197，builder，ARM64 | 两次退出 0，4.2.8，local_service=running | 首次 operation=repair；再次稳定运行，单 ddnsto 进程；yaml 摘要前后相同。通过 SSH 执行公网命令，未测试注销/重启和旧版本升级 |
| Windows 192.168.9.199，admin，10.0.26200 | 两次退出 0，4.2.8，local_service=running | PowerShell 5.1 读取公网候选、ScriptBlock 执行；任务 DDNSTO=Running，单 CLI 进程；yaml 摘要不变。仅 CLI，不包括 GUI |
| 群晖 192.168.9.121，DS220j，DSM7 aarch64 | 管理员默认安装两次退出 0，提示安装及启动成功 | 原套件 4.2.8-7；第二次配置摘要前后相同，synopkg=running。sudo 管理员执行，不代表交互式 sudo 提权链路验收；额外 status 路径失败，见下文 |
| 华硕 192.168.3.247:2222，aarch64 | E_ENV_UNKNOWN，未进入安装 | 正常 S70ddnsto.sh 软链接被环境预检误判。现有 4.2.9 及原进程保留；不能视为安装或防降级场景通过 |
| OpenWrt 192.168.30.244 | 未执行 | SSH 主机密钥与本地历史记录不符，已请求用户确认；没有跳过校验或向该主机发送密码 |

macOS yaml SHA256：`cabec0447d3c2262ccdd07a5ea1f4fbbb8d2e682f1a93b3ba0e1a007bd991b60`。
Windows yaml SHA256：`1d92c6623c8a71c3dec945e160c235a91ea6283206837a69d470269b898c6155`。
群晖重复执行时 JSON 配置 SHA256：`b51fd77003b316103eb2d0efa3caa5de3c4751080765462005753a637eec8ce3`。
配置一致性不等于完整设备身份文件对照；本轮未单独收集加密身份文件摘要。
设备在线不作为安装成功条件。没有测试空白新装、跨版本升级、停止后恢复、重启和破坏性故障注入。

## 发现的问题（未修改安装器）

1. 华硕 `ddnsto_business_service_file` 拒绝所有软链接，而软件中心的
   `/koolshare/init.d/S70ddnsto.sh` 正常指向 `/koolshare/scripts/ddnsto_config.sh`。
   两者可读，针对服务器参数的扫描均未匹配，但仍触发 E_ENV_UNKNOWN。
   后续应验证已知链接的目标、所有者和权限，而不是移除链接或放开全部链接。
2. 群晖额外 `--action status` 走旧的 download/manual handoff 路径，默认使用 `/tmp/zsetup`。
   普通用户遇到历史 root 0700 缓存；sudo 后在 noexec 的 `/tmp` 上运行 native 失败。
   已校验官方 zsetup 0.6.4 aarch64 文件摘要，直接执行退出 126（Permission denied），不是证明版本错误。
   指定独立可执行缓存目录后，status 仍提示 `Synology supports only download or manual install handoff`。
   默认 ensure 则走 auto-synology 专用缓存路径并成功，不能将 status 的失败写成默认安装失败。
3. 通用 bootstrap 的错误传播会在上述失败后继续访问 RESCUE_VERSION / ACTIVE_ZSETUP，产生 unbound variable，
   掩盖原始权限错误；应另行补回归和修复，不通过放开 /tmp noexec 解决。

## 用户复测

Shell（保留当前业务环境，Token 换成账号自己的）：

```sh
(s=$(curl -qfsS --max-time 60 https://web.toany.net/ddnsto-candidates/20261124-8e83153-worktree/recommended-entry.sh) && test -n "$s" && sh -c "$s" -- --token 'YOUR_TOKEN')
```

群晖本轮使用 sudo 管理员 Shell；不要据此认为无需管理员权限。不要在华硕已知阻塞未修复前标记验收通过。
该命令测试的是候选脚本分发，不是 `--env test`；两者独立。本轮未切换客户端业务服务器。
