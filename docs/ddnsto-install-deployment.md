# DDNSTO 安装域名、业务环境与发布边界

更新：2026-11-20。状态：本地开发；域名尚未部署，本轮不部署、不做公网/真机验收。

## 唯一职责

`zsetup-scripts` 维护、测试并打包入口、推荐清单、不可变执行器和 AI 指南。控制台固定引用 `https://install.ddnsto.com`，不再随网页 Host 变化。`ddns-server` 与 `ddnsto-static` 不发布或渲染安装资源。原有客户端包及 zsetup 核心下载来源保持不变。

部署使用运维现有上传/托管流程，不新增部署系统。运维可对安装域名设置 HTTP 301/302；每个目标必须为 HTTPS，最多五次跳转，保留有效证书验证。路由需覆盖下列全部路径，不能只跳转 `/i`。脚本正文按摘要校验，不对正文做 URL 替换。

```text
install.ddnsto.com
├── i                         # recommended-entry.sh 的同字节副本
├── i.ps1                     # recommended-entry.ps1 的同字节副本（UTF-8 BOM）
└── ddnsto-install
    ├── current
    │   ├── recommended-entry.sh / recommended-entry.ps1
    │   ├── recommended-shell.txt / recommended-powershell.txt
    │   ├── immutable/<SHA256>/install.sh 或 install.ps1
    │   └── review.json
    └── agent/install.md       # 同时保留 versions/<SHA256>/install.md
```

短入口、推荐清单和指南应 `Cache-Control: no-store`，执行器的摘要路径可 immutable。资源缺失应返回真实 404，不回退 HTML。仅文本内容，不需要网关动态渲染。脚本代码更新不要求重新构建控制台；修改客户端推荐仍遵守 `platform-releases.json` 的唯一维护源约束。

重定向支持使用 curl 或 Windows PowerShell 的逐跳验证。GNU Wget 的 `--https-only` 不保证重定向禁止降级，所以 wget 备用入口仍拒绝跳转；遇到 301/302 会要求安装 curl 后重试。这是明确的兼容限制，不关闭 TLS 校验来绕过。

## 两个独立维度

| 场景 | 脚本来源 | 客户端业务环境 |
| --- | --- | --- |
| production 控制台 | 固定安装域名的已发布推荐 | 正式（省略环境参数） |
| development / staging 控制台 | 同一个已发布推荐，不等于本地候选 | `--env test` / `-Environment test` |
| 本地脚本开发 | 工作区候选及隔离 fixture | 测试参数只决定业务连接；不更换脚本 |
| 后续候选脚本测试发布 | 开发者可更新的测试服务器（待实现） | 独立指定测试业务环境 |

本轮不增加 `--channel test`，也不实现候选脚本测试分发服务。将来测试分发要有独立来源、候选审查、激活及回滚记录，不能反复要求运维更新正式安装域名来测试未审查代码。

默认一律为正式环境：不传环境参数、旧安装没有环境记录，都按 production 处理，不要求用户补记录。只有显式传入测试参数才连接现有 test-toany 业务配置，不接受任意服务器 URL。环境保存在平台服务配置中，重启保持。已有明确环境记录发生冲突时需确认切换，保留 Token、设备身份和其他配置；实际自定义服务器配置仍单独核对。平台不具备可靠测试环境能力时在修改设备前报错，不回退正式环境。实际平台支持范围及验证结果见本次发布记录。

环境切换使用 Shell `--switch-environment` 或 PowerShell `-SwitchEnvironment`，配合目标环境及安装/更新动作；普通控制台复制命令不自动加入该确认参数。缺少环境记录的旧安装默认正式，正常安装、升级和修复不因此受阻，也不需要删除加密启动记录。切换授权不包含换绑或清除身份。

Windows GUI 保持原行为；测试控制台提示采用折叠区 CLI。安装/本地启动是本模块验收目标，云端在线不是脚本成功标准。

### 本轮平台边界

| 平台 | 测试业务环境实现 | 兼容限制 |
| --- | --- | --- |
| Linux/systemd | 受管 unit 持久化启动 assignment | 测试模式需要 jq；缺少环境记录默认正式；新客户端能力先核验再提交版本 |
| macOS | 用户 launchd 持久化启动 assignment，并核对已加载 job | 缺少环境记录默认正式；保留卸载后的已知环境及设备身份 |
| Windows CLI | 独立计划任务设置进程 assignment，保留业务配置环境记录 | PowerShell 5.1 运行/真机待验收；检测到停止后子进程残留即拒绝覆盖，不全局杀进程 |
| OpenWrt / 群晖 / 华硕 | 测试参数在业务修改前拒绝 | 现有发布包的服务模板没有已验证的统一 assignment 配置入口，正式安装能力保留 |
| Docker / QNAP / Unraid | 当前不新增测试环境支持 | 明确提示范围，不静默改用正式环境或其他安装方式 |

这是实现范围，不是实际设备验收结论。最终验证命令和跳过项以发布记录为准。

## 本地准备

先按 [发布 SOP](ddnsto-release-sop.md) 生成并测试，审核两份实际执行器的字节。下面的摘要是占位符，不能复制为真实值：

```sh
python3 -B scripts/build-entrypoints.py
python3 -B scripts/build-entrypoints.py --check
sha256sum ddnsto/ddnsto-install.sh ddnsto/install.ps1
python3 -B scripts/package-ddnsto-site.py \
  --reviewed-shell-sha256 '<审核后的摘要>' \
  --reviewed-powershell-sha256 '<审核后的摘要>' \
  --output '/绝对路径/新的发布目录'
```

若延续已审核 native-first 策略，显式加 `--native-first`；省略为 shell-first，不能无意改变线上策略。打包不会下载客户端或执行安装，也不上传任何文件。输出为独立站点根目录，带 `SHA256SUMS`；输出目录已存在时拒绝覆盖。审核后修改执行器必须重新生成、测试、审核及打包。

## 正式发布与迁移

1. 提交经授权审查的源码，记录最终提交、构建环境、摘要和回滚点；本轮不自动提交。
2. 运维先上传新的不可变执行器与历史指南，校验实际 HTTPS 读回；保留全部旧摘要路径。
3. 原子切换推荐清单、指南及需要更新的入口。核对短入口与长入口字节一致，清单大小/摘要匹配，跳转不降级。
4. 独立安装域名链路验收通过后，再按既有业务流程发布正式控制台和移除旧安装服务职责的网关；静态仓库只发布业务静态文件。
5. 现有服务器旧文件的清理是单独运维动作；本地删除旧副本不授权远端删除。保留全量同步的 legacy 排除保护，避免 `--delete` 清除历史资源。
6. 复制实际控制台命令完成获授权的目标设备验收；测试环境必须确认重启后业务环境仍正确。尚未做真实验收不得宣称上线就绪。

安装脚本回滚恢复上一份审核入口/清单/指南，保留不可变正文；业务控制台、网关独立回滚。推荐回滚不会自动降级客户端，也不会自动恢复客户端业务环境。
