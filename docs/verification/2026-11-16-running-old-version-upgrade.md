# 旧版本正在运行时的一键更新：专项测试

日期：2026-11-16。用户要求针对各平台“旧版正在运行 → 一键更新 → 更新后运行情况”
编写测试并获取结果。本轮只新增测试和记录，未修改安装器实现、测试站或正式环境，
没有连接或降级任何真机。现有业务安装器 SHA256 仍为
`1de460d6296f387978a83d22aa7112c8a584913d45f74f8ec92b7ac469e807ae`。

## 新增用例与结果

共 **19 个用例通过**：本地隔离用例 16 个，独立 Linux 容器用例 3 个。
OpenWrt 的成功及部分包失败用例分别覆盖 opkg、apk 子场景。

回归命令 `DDNSTO_TEST_NATIVE=/tmp/ddnsto-zsetup-audit.b6JOZ8/zsetup python3 -B -m unittest discover -s tests -p 'ddnsto*test.py'`
最终执行 172 项：137 项通过、35 项跳过、0 失败（29.311 秒）。其中新增 Linux 3 项
因宿主隔离保护而跳过，已在独立容器另行执行并通过。跳过项不计入通过数。
`python3 -B scripts/build-entrypoints.py --check` 与 `git diff --check` 均通过。
此回归范围不等于整个仓库所有历史测试。

| 平台 | 用例数 | 本轮实际执行层次 | 结果 |
| --- | --- | --- | --- |
| Linux | 3 | 真实 ensure 控制器、zsetup 0.5.0、解包/版本切换/回滚，模拟下载和 systemd | 4.2.7 → 4.2.8；配置逐字节保留，current 指向新版、previous 指向旧版；下载失败不停止旧版；新服务首次启动失败后恢复旧版本、旧 unit 和 active/enabled 状态 |
| macOS | 3 | 执行真实 `install-macos.sh`，模拟 zsetup 下载和 launchctl | 旧二进制及其 4.2.7 摘要回执升级至 4.2.8 回执；先 bootout 后 bootstrap/kickstart，保留配置和设备标识；下载失败不停止；启动失败恢复旧二进制、回执、配置及模拟运行状态 |
| OpenWrt | 3 | 真实更新执行器及配置恢复，模拟 opkg/apk、UCI、init | 旧包记录为 4.2.6；更新替换客户端夹具、停止后重启，配置不变，禁止包钩子提前启动；第二个包失败返回 23 并保留配置；更新后服务不运行返回 13 |
| 群晖 | 5 | 真实自动升级、账号/版本检查和稳定性函数，模拟 synopkg 与 `/proc` | 4.2.7-7 → 4.2.8-7，旧 PID 1234 → 新 PID 2345，三次状态检查通过；下载失败旧状态不变；包部分失败、新版启动失败或 PID 抖动均不记录 started |
| 华硕 | 3 | 真实升级事务编排，下载/备份/插件操作/服务/恢复函数为边界夹具 | 4.2.7 分支按下载→备份→停止→安装→启动执行，保留账号及功能设置；下载失败不停止；安装或启动失败调用恢复。**没有验证真实 restore_plugin 恢复后进程** |
| 不支持的默认路径 | 2 | 真实自动安装前置检查 | QNAP、Unraid、Windows Shell 路径返回 E_PLATFORM；默认 Docker 选择返回 E_METHOD，不擅自迁移安装方式 |

“运行”在本轮是平台管理器/进程状态模型，不是实际 DDNSTO 进程。本轮没有验证云端在线、
隧道重连、远程链接恢复、重启设备后的自启动、实际 GUI 升级或实际平台包管理器行为。
Windows 边界用例不代表 Windows GUI 安装器测试。

## 对用户运行状态的结论

1. **成功更新不是热更新**。脚本会停止/替换/启动；测试检查调用顺序和最终状态，
   不能据此给出实际中断时长。
2. **下载失败与替换后失败必须区分**。下载失败场景检查未发生 stop、版本和运行状态
   仍为旧值；不能仅凭非零退出码认定保护成功。
3. **Linux/macOS 的可控启动失败会尝试并能在本夹具中完成恢复**。Linux 检查真实
   current/unit/配置/候选目录及模拟 manager 状态；macOS 检查旧文件逐字节一致，
   且确实经历新任务 bootstrap 失败与恢复 bootstrap，防止“未执行到更新”造成假通过。
4. **OpenWrt 不提供完整包回滚保证**。测试注入 ddnsto 包写入后另一个包失败，
   返回 partial，原配置仍在；没有把包数据库或旧客户端恢复列为已通过。
5. **DSM 可能是新版已落盘但没有运行**。模拟包部分失败或 start 失败后，版本为
   4.2.8-7、running=false，保留配置备份、返回 E_PACKAGE/E_START，不自动降级。
   此行为是测试确认的当前边界，不是声称真实 synopkg 每次失败都产生同一最终状态。
6. **华硕目前只证明事务编排请求恢复**。不能把 stub 的恢复调用当作真实旧进程重启成功。

额外发现：DSM 控制器在 `set -e` 下，`ddnsto_flow_error` 的返回值 2 会使执行提前结束，
后面的 `exit 11/13` 没有执行。本轮失败夹具实际返回 2，错误分类仍分别为
E_DOWNLOAD、E_PACKAGE、E_START。测试同时断言错误分类和文件/运行状态，
不能仅按数字退出码区分失败阶段；本轮记录现状，没有修改安装逻辑。

此前 DS220j 真实 4.2.7-7 → 4.2.8-7 成功记录仍有效，见
[群晖历史真机记录](2026-11-09-synology-auto.md)；本轮没有重做该升级。
此前 OpenWrt 真机同版本验证仍不能替代跨版本升级验证。

## 文件与复跑

- `tests/ddnsto_running_upgrade_test.py`：macOS、OpenWrt、华硕及不支持平台，11 项。
- `tests/ddnsto_running_upgrade_synology_test.py`：有状态 DSM 夹具，5 项。
- `tests/ddnsto_running_upgrade_linux_test.py`：原生事务测试，3 项，默认隔离保护未满足则跳过。

在仓库根目录执行前两组：

```sh
python3 -B tests/ddnsto_running_upgrade_test.py
python3 -B tests/ddnsto_running_upgrade_synology_test.py
```

Linux 组只能在一次性容器内执行。需要 root、Python 3、jq、shell/tar/基础工具、
复制后的仓库、独立持久卷挂载到 `/opt/linkease`，以及固定 SHA256 的官方 zsetup 0.5.0。
本次使用 `python:3.12.11-slim`、专用 Docker 卷，不挂载宿主的业务目录。
容器内的启动方式：

```sh
mkdir -p /ddnsto-lifecycle-sandbox
DDNSTO_LIFECYCLE_SANDBOX=1 DDNSTO_TEST_NATIVE=/fixture/zsetup \
  python3 -B tests/ddnsto_running_upgrade_linux_test.py
```

不要在开发机或测试服务器宿主创建该标记后运行；测试会操作容器内的
`/opt/linkease/ddnsto`、`/etc/ddnsto` 和模拟 systemd unit。
执行前校验核心 SHA256：
`9563b8442a75957792bb82a2d98a736142fc52be57dd2dc42005490096897617`。

初次 Linux 夹具使用 overlay，真实 storage 拒绝未确认的持久存储；随后改用独立卷。
下载失败用例收紧为明确返回 11；启动失败收紧为返回 9 且确实调用 start。
最终 3 项全部通过，耗时约 25 秒。未放宽生产存储检查或修改核心。

一次性容器 `ddnsto-upgrade-scenarios-20261116` 和专用卷
`ddnsto-upgrade-data-20261116` 已删除；只含合成测试数据，不含真实用户配置。
本轮没有发布、提交或推送。
