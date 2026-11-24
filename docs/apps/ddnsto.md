# DDNSTO

当前部署模型见 [独立安装域名与业务环境](../docs/ddnsto-install-deployment.md)，
本轮状态见 [2026-11-20 本地变更记录](../docs/verification/2026-11-20-ddnsto-release-install-domain.md)。
控制台将固定使用 install.ddnsto.com；安装资源不再由业务服务器/静态仓库发布。
以下日期条目是历史证据，不代表新域名或业务环境参数已经完成真机验收。

## 分平台产品版本维护

原生安装器的版本和产品摘要统一维护在 `platform-releases.json`；不同平台可以独立推荐版本。
有 `templates/*.in` 的脚本和 `install-rules.json` 为生成文件，请修改模板中的安装逻辑或 JSON 中的产品数据，
再从仓库根目录运行 `python3 -B scripts/build-entrypoints.py`。不要直接修改这些生成文件。
更新流程与边界见 [分平台推荐配置](../docs/ddnsto-platform-releases.md)。设备端不增加 JSON 解析依赖。

2026-11-19：[macOS 历史身份文件 0777 兼容修复](../docs/verification/2026-11-19-macos-identity-permissions.md)：仅在私有目录、文件归属及安装记录检查通过后收紧身份文件权限，保留配置和设备身份；已通过 Mac 真机状态检查、重复安装与服务重启验证。本项尚未发布至测试站 `/i`。

2026-11-16：[macOS 与 Windows CLI 真机验收](../docs/verification/2026-11-16-desktop-native-lifecycle.md)：本地 Mac 修复候选和 Windows CLI 执行器通过首次安装、重复执行及启停；Mac 公网入口尚未更新，Windows 公网脚本在 Restricted 执行策略下仍受限。未验收跨版本升级、重启或 Windows GUI Token 保存。

2026-11-16：[zsetup 能力复用审查与候选开发任务](../docs/ddnsto-zsetup-reuse-audit-2026-11-16.md)。第一批已收敛现代华硕下载后的重复校验，并增加真实核心契约测试；[验证记录](../docs/verification/2026-11-16-ddnsto-native-reuse-batch1.md)。华硕 SSH 已恢复且身份校验通过，RT-AX86U 上两版核心的候选下载函数验证通过；未部署、未升级核心，完整安装/恢复真机验收仍待完成。

第二批将现代华硕的解包输出捕获交给现用 zsetup 0.5.0（大小、空间与超时限制），保留 tar、包白名单及 armsoft 兼容路径。RT-AX86U 的真实包暂存解包通过；未执行安装或重启。详见上述验证记录。

后续已实现[核心先行入口](../docs/ddnsto-native-first-candidate.md)：打包器显式 `--native-first` 才启用，普通 Linux x86_64/aarch64 先校验固定核心再由核心下载业务脚本，其余平台保持原路径。2026-11-16 经用户授权，完成 OpenWrt/DSM 同版本公网验收、测试站 `/i` 激活及回滚演练；[发布与限制记录](../docs/verification/2026-11-16-native-first-test-release.md)。正式环境未更新，完整真机矩阵仍未齐全；华硕按用户要求跳过。

旧版本正在运行时的更新结果，见 [跨平台升级专项测试](../docs/verification/2026-11-16-running-old-version-upgrade.md)：19 个新增用例通过，明确区分真实文件事务、模拟服务状态和真机证据；不将包部分失败后的配置恢复当作完整客户端回滚。

群晖自动安装、升级和启动已发布至测试站 `/i`：DSM 7 原生 SPK，管理员 sudo 授权，保留配置且不降级。DS220j / DSM 7.1 已验证空白新装、4.2.7-7 升级到 4.2.8-7、停止后启动及重复执行。新装通过 DSM 本机套件中心 API 传递 Token，安装至默认卷；接受已校验摘要的 DDNSTO 第三方包，不改全局信任策略。发现卸载残留或账号不同会拒绝覆盖。其他机型及 DSM 6 尚未完成真机验收。ARM64 仅开放已验证的 DS220j ARM32 兼容路径，不代表全部 ARM64 群晖。正式环境未更新，详见 [群晖验证记录](../docs/verification/2026-11-09-synology-auto.md)。

> 当前标准安装器版本为 0.3.0，默认动作是无菜单的 `ensure`。客户端产品版本由 `platform-releases.json` 独立维护；安装器版本不等于客户端版本。

Linux、OpenWrt 和 macOS 统一使用 `apps/ddnsto/install.sh`；Windows 使用 `apps/ddnsto/install.ps1`。两个标准入口都调用 zsetup，同一版本的不可变实现位于 `apps/ddnsto/versions/0.3.0/install.*`。维护源码位于 `sources/ddnsto/`。

发布后用户入口：

```sh
zsetup install ddnsto -- --token 'YOUR_TOKEN'
sh -c "$(curl -fsSL https://fw.koolcenter.com/binary/zsetup-scripts/apps/ddnsto/install.sh)" -- --token 'YOUR_TOKEN'
```

OpenWrt 支持 opkg/apk × x86_64/aarch64/armv7/mipsel；总内存低于 900 MiB 自动选 Lite，可传 `--force-version lite|standard`。token 可选；`--verify-status` 请求服务检查。Linux 支持 x86_64/aarch64，默认 Standard 4.2.3，无终端时必须提供 token。Windows 入口支持 x86_64 CLI 4.2.1，在 Windows 10 x64 WOW64 / PowerShell 5.1 验证范围内使用计划任务启动；macOS 入口支持 Intel/Apple Silicon CLI 4.2.1，使用用户级 launchd。Windows/macOS 的 4.2.1 归档 SHA256 固定在入口脚本中，升级新版本前必须更新脚本、测试和发布配置。参数、退出码及交互详情见 [统一协议](../docs/ai-contract.md)。

应用接口只包含 `app.json`、三个标准入口 `install.sh`、`install.ps1`、`install.md` 和 `versions/`。产品文件由 DDNSTO 业务发布流程提前部署到独立 `/binary/ddnsto/`；测试位于 `tests/apps/ddnsto/`，不会复制到服务器。

DDNSTO 是 [apps layout v2](../apps-layout-v2.md) 标杆，不提供兼容别名。`run.ddnsto.com` 直接映射三个标准入口，不建立 `_sites`；不可变实现位于 `versions/0.3.0/`。business、Python 工具、测试和 README 不进入应用发布目录。

模块命令（从仓库根目录执行）：

```sh
python3 -B ddnsto/tests/ddnsto_test.py /path/to/zsetup/dist/release/zsetup-linux-x86_64 /path/to/linkease-tunnel
python3 -B ddnsto/tests/cross_platform_installer_test.py
```

业务发布者从其实际发布字节生成 SHA256SUMS，并先部署 OpenWrt 每个版本目录中的主包、LuCI/语言包和摘要，以及 Linux tar 和摘要，最后更新 VERSION/VERSION_LITE。安装脚本只从服务器读取版本和摘要，再调用 zsetup download 校验产品。完整安装配置仍与 FastNet、native zsetup 一起生成；发布顺序见 [发布文档](../docs/release.md)。


Linux storage candidate scripts0.1.8 requires Rust zsetup0.5.0. Default command
is ~/.local/bin/ddnsto; the system-service payload is root-protected under
/opt/linkease/ddnsto. Systemd is the new raw service adapter; SysV legacy remains
unported. Ordinary users prepare on persistent storage then use sudo -n for
verified root commit (sudo -v beforehand when credentials are missing).
Explicit root invocation also works. Common --installer-prefix/work-dir/scope
options precede business arguments; -- ends common parsing. Unknown existing
installations are migration conflicts. OpenWrt keeps only its proven native
package mappings and explicit root invocation. See ../docs/linux-install-storage.md
for disk bounds, two-version cache, metadata/network behavior and recovery.
This is an unpublished candidate, not a new production pointer.
