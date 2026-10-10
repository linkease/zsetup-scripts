# 构建、配置与发布

业务发布流程提前把 FastNet/DDNSTO 产品、版本信息和真实 SHA256 元数据放到服务器。设备上的业务脚本按平台和架构选择产品，调用 zsetup 下载、校验、复用缓存，然后完成业务安装。本仓库维护安装脚本和统一安装索引，不采集、缓存或重新打包产品。

依赖权威 zsetup 源码和现有构建能力，最低版本 0.2.4。复用原生版本/SHA256 元数据读取、总内存探测和 download/context/run/install；保留 0.2.3 Race 预算及 DoH/UDP 解析修复。本次没有修改下载内核或业务脚本字节，脚本版本仍为 0.1.3，config_version 为 scripts-0.1.3。

## 本地构建

业务变动不要求重编同版本 zsetup，复用已验证的不可变 release；若需要新 native 版本，在 zsetup 仓库执行既有 release-targets.sh、check-release-artifacts.sh、run-target-smoke.sh。无需下载任何 DDNSTO 产品来构建安装脚本发布包。

```sh
cd /path/to/zsetup-scripts
python3 -B scripts/build-entrypoints.py
sh scripts/check.sh /path/to/linkease-tunnel/zsetup
python3 -B scripts/package-release.py --zsetup-root /path/to/linkease-tunnel/zsetup --require-clean
(cd dist/release && sha256sum -c PACKAGE-SHA256SUMS)
```

`--require-clean` 检查两个源码目录已经提交；不传时允许开发构建，manifest 明确记录 dirty 状态。旧的 --collect-ddnsto、--ddnsto-artifacts 和 --require-production-ready 已移除。打包不访问产品服务器；测试通过隔离 HTTPS fixture 提供产品，不执行真实系统安装。

输出 dist/release/binary/、scripts-release-manifest.json、PACKAGE-SHA256SUMS 和确定性 tar.gz；dist/evidence/ 存放测试日志。两者都被 Git 忽略。打包器复用 zsetup 的 check-release-artifacts.sh 和 generate-product-config.py，摘要/大小从实际脚本及 native 发布字节生成，沿用完整 Product Configuration schema 1。

manifest 的 business_artifacts 标记业务服务器发布所有权及 included=false，readiness 固定为 server-artifacts-and-canary-unverified。本地构建不证明线上产品/元数据可用或设备 canary 通过。再次构建只保留历史不可变安装脚本和 native release，不带入旧候选中的产品包、业务版本指针或业务 SHA256SUMS；更新的是本地候选，不会删除服务器任何文件。

## 本仓库发布布局

| 文件 | 规则 |
|---|---|
| binary/zsetup/0.2.4/ | 权威 native release 的六个不可变文件，包括 SHA256SUMS/manifest |
| binary/{fastnet,ddnsto}/0.1.3/install.sh | 不可变业务入口；索引记录真实 SHA256/size |
| binary/{fastnet,ddnsto}/install.sh | 可变用户入口，与当前索引脚本同字节 |
| binary/ddnsto/install.ps1、install-macos.sh | Windows/macOS 原生业务入口；使用已发布客户端归档，不在本仓库内复制客户端二进制 |
| binary/zsetup/config.json | 完整配置，不进行字段合并 |
| binary/zsetup/stable | 精确 native 版本，最后激活 |
| binary/ddnsto/openwrt/install_ddnsto.sh、install_ddnsto_business.sh、setup_ddnsto.sh | 相同 DDNSTO 入口字节的兼容副本 |
| binary/ddnsto/linux-binary/install_ddnsto_linux.sh | 相同 DDNSTO 入口字节的兼容副本 |

APP/business.sh、main.sh、lib/、legacy/、Python 工具、测试和 README 均不上传网站。旧脚本历史源码归档在 legacy/；根目录没有旧别名。服务器兼容 URL 由 ddnsto/release.py 从当前 ddnsto/install.sh 生成实际文件，不依赖历史快照或符号链接。Windows/macOS 原生入口由打包器显式复制；脚本字节变更必须递增不可变版本/config_version；旧版本不得覆写。

## 服务器提前提供的产品

以下路径位于站点 /binary/ 下，由各业务发布流程准备。每个候选 URL 必须返回相同字节，产品摘要由发布者从实际产品计算；不为未取得的字节虚构摘要，不关闭校验。

FastNet：fastnet/version.txt，以及它声明的 FastNet-<VERSION>.amd64、.arm64、.armv7 和匹配 SHA256。格式保持现有业务协议。

DDNSTO：

```text
ddnsto/openwrt/VERSION
ddnsto/openwrt/VERSION_LITE
ddnsto/openwrt/<standard|lite|standard-apk|lite-apk>/<VERSION>/
  ddnsto_<x86_64|aarch64|arm|mipsel>.<ipk|apk>
  luci-app-ddnsto.<ipk|apk>
  luci-i18n-ddnsto-zh-cn.<ipk|apk>
  SHA256SUMS
ddnsto/linux-binary/ddnsto-standard-4.2.3.tar.gz
ddnsto/linux-binary/SHA256SUMS
```

opkg 使用 ipk，apk 使用带 -apk 的目录和 apk 包。OpenWrt 主包、LuCI 包、语言包及 SHA256SUMS 放在同一个不可变版本目录，全部完成后才更新 VERSION/VERSION_LITE。Linux tar 包含 ddnsto-standard-4.2.3/ddnsto.x86_64 和 ddnsto.aarch64 普通文件；其他已发布版本可通过 DDNSTO_VERSION 选择，并有对应摘要。SHA256SUMS 使用标准的 `64位十六进制摘要  文件名` 格式；安装端由 zsetup metadata 读取，zsetup download 内置校验，不依赖系统 awk/sed/openssl/sha256sum。

旧 CDN 已有产品的历史检查记录位于 docs/verification-2026-10-08.md。当时部分 checksum 元数据尚未提供，LuCI 包位于可变根目录；新入口上线时业务发布者应补齐上面的版本目录及元数据。已有产品无需搬回本仓库，不把“缺少元数据”等同于“缺少产品”。历史摘要记录仅供核对，当前打包器不读取或发布它们。

## 正式服务器切换

固定 primary 为 dl.istoreos.com、fw.d4ctech.com、fw20.koolcenter.com；fw.koolcenter.com 为最终 fallback。HTTPS 与 shell 首次自举的明确确认规则保持不变。

1. 业务发布流程先完成各站点产品及版本/SHA256 元数据。确认对应系统、包管理器和架构路径可读取，内容/摘要一致。
2. 将本仓库 tar 放入受控部署 staging，解包并验证 PACKAGE-SHA256SUMS。按 binary/ 相对路径增量部署到网站 /binary/，保留已有产品和历史版本；不得使用同步删除。
3. 先部署并回读不可变 native/业务脚本，拒绝同版本字节冲突；设备 canary 验证两种入口和回滚。随后原子切换用户/兼容入口、完整 config.json，stable 最后激活。
4. 四站点同步并完成回读后公布升级。immutable 路径可长期缓存；install.sh、config、stable、业务 VERSION/version.txt 和未版本化 SHA256SUMS 使用 no-cache。

回滚恢复上一份完整配置、可变入口和所需业务指针，stable 最后回退；保留不可变文件。配置 stable/min_version/artifacts 必须一致，不仅修改版本字符串。

当前工具只生成本地候选，不上传公网、不更改服务。原 zsetup upload-fw-koolcenter.sh 只接受旧 S6 FastNet 布局，不能直接上传本多业务包。实际部署需要具体服务器、网站路径、上传方式、站点回源关系及 canary 设备。

维护者构建依赖仍为 Python 3.11+、Git、POSIX shell 和权威 native release 检查器所要求的现有 binutils/UPX 等工具，不增加设备安装依赖。
