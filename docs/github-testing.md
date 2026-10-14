# GitHub 固定入口测试（0.1.8）

目标：下载站完全只读，GitHub只分发脚本，现有下载站提供zsetup和DDNSTO产品。用户不下载仓库、不预装zsetup。专用测试分支 `test/ddnsto-github-pinned-20261014`；实际测试必须使用固定commit的Raw地址，不使用随时变化的main或分支URL。本文末尾记录固定commit与实际验收结果。

## 使用方式

以下 `<COMMIT>` 为占位符，执行前替换为已发布并核验的40位commit，不可原样执行。

Linux/OpenWrt/macOS终端（需要curl）：

```sh
sh -c 'entry=$(curl -fsSL --proto "=https" --proto-redir "=https" https://raw.githubusercontent.com/linkease/zsetup-scripts/<COMMIT>/ddnsto/install.sh) && test -n "$entry" && sh -c "$entry" install.sh'
```

Windows管理员PowerShell：

```powershell
$ErrorActionPreference='Stop'; [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; & ([ScriptBlock]::Create((Invoke-WebRequest -UseBasicParsing -MaximumRedirection 0 'https://raw.githubusercontent.com/linkease/zsetup-scripts/<COMMIT>/ddnsto/install.ps1').Content))
```

首次按提示粘贴控制台Token（不回显）；无终端自动化使用受限权限Token文件参数，不能把真实Token放进GitHub、日志或公开命令。Linux仍需重复提供Token；桌面重复安装保留配置。macOS为用户登录后启动，Windows为SYSTEM计划任务，Linux需可用systemd/OpenRC。最终到控制台确认设备在线；脚本的本地成功不等于云端绑定成功。

GitHub Raw必须在测试机上可达；网络失败应停止，不使用不可信代理或HTTP替代。不要用 `curl | sh` 占用Token交互输入。NAS/厂商系统不能只因底层是Linux便视为已适配。

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

待固定commit上传后记录GitHub字节回读及隔离Linux真实安装结果。禁止把“推送成功”当作“全平台安装通过”。
