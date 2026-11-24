# DDNSTO 安装域名、业务环境与发布边界

更新：2026-11-24。状态：本地候选；本轮不部署、不做公网/真机验收。

后续测试进展：同日用户另行授权测试服务器与真机验证，已建立独立
`web.toany.net/ddnsto-candidates/20261124-8e83153-worktree/` 测试分发路径。
这不改变正式安装域名或控制台，不等于自动化测试发布服务已实现。
实际部署、设备结果和阻塞见 [真机测试记录](verification/2026-11-24-ddnsto-test-server-devices.md)；
下文“待实现/本轮不部署”保留为此前正式部署方案阶段的边界。

最新普通测试候选为 `20261124-0.2.5-r4`：群晖 status 已修复，华硕历史包隔离镜像升级通过并恢复原版，
OpenWrt 配置归属兼容修复、独立工作目录重装及普通入口重复执行通过。
华硕正式包版本不一致、OpenWrt 默认 /opt 写入异常仍未解除，详见
[兼容修复与验收进展](verification/2026-11-24-ddnsto-appliance-compatibility.md)。

## 唯一职责

`zsetup-scripts` 维护、测试并生成入口、推荐清单、不可变执行器和 AI 指南到
`apps/ddnsto/`，作为 Git 跟踪的最终产物，随现有完整 `apps/` 发布。
控制台固定引用 `https://run.ddnsto.com`，不随网页 Host 变化。
`ddns-server` 与 `ddnsto-static` 不发布或渲染安装资源。
原有客户端包及 zsetup 核心下载来源保持不变。

部署使用运维现有上传/托管流程，不新增部署系统。运维可对安装域名设置 HTTP 301/302；每个目标必须为 HTTPS，最多五次跳转，保留有效证书验证。路由需覆盖下列全部路径，不能只跳转 `/install.sh`。脚本正文按摘要校验，不对正文做 URL 替换。

```text
apps/ddnsto/                  # run.ddnsto.com 的路径映射根
├── install.sh                         # recommended-entry.sh 的同字节副本
├── install.ps1                     # recommended-entry.ps1 的同字节副本（UTF-8 BOM）
└── ddnsto-install
    ├── current
    │   ├── recommended-entry.sh / recommended-entry.ps1
    │   ├── recommended-shell.txt / recommended-powershell.txt
    │   └── immutable/<SHA256>/install.sh 或 install.ps1
    └── agent/install.md       # 同时保留 versions/<SHA256>/install.md
```

## 运维映射（必须整体配置）

| 用户地址 | 下载站地址 |
|---|---|
| `https://run.ddnsto.com/install.sh` | `https://fw.koolcenter.com/binary/zsetup-scripts/apps/ddnsto/install.sh` |
| `https://run.ddnsto.com/install.ps1` | `https://fw.koolcenter.com/binary/zsetup-scripts/apps/ddnsto/install.ps1` |
| `https://run.ddnsto.com/ddnsto-install/<路径>` | `https://fw.koolcenter.com/binary/zsetup-scripts/apps/ddnsto/ddnsto-install/<路径>` |

后缀路径逐项保留；未知路径返回 404。根 `/` 可选映射到 `install.sh`，控制台不依赖根路径。
不能将所有请求重定向到旧 `install_ddnsto_linux.sh`。
`ddnsto-install.sh` 保留为历史兼容的原生索引入口；控制台使用 `install.sh`、
`install.ps1` 的跨平台推荐协议。本次不新增 DDNSTO 的原生 Windows 索引记录。
先发布标准入口及其完整依赖、配置并回读上述映射，再发布引用新地址的控制台和官网。
发布树不再生成 `i` / `i.ps1`；若要兼容已复制的命令，由运维将旧路径重定向至标准路径。
这些路由需要单独上线；本地生成、测试通过不代表线上已经切换。
维护源码、模板、推荐配置和 app.json 均在发布树外的 `sources/ddnsto/`。
`apps/ddnsto/` 仅保留运行产物；说明和审核记录在 `docs/`，不部署。

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

在仓库根目录按 [发布 SOP](ddnsto-release-sop.md) 生成并测试：

```sh
python3 -B scripts/build-ddnsto-products.py
python3 -B scripts/build-ddnsto-products.py --check
python3 -B scripts/build.py
python3 -B scripts/build.py --check
python3 -B tests/ddnsto_apps_site_test.py
python3 -B tests/ddnsto_site_package_test.py
python3 -B scripts/check-public-tree.py apps
(cd apps && sha256sum -c SHA256SUMS)
```

构建复用站点/推荐打包器，将完整结果写入 `apps/ddnsto/`，并更新全局
`apps/SHA256SUMS`；`--check` 检查入口、清单、正文、指南及摘要是否漂移。
历史摘要文件保留，不用旧 dist 覆盖新源码，不手工编辑生成文件。
隔离打包器生成的 review.json 只记录一致性，`published=false`，不代替人工审核和真机验收；
审核记录归档到 `docs/verification/`，完整 apps 构建不复制它。
本次 apps 推荐入口采用原打包器默认 shell-first；native-first 仍是独立审核选项，
不在本次更改中激活。标准 apps install.sh 自举行为不变。
旧 `package-ddnsto-site.py` 仍可生成隔离候选用于测试，但其 dist 不再单独部署。

## 正式发布与迁移

发布器不删除远端文件。如果下载站已有旧 `source/`、app.json、README.md 或 review.json，
本次目录调整不会自动移除它们；需另行确认精确路径、备份并授权运维清理。不要使用广泛的 `--delete`。

1. 审核源码及生成结果，获得授权后提交并推送 main，记录最终提交及回滚点；本轮不自动提交。
2. 按 [现有 apps 发布流程](apps-release.md) 执行 `scripts/publish-apps.py prepare` 和 `plan`。
   prepare 要求 apps 已提交且干净；不要为本地未提交候选绕过门禁。发布物仍为完整 apps，
   固定同步到 `/binary/zsetup-scripts/apps/`，不把 apps/ddnsto 直接覆盖 `/binary/ddnsto/`。
3. 获得精确 release ID 的上线授权后，使用现有协调器发布。版本文件、摘要执行器和历史指南
   先暂存并经 HTTPS 回读，再激活可变清单及入口；不另建独立站点上传流程。
4. 运维修正上表域名映射，逐项核对短/长入口字节、清单引用、Windows BOM、AI 文档和
   HTTPS 跳转；不能只检查 HTTP 200。链路通过后，按既有流程发布测试控制台，验收后发布正式控制台。
5. 现有服务器旧文件的清理是单独运维动作；本地删除旧副本不授权远端删除。保留全量同步的 legacy 排除保护，避免 `--delete` 清除历史资源。
6. 复制实际控制台命令完成获授权的目标设备验收；测试环境必须确认重启后业务环境仍正确。尚未做真实验收不得宣称上线就绪。

回滚使用现有 apps 协调器与准确 release ID，恢复该整体发布的可变文件，保留不可变正文。
整体发布回滚会影响该 release 中其他应用的可变文件，需核对版本，不能冒充仅 DDNSTO 回滚。
域名路由和业务控制台独立回滚。推荐回滚不会自动降级客户端，也不会自动恢复业务环境。
