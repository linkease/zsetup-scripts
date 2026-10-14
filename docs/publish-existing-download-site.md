# 在现有下载站发布 DDNSTO 直接入口

> 本文保留0.1.7候选发布方案。0.1.8在下载站不可修改的条件下改用[GitHub固定入口与内置摘要](github-testing.md)，无需执行本文的上传或业务元数据补齐步骤。

目标：复用 `https://fw.koolcenter.com/binary/` 及既有镜像。不新建下载服务器，不重新上传 zsetup，不要求用户手动下载工具或仓库。本文是维护者发布清单，不是最终用户的安装步骤。

## 当前候选

`dist/ddnsto-entrypoints-0.1.7/` 已生成并校验，只含以下四个入口文件及本地校验材料：

```text
binary/ddnsto/0.1.7/install.sh
binary/ddnsto/0.1.7/install.ps1
binary/ddnsto/install.sh
binary/ddnsto/install.ps1
SHA256SUMS
entrypoints-manifest.json
```

Shell SHA256：`86757d25416bebc20bbd0808740adac48068391a770995438edd6f570bc2c6f2`。
PowerShell SHA256：`403288ba109ad9170289d9816fc2e7cb0f06714c1202c3bae806a4864cf3111a`。

此包**不含** native、客户端产品、全局索引或 stable 指针。它不会部署服务器，不能用“打包成功”替代发布验收。Shell 与0.1.6相同；Windows 引导更新为 zsetup0.4.0，统一业务入口版本升至0.1.7。

## 已有依赖直接复用

| 平台 | zsetup 来源与版本 | 本轮状态 |
|---|---|---|
| Linux / OpenWrt | 既有 `/binary/zsetup/stable`，当前0.4.0 | Linux x86_64真实下载器、自动引导和业务夹具矩阵通过 |
| Windows | `/binary/zsetup/0.4.0/zsetup-windows-i686.exe`，脚本固定官方 SHA256 | 真实文件摘要核对、脚本行为回归通过；本轮未跑 Windows 原生安装 |
| macOS | `/binary/zsetup/0.3.0/zsetup-macos-*` | 暂不切0.4.0；上游将其 macOS0.4.0标记为未原生验收候选 |

保留既有三个 primary 与 fw.koolcenter.com fallback。下载站来源不等于客户端连接后端，测试账号绑定必须另行使用明确的测试后端环境。

## 必须补齐的业务发布内容

2026-10-14只读检查，正式 DDNSTO 入口和以下 SHA256SUMS 仍返回404：

```text
binary/ddnsto/linux-binary/SHA256SUMS
binary/ddnsto/openwrt/standard/4.2.6/SHA256SUMS
binary/ddnsto/openwrt/standard-apk/4.2.6/SHA256SUMS
binary/ddnsto/openwrt/lite/4.2.2/SHA256SUMS
binary/ddnsto/openwrt/lite-apk/4.2.2/SHA256SUMS
```

这些是当次 VERSION/VERSION_LITE 的结果，不是未来版本硬编码。发布时重新读取版本指针，核对所有引用的主包、LuCI包、语言包确实存在于相同版本目录，再在**业务发布服务器**从实际文件字节生成标准 SHA256SUMS。不能只补一个虚构摘要文件，也不能用旧文档摘要代替当前字节计算。

Linux 默认产品为 `ddnsto-standard-4.2.3.tar.gz`；不要为这次安装器发布重建或覆盖同名历史客户端包。正式客户端错误退出码修复的构建发布属于另一个版本流程。

## 执行顺序

1. 确认现有下载站的发布脚本/流水线；若使用 SSH，确认准确的目标、端口、`/binary/` 对应的服务器目录及镜像同步关系。不能从下载域名推断 SSH 地址或 Web 根目录。
2. 在私有 staging 校验候选的 `SHA256SUMS`。服务器提前准备上述业务包和元数据；不在脚本仓库中采集或重新打包产品。
3. 先增量发布 `ddnsto/0.1.7/` 两个不可变入口，已有同名路径必须先比较摘要；不同字节则拒绝覆盖。保留旧版本和现有产品，不使用 `--delete`。
4. 从真实 HTTPS 地址回读校验，执行约定平台 canary。Windows/macOS/OpenWrt及 Linux 其余环境的未验收状态不能隐藏；只完成 Linux 测试不能宣布全平台正式放行。
5. 满足上线范围的验收条件后，才原子切换 `ddnsto/install.sh`、`install.ps1` 的用户别名。若需兼容历史 URL，另行核对范围，不自动覆盖旧平台脚本。
6. 运行 `python3 -B scripts/check-publication.py --mode direct --base https://fw.koolcenter.com/binary`，并核对各镜像内容。工具只核验入口和元数据，不替代真实安装或客户端包字节校验。

**本流程不修改** `binary/zsetup/config.json`、`config-windows.json`、`stable`、`stable-windows`、已有 native 版本目录或 FastNet 文件。直接入口调用 `zsetup download`，不要求把 DDNSTO 写入全局安装索引。不得把旧完整索引发布包整体同步到站点根目录。

回退只恢复本次改动的 DDNSTO 用户别名和必要业务元数据，保留已发布版本文件；不要回退 zsetup 或其他业务的全局指针。

## 当前缺口

工作区中尚未找到 fw.koolcenter.com 对应的实际上传入口及 Web 根目录。本轮没有尝试猜测 SSH 目标、覆盖正式站点或新建服务。待维护者提供既有发布流程后，按以上清单继续。

具体兼容性证据见 [0.4.0复用验证](verification-2026-10-14-zsetup040.md)。
