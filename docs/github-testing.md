# GitHub 固定入口测试（0.1.8）

2026-10-15：0.1.9 已另行部署到 [web.toany.net 测试目录](test-site-2026-10-15.md)，不再依赖 GitHub Raw 获取入口。下文是 0.1.8 固定 GitHub 链路的历史记录，其成功与网络超时不能代替新测试站的验收结果；旧 commit 字节保持不变。

## macOS用户反馈与0.1.9本地候选

用户运行下方固定commit后反馈：macOS已完成下载、客户端4.2.1和LaunchAgent运行检查；仍未据此确认云端绑定、重启或全架构验收。用户要求Token输入可见，0.1.9本地候选已改为终端回显，安装器不额外打印Token；macOS输出明确标注“固定版本、未检查最新版”。先运行两项新测试确认旧实现失败，再修改源码并回归。此候选尚未提交/推送，下方旧链接仍保持原行为。

macOS客户端4.2.1及归档SHA256由安装器固定，`--version`也不能绕过未收录版本的校验。zsetup0.3.0是独立下载器版本。2026-10-14只读查看官方 `https://fw.koolcenter.com/binary/ddnsto/macOS/`，目录仅列出 `ddnsto_darwin_cli_4.2.1.tar.gz`；这证明当次公开目录所列版本，不是自动“最新版”协议。固定commit即使重复执行也不会自动跟随以后发布的客户端。

在下载站不可修改的前提下，如需“最新推荐稳定版”，可后续在GitHub维护按平台区分的版本、URL和SHA256清单，由稳定入口读取；旧固定commit保留为可复现测试入口。本轮不实现该独立升级策略，也不以抓取目录最大版本号替代正式发布推荐。

目标：下载站完全只读，GitHub只分发脚本，现有下载站提供zsetup和DDNSTO产品。用户不下载仓库、不预装zsetup。专用测试分支 `test/ddnsto-github-pinned-20261014`；实际测试必须使用固定commit的Raw地址，不使用随时变化的main或分支URL。本文末尾记录固定commit与实际验收结果。

## 使用方式

本轮固定安装器commit：`5a7a0437d11b1df7cfc44be5d6f95453de3baf34`。以下命令已使用该commit，不会跟随测试分支之后的变动。

Linux/OpenWrt/macOS终端（需要curl）：

```sh
sh -c 'entry=$(curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 --proto "=https" --proto-redir "=https" https://raw.githubusercontent.com/linkease/zsetup-scripts/5a7a0437d11b1df7cfc44be5d6f95453de3baf34/ddnsto/install.sh) && test -n "$entry" && sh -c "$entry" install.sh'
```

Windows管理员PowerShell：

```powershell
$ErrorActionPreference='Stop'; [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; & ([ScriptBlock]::Create((Invoke-WebRequest -UseBasicParsing -MaximumRedirection 0 'https://raw.githubusercontent.com/linkease/zsetup-scripts/5a7a0437d11b1df7cfc44be5d6f95453de3baf34/ddnsto/install.ps1').Content))
```

首次按提示粘贴控制台Token（不回显）；无终端自动化使用受限权限Token文件参数，不能把真实Token放进GitHub、日志或公开命令。Linux仍需重复提供Token；桌面重复安装保留配置。macOS为用户登录后启动，Windows为SYSTEM计划任务，Linux需可用systemd/OpenRC。最终到控制台确认设备在线；脚本的本地成功不等于云端绑定成功。

GitHub Raw必须在测试机上可达；网络失败应停止，不使用不可信代理或HTTP替代。Shell命令有有限重试和超时，仍不保证所有国内网络可达。不要用 `curl | sh` 占用Token交互输入。NAS/厂商系统不能只因底层是Linux便视为已适配。

## 固定版本与只读下载站

| 平台 | 客户端 | zsetup |
|---|---|---|
| Linux x86_64/aarch64 | Standard 4.2.3 | 既有stable，本轮0.4.0 |
| OpenWrt opkg/apk × x86_64/aarch64/armv7/mipsel | Standard 4.2.6 / Lite 4.2.2 | 同上 |
| Windows x64 | CLI 4.2.1 | 固定0.4.0 |
| macOS Intel/Apple Silicon | CLI 4.2.1 | 固定0.3.0 |

Linux/OpenWrt的21个唯一路径及SHA256维护于 `ddnsto/product-pins.sh`，构建时嵌入独立入口。2026-10-14使用真实zsetup0.4.0从 `https://fw.koolcenter.com/binary/ddnsto/` 重新下载全部21个文件，实算大小/摘要全部与历史证据匹配。文件只在临时目录核验后回收，没有进入源码或发布包。历史大小/摘要可对照 `docs/ddnsto-artifacts-2026-10-08.json` 的 `source_path`（不是其重排后的 `path`）。

主包沿用版本目录；LuCI/语言包沿用OpenWrt根目录，不假设已复制进版本目录。脚本不请求业务VERSION/VERSION_LITE/SHA256SUMS，不修改全局zsetup配置、stable或FastNet。native自身的stable/SHA256SUMS仍来自已有下载站。

上游改变同名LuCI字节时，旧脚本会拒绝下载；维护者重新核验产品、兼容性后更新pins并递增安装器版本，再发新的commit链接。未知Linux产品返回11。重新运行不是“自动升级最新版”；不要为方便而取消SHA256校验。

## 验证范围

- 测试先行：旧实现因请求VERSION元数据而失败，未知Linux版本先下载再失败；新实现不访问业务元数据且提前拒绝未知版本。
- 真实zsetup0.4.0 + 隔离HTTPS夹具：直接入口、冷引导、opkg/apk四架构、Lite/Standard、缓存、Token、失败回收通过。夹具中的摘要仅修改在临时脚本副本，不提供生产运行时校验绕过。
- 变更根目录LuCI字节，真实下载器拒绝，在包管理器修改前失败。
- macOS12项、POSIX Token5项、Linux服务9项、Windows行为/引导两组及打包/布局/发布器回归通过；Windows/macOS系统API为夹具，不是真机验收。
- 完整native源码/索引构建仍未运行；`zsetup install`索引路径的既有问题不在本次范围。直接入口不使用它。
- 产品可下载/摘要匹配不证明原生安装；Windows/macOS/OpenWrt、Linux ARM64/systemd、机器重启、跨版本升级、真实账号绑定仍需验收。

## 发布与实测记录

已推送测试分支，未改main。两个固定commit Raw入口均匿名回读成功，与本地生成字节一致；Shell `--help` 成功。摘要：

```text
88f28305cb4ba98b879970f38e4cfac9efb4b44938fb1a29d1b596cb3ac33740  install.sh
403288ba109ad9170289d9816fc2e7cb0f06714c1202c3bae806a4864cf3111a  install.ps1
```

### 测试环境及一次失败的定位

沿用已授权测试服务器，在临时Alpine3.20/OpenRC0.54容器内运行 `ddnsto/tests/github_linux_canary.sh`；不在宿主安装客户端。初次Docker Hub拉取超时，改为传输已有Alpine镜像；官方Alpine软件源过慢，容器依赖改从可达镜像安装，APK签名验证保留。上述仅影响测试环境，不改变产品下载地址。

第一次实际安装通过GitHub入口回读、zsetup0.4.0自动引导、客户端4.2.3下载与校验，但因容器仅有softlevel、缺少OpenRC starting/started等运行目录而服务启动失败。安装器返回13，没有误报成功；失败恢复提示保留备份。最小隔离容器中相同客户端也失败，补齐运行目录后服务started、健康接口ok，证明是测试初始化问题。已修正测试脚本，不修改已发布安装器字节。同时修正测试中服务名称为实际的 `com.linkease.ddnstoshell`。

容器出站仅允许DNS与解析出的GitHub/产品下载站443，禁用IPv6；实际确认生产控制端口不可达。使用合成非账号Token，不做生产或测试后端设备绑定。诊断容器及其internal网络已清理，未改变宿主服务。不能把本地服务运行当作云端在线。

后续一次复跑在GitHub Raw回读时60秒超时（exit28，尚未进入安装）。同链接此前在该服务器成功回读，说明网络存在波动。测试入口获取增加有限重试，未关闭TLS、未使用第三方代理、未改写GitHub地址。

最终测试服务器这一轮包含两次重试的三次Raw请求均超时，退出28，未进入安装；不标记为该服务器完整安装通过。临时canary容器已自动删除，诊断internal网络也已删除；原guacd仍healthy，原站首页HTTP200。该限制与下方开发机完整通过的结果分别记录。

### 开发机隔离容器：完整GitHub链路通过

使用同一测试脚本、同一固定commit、同一Alpine3.20/OpenRC0.54及出站白名单，在开发机Docker容器进行对照，退出0：

1. 无预装zsetup、无客户端，先从GitHub回读入口，SHA256与上表一致。
2. 执行GitHub一键命令：自动获取zsetup0.4.0，选择既有fw20下载源，取得15.5MiB客户端4.2.3并通过SHA256校验。
3. 安装及启动真实服务 `com.linkease.ddnstoshell`；输出 `local_service=healthy cloud_status=unverified`，OpenRC为started、健康接口返回ok，`COLD_INSTALL_OK`。
4. 再次执行同一命令，复用已校验缓存、停止旧服务再启动；健康接口ok，设备ID保持一致，`REPEAT_INSTALL_OK`。
5. 停止测试服务，临时容器自动删除；其中合成Token、服务配置及安装随之回收，未安装到宿主。无需恢复用户数据，可重跑脚本重建。

这是Linux x86_64/OpenRC、真实下载与真实客户端的验收，不是模拟包或模拟服务；云端绑定被主动隔离，未验收账号闭环，也不代表Windows/macOS/OpenWrt真机、systemd/ARM64、跨版本更新或系统重启验收通过。服务器网络波动不能因另一环境通过而忽略。
