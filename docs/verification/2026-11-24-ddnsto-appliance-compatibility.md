# 0.2.5 群晖维护兼容与华硕验收进展

状态：修复候选已部署测试站；群晖状态通过；华硕隔离历史包升级通过并恢复原版；
OpenWrt 升级暴露的配置归属问题已修复，独立工作目录重装及普通入口重复执行通过。
OpenWrt 默认 /opt 写入异常、华硕正式下载包版本不一致仍未解除，不能据此宣称正式全链路通过。

## 授权与边界

用户确认 OpenWrt 主机变化，要求修复群晖兼容、华硕验证通过，并允许华硕先降级再升级。
不修改 zsetup 核心，不提交或推送、不部署正式域名、不静默换绑。
仅更新 OpenWrt 对应 known_hosts 记录，确认 ED25519 指纹仍为
`SHA256:hy8NP2zSZviI5DS8z4EUeJ9lM39tyMaJiX+CwhsRY+Y` 后登录。
源为 `8e83153` 加工作区未提交改动。

## 代码修复

- 群晖 `--action status` 直接查询 DSM 套件、检查 PID/可执行文件和稳定性；不下载 native，
  不使用 noexec 的 /tmp 执行缓存，不创建安装缓存。需要管理员权限。
- 华硕识别软件中心已知 S70 → config 链接，以及安装器自己的受管桥接链接。
  保留目标所有者/模式和服务端参数检查；拒绝任意链接、悬空链接、可被其他用户写入的目标。
  只读供应商脚本，不执行它们；软件中心既有可写父目录仍是继承的固件信任边界。
- 华硕 native 下载器适配当前共享 `fetch_bootstrap_metadata https FILE FILE` 调用约定，
  元数据存放在自己的受保护目录，要求有效 SHA256，不通过缺省参数调用或 HTTP 降级绕过。
- DDNSTO 脚本版本增为 0.2.5；打包器从外部 app.json 获取当前版本，保留已发布 0.2.4 字节。
  客户端推荐版本未修改。其他应用、核心源码未修改。

## 本地测试

先观察新增回归失败，再实现修复：群晖 status 路由错误、缺少本地查询、华硕正常链接误拒绝、
共享 bootstrap 参数缺失、悬空已知链接未拒绝。之后对应检查通过。

- 顶层 DDNSTO：211 项，168 通过、43 跳过（PowerShell/native/旧 Shell 等环境缺口仍在）。
- appliance maintenance 3 项、auto-synology 13 项、ASUS download 6 项、business environment 18 项通过。
- apps 生成检查、公共树检查、迁移与完整发布契约检查通过。
- 本轮未执行完整 native check.sh，也未重做 Windows/macOS 真机安装。

## 候选与测试站

沿用上一轮独立 `/ddnsto-candidates/` 路由，不改 nginx、控制台或业务服务。

| 候选 | Shell 正文 SHA256 | 用途 |
|---|---|---|
| 20261124-0.2.5-r1 | `3dcfef6b87ed8e8cf7b96d26192c030ef6ec9093e8bd76673fabbdc865c981c0` | 群晖启停状态、华硕已知链接和防降级验证 |
| 20261124-0.2.5-r2 | `3bd76998e797003015f658c2fb787ef44847911b6a7e5868bf32eb5991a59205` | 最新候选，补充拒绝悬空已知链接 |

公共目录：`https://web.toany.net/ddnsto-candidates/20261124-0.2.5-r2/`。
入口为 `recommended-entry.sh` / `recommended-entry.ps1`。两次发布的 Shell 正文均经 HTTPS
读回与本地逐字节比较；PowerShell 正文未改，SHA256 为
`04d98cf8f84bf54bc5d2b07c9b4d212ead933bba479f828eb8013999e00b19f7`。
本地候选位于 `/tmp/ddnsto-device-test.ciVSnl/`，review 不公开发布。
0.2.4 原正文仍为 `50d04954ccb5a5dd7d035730ff09ee6716ae1df31288e1487ea07aa66259e42f`。

## 真机结论

### 群晖 192.168.9.121

以原管理员 sudo 执行公网候选 `--action status`：退出 0，`local_service=running`。
短暂停止套件后 DSM 返回 `status=stop`，安装器退出 0，`local_service=stopped`；
恢复套件后再次返回 running。设置退出时恢复启动的 trap，结束时服务运行。
没有更改 Token、身份、包版本或 /tmp 挂载选项。最新 r2 也执行运行状态复查。
普通用户不经 sudo 的查询仍明确要求管理员权限，不将权限不足误报为停止。

### 华硕 192.168.3.247:2222

RT-AX86U aarch64，现有 DDNSTO 4.2.9。使用设备原 Token（不记录具体值）执行 r1 后，
正常 S70 链接不再触发 E_ENV_UNKNOWN；进入版本保护并返回 E_VERSION，拒绝降级到推荐 4.2.8。
原两个主/子进程 PID 17956、17958 保持不变；没有降级操作。

下载站额外阻塞：rogsoft/ddnsto.tar.gz 302 到 `ddnsto-2f7b01dc7504.ver.tar.gz`。
文件 8227744 字节，SHA256 `681958457e99ff4693e4f8742ee80c36df6eec9f635c4617f8a118151cc0f66e`。
包内 version 为 4.2.8，但 aarch64 二进制 SHA256 为
`e1b604610fa014a5a71dafce4b9b826ff0445b490e65735c70a9c30a1498a782`，
与路由器实际报告 4.2.9 的二进制完全相同。因此不能仅更新摘要就称为审核通过的 4.2.8 包。
其他五渠道当前下载字节与原有摘要一致。

设备保留旧 4.2.8 包 `/jffs/.ddnsto-installer/canary-20261110/rogsoft.tar.gz`，
其旧公网版本地址已 404。已询问是否允许将历史审核包临时用于测试服务器候选；
收到确认后仍需重新校验 SHA256，备份原 4.2.9 插件、dbus 配置及身份，再降级/升级、验收并恢复。
不能把版本保护通过写成真实升级通过；不能将历史测试镜像等同正式下载链路。

### OpenWrt 192.168.30.244

新系统 iStoreOS/x86_64/opkg，客户端 4.2.2~8664-r1、enabled=0，UCI 无 Token。
首次公网安装返回 E_ACCOUNT，正确拒绝无法确认归属的安装；未覆盖配置或二进制。
备份 `/root/ddnsto-before-test.ebmdab/` 包含 config、service、ddnsto。
执行后逐字节比较配置和二进制与备份相同，enabled 仍为 0。
已询问是否可补入用户此前提供的测试 Token 后再启动旧版并验证升级，未擅自处理账号。

## 剩余工作

1. 获准后完成华硕历史包测试及原 4.2.9 恢复；官方 rogsoft 包的版本不一致需发布方纠正。
2. 获准后准备 OpenWrt 旧版运行基线，验证升级、配置和设备身份保留、重复执行。
3. 本次修复没有扩展群晖 start/stop/repair 等所有脚本维护动作，启停由 DSM 套件管理器完成。
   通用 bootstrap 在其他失败路径上的错误传播仍需独立回归，不宣称所有权限错误已修复。
4. 提交、推送及正式上线均需另行授权。

## 追加授权后的实际验收（同日）

用户明确允许历史审核包临时镜像，以及为 OpenWrt 补入既有测试 Token。
上文“等待确认”为此前检查点，以下覆盖该等待状态。不改正式来源，不修改核心。

### 新修复与回归

- ASUS 老 ash 没有 `command` 内建命令；共享 bootstrap 的命令探测误判没有 curl/wget。
  在 ASUS worker 中提供仅支持 `command -v` 的兼容函数，复用既有下载和摘要校验。
  新测试先复现同样的缺少下载工具错误，再通过。ASUS download 共 7 项通过。
- opkg 升级保留配置时，`/etc/config/ddnsto` 出现在 `opkg status ddnsto` 的 Conffiles，
  但不在普通 `.list` 中；原脚本因此误报安装不完整（15），未恢复服务。
  仅在 search 无所有者、目标恰为配置文件时，检查唯一的已安装 ddnsto 包记录及其
  唯一、合法的 conffile 摘要记录。其他所有者、普通文件、缺失/重复/未安装记录仍拒绝。
  不要求配置内容与发行默认摘要相同（用户配置本来就会修改）。新增 3 项先红后绿。
- 顶层 DDNSTO 214 项：171 通过、43 跳过；OpenWrt adapter 6 项、lifecycle 29 项、
  release config 10 项通过；生成一致性、公共树及 diff 空白检查通过。
  未执行完整 native check.sh，原 Windows/旧 Shell 等跳过仍不算验证通过。

### 最新普通候选

`https://web.toany.net/ddnsto-candidates/20261124-0.2.5-r4/recommended-entry.sh`

Shell SHA256：`6bd62d02af45c524bd6610349d29e6fbe8d332e0a8914249e30d23bad09f0636`。
PowerShell 不变。已 HTTPS 读回校验，不覆盖此前不可变候选，不改控制台/正式入口。

### ASUS：真实旧版本升级、重复执行、恢复通过

历史包 SHA256 再次核实为 `671c1c77d7b867f5019af35e8702be665695e30c107138ae150d045e11df1960`。
只临时发布到测试站 `/ddnsto-candidates/packages-20261124/rogsoft-4.2.8.tar.gz`。
在 `/tmp/ddnsto-device-test.ciVSnl/asus-source/` 隔离源码副本中将 rogsoft URL 指向该镜像，
版本/大小/摘要不改，其他五渠道不改；正式工作树未写入镜像 URL。

测试候选：`20261124-0.2.5-asus-mirror-r3`；Shell SHA256：
`53011e593a6b7b93b0918bb9d1450bffb8af2d3a21532ddf845ba30890c7d1bf`。
与普通候选的预期差别为镜像 URL；该候选早于后来 OpenWrt conffile 修复。

1. 备份插件原文件/链接、dbus 配置、身份文件、原 current 指针，私有备份保留。
2. 从本地 rogsoft 历史提交 `d86e8bd` 提取 ARM64 4.2.2 二进制，设备运行 `-v` 确认，
   SHA256 `f03976ccff955042beadbfe4e839474854bad714e9eb6dc5d54268d29855f055`。
   这是受控构造的旧插件运行基线，不是历史插件安装包安装验收。
3. 使用原 dbus Token/功能参数启动真实 4.2.2，经公网候选升级为 4.2.8。
   返回安装、启动成功；主/子 PID 2971、2973 稳定，身份文件逐字节相同。
4. 再次执行成功且两 PID 不变，未重复重启。
5. 退出恢复原 4.2.9；实际二进制 SHA256 恢复为 `e1b604610fa014a5a71dafce4b9b826ff0445b490e65735c70a9c30a1498a782`，
   身份文件相同；与最早备份对照，dbus 没有新增或改变的键。

成功轮备份 `/jffs/.ddnsto-installer/before-20261124-32374/`；最早原状备份
`before-20261124-28802/`。验收辅助脚本留在私有状态目录，不发布。
成功日志为 `tmp.9fc8218d511bbc3746c85c71/events.log`、
`tmp.484210a10a48511de31e23c9/events.log`。最终 4.2.9 PID 5477、5479。

修复过程中有一次未解释的下载失败，安全返回且原服务恢复；随后实际 native 下载与包校验成功，
完整升级通过。另外在全新私有缓存 `asus-probe/cold-5637` 以固件 PATH 独立验证
共享元数据 → 下载 → 摘要校验 → zsetup 0.6.4 执行成功，非仅复用旧缓存。
不将重试成功解释为所有网络失败原因均已解决。

### OpenWrt：配置归属修复验证通过，默认存储仍有环境阻塞

已配置用户授权的测试 Token、enabled=1，启动 4.2.2，实际进程名为 ddnstod，PID 6657。
启动后 UCI SHA256 为 `a12e253f60047a503bf223b0589792d8a1e83de1242ae9c2c98d73d64d5f3484`。

- 默认升级未修改包，失败原因为 `mkdir: can't create directory '/opt/linkease/': Directory not empty`。
  只读检查中 /opt 下没有该目录；内核有 overlay upper/work/lower 复用警告。
  不能据此断言具体固件根因，未修改 Docker、挂载或底层 overlay 数据。
- 使用显式 `--installer-prefix /root/ddnsto-test-installer-20261124` 进行对照，
  真实从 4.2.2 更新为 4.2.8~8664-r1，随后遇到上述 conffile 归属误判（15）。
  配置已正确恢复，但未自动启动；立即通过原 init 服务恢复运行。
- r4 普通入口连续执行两次均返回安装成功、启动成功，日志依次含
  checking/installed/starting/started、exit_code=0；`--action status` 返回 running。
  日志 `/tmp/ddnsto-result.gBlgPa/events.log`、`/tmp/ddnsto-result.Cihbnj/events.log`。
- r4 再以同一独立前缀执行 `--action update`，完整下载校验、包重装、配置恢复、服务自动恢复
  全部成功；package-result 为 phase=complete、exit=0，最终 ddnstod PID 14857。
  UCI SHA256 全程与启动旧版后的记录相同，包含原账号、index 和已有配置。
  未采集升级前独立设备 ID，不能额外声称设备 ID API 对照验收通过。

设备留在 4.2.8 正常运行；原 4.2.2 备份仍在 `/root/ddnsto-before-test.ebmdab/`。
没有为了补跑完整旧版升级而擅自再次降级 OpenWrt。修复后验证的是当前版本重装和重复执行，
不是“修复后从旧版自动升级一次就完全成功”。默认前缀问题需要设备管理员另行处理，
不可把显式替代目录对照结果写成默认一键路径验收通过。
