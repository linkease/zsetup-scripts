# 客户端 4.2.8 一键安装测试交接

日期：2026-11-03。安装器候选 0.2.1；不更改 zsetup、FastNet、官网默认入口或旧测试链接。

## 实际核验范围

从 `https://fw.koolcenter.com/binary/ddnsto/` 完整下载并计算 27 个安装器所需产物的 SHA-256，证据见 [JSON](ddnsto-artifacts-2026-11-03.json)：Linux Standard 归档 1 个、macOS CLI 归档 1 个、Windows CLI ZIP 1 个、OpenWrt 主包 16 个与 LuCI/语言包 4 个、群晖 SPK 4 个。Windows `version.txt` 为 4.2.8，包内 EXE 摘要与声明一致；群晖 INFO 为 4.2.8-7，DSM 最低版本未变。没有执行这些下载的客户端或包安装钩子。

- Linux 原生：4.2.8，x86_64/aarch64。
- OpenWrt：opkg/apk × 四架构 × Standard/Lite 均为 4.2.8。`lite` 保留既有包目录与参数名，对应 Micro 二进制；LuCI 根目录包继续固定摘要，线上字节变化时必须重新核验，不能跳过校验。
- Windows 原生：4.2.8 CLI，x64；不安装 GUI ZIP。
- 群晖：使用 `synology/4.2.8-7/` 下的 SPK，仍只下载并引导包中心手动安装。`--action download` 返回 0；默认 install 返回 20 表示待手动安装，不是成功安装。
- macOS：4.2.8，Intel / Apple Silicon，归档完整下载、摘要及 version.txt 已核验。56 项隔离行为测试通过；仍需目标 Mac 真机验收。
- Docker：仍为既有 4.2.6 镜像 pin；下载站发布不代表 Docker 镜像发布，不支持替换更新。

## 本地测试命令

从本仓库目录执行，以下 `--plan` 只预览，不下载或安装：

```sh
sh ddnsto/install.sh --plan --method native
```

在目标 Linux/OpenWrt 设备上执行当前候选 `install.sh`，首次安装按提示填写控制台 Token；不要在开发宿主上直接执行安装：

```sh
sh install.sh --method native
# 已安装设备显式更新，沿用原配置和 Token：
sh install.sh --method native --action update
sh install.sh --action status
```

Windows 在目标设备管理员 PowerShell 中：

```powershell
powershell -File .\install.ps1 -Plan
powershell -File .\install.ps1
# 已安装设备：
powershell -File .\install.ps1 -Action update
powershell -File .\install.ps1 -Action status
```

群晖 SSH：`sh install.sh --platform synology --action download`，下载后在 DSM 包中心手动导入。不要混用 Token 与群晖下载参数。

默认重跑不会自动更新；必须选择更新或显式使用 update。不将 `local_service=running/healthy` 当作云端在线，应在控制台确认设备在线，并检查更新前后设备 ID 和配置是否保留。

## 候选产物与验证

```sh
python3 -B scripts/build-entrypoints.py --check
python3 -B ddnsto/tests/cross_platform_installer_test.py
python3 -B scripts/package-entrypoints.py --output dist/ddnsto-entrypoints-0.2.1
(cd dist/ddnsto-entrypoints-0.2.1 && sha256sum -c SHA256SUMS)
```

候选仅包含独立入口与审计元数据，不包含 zsetup 或客户端。目标设备运行入口时自动下载并校验 zsetup 和客户端，用户无需手动下载这些依赖。

新的测试入口为 `https://web.toany.net/ddnsto-install/0.2.1/20261103-a80245f87de8/`，install.sh 与 install.ps1 已 HTTPS 回读核验。旧目录不变。

### 本次检查结果

- 18 组 Python 隔离测试共 279 项：默认 runner 中 6 项真实 native 测试跳过，随后用已核验的 zsetup 0.5.0 补跑 bootstrap 全部 17 项通过，消除这 6 项跳过。
- 默认 runner 未发现 PATH 中的 pwsh；随后使用本机已有 PowerShell 工具单独运行 Windows 7 组测试，全部通过。恢复失败 WARNING 是预期故障注入，不是真机验收。
- 真实 zsetup 0.5.0 的 HTTPS 本地夹具通过：独立入口、Linux、opkg/apk × 四架构、Standard/Lite、缓存、Token 和失败传播。未运行依赖核心源码的历史索引安装/完整发布流程。
- 生成入口一致性、模块布局、发布契约和两个打包测试通过；本地 `dist/ddnsto-entrypoints-0.2.1/` 的五个文件 SHA-256 校验全部通过。
- 未进行真实 Windows/macOS/路由器/DSM 安装、真实账号绑定或云端在线验收，未提交或推送 Git，仅部署新的测试入口，未发布正式下载站。
