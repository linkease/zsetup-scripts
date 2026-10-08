# 构建、配置与发布

依赖权威 zsetup 源码和工具，最低版本 0.2.4。新脚本依赖其原生版本/SHA256 元数据读取和总内存字段，并保留 0.2.3 修复的 Race 预算与 DNS fallback 链；本仓库不复制 runtime，不重写 Race/DoH/UDP/HTTPS 下载器，也不重新分发另一个实现。现有四架构 zsetup 的构建仍在其仓库执行：

```sh
cd /path/to/linkease-tunnel/zsetup
./scripts/release-targets.sh
./scripts/check-release-artifacts.sh --directory dist/release
./scripts/run-target-smoke.sh --all
```

业务变动不要求重编同版本 zsetup；复用已验证的不可变 release。共享 bootstrap 与单业务脚本生成后先执行测试。业务脚本字节变化必须递增 catalog 的 `APP/VERSION/install.sh` 和 config_version；禁止用新字节覆写旧版本。

```sh
cd /path/to/zsetup-scripts
python3 -B scripts/build-entrypoints.py
sh scripts/check.sh /path/to/linkease-tunnel/zsetup
python3 -B scripts/package-release.py --zsetup-root /path/to/linkease-tunnel/zsetup --collect-ddnsto --require-production-ready
```

输出 `dist/release/binary/`、`scripts-release-manifest.json`、`PACKAGE-SHA256SUMS` 和确定性 tar.gz。使用 `--collect-ddnsto` 时按旧脚本 CDN 路径采集已有产物，自动计算并保存摘要；无须用户另行整理产物清单。不传采集选项或已有目录时只生成开发包，manifest 为 `development-ddnsto-artifacts-required`。打包器复用 zsetup 的 `check-release-artifacts.sh` 和 `generate-product-config.py --installer-catalog catalog.json`；原 `--fastnet-script` 和 S6 暂存流程仍可使用。

## DDNSTO 业务产物输入

旧脚本已确定业务来源、版本指针与文件名。用户要求继续沿用这些来源；采集由现有 zsetup download 执行，HTTPS 三个 primary 竞速、fw.koolcenter.com 最终 fallback 保持不变。不会执行下载的程序或安装真实包：

```sh
python3 -B ddnsto/collect-artifacts.py \
  --zsetup-bin /path/to/linkease-tunnel/zsetup/dist/release/zsetup-linux-x86_64
```

默认输出 `dist/ddnsto-artifacts/`，包含以下目录、自动生成的 artifacts.json 和 acquisition.json。后者记录采集时间、来源 URL 组、版本、大小与摘要：

```text
artifacts.json
openwrt/VERSION
openwrt/VERSION_LITE
openwrt/lite/<VERSION_LITE>/{ddnsto_x86_64,ddnsto_aarch64,ddnsto_arm,ddnsto_mipsel,luci-app-ddnsto,luci-i18n-ddnsto-zh-cn}.ipk
openwrt/standard/<VERSION>/同样六个 .ipk
openwrt/lite-apk/<VERSION_LITE>/同样六个 .apk
openwrt/standard-apk/<VERSION>/同样六个 .apk
linux-binary/ddnsto-standard-4.2.3.tar.gz
```

Linux archive 必须含 `ddnsto-standard-4.2.3/ddnsto.x86_64` 与 `.aarch64` 普通文件。其他已确认版本可追加，脚本用 DDNSTO_VERSION 指定。旧 CDN 的 LuCI 包在可变根目录，新安装将其快照与主包放在相同不可变版本目录，避免在一次安装中混用不同发布。

采集工具自动生成 `artifacts.json`。它也支持维护者提供既有目录；格式如下，所有文件（包括两个版本指针）记录实际摘要：

```json
{
  "schema_version": 1,
  "provenance": "旧脚本 commit / 发布来源与 HTTPS 采集记录",
  "files": [
    {"path": "openwrt/VERSION", "sha256": "采集文件计算得到的真实64位小写摘要"}
  ]
}
```

采集完成后，打包器逐个核对本地文件与采集摘要，再生成各版本的 SHA256SUMS 和 Linux tar 的 SHA256SUMS。旧 CDN 不需要预先提供 checksum metadata。LuCI/语言包只从旧根目录下载一次，再分别复制到对应 Lite/Standard 版本目录；全部 23 次下载汇集 27 个发布文件。重复采集如果同版本文件变了，会拒绝替换旧快照。摘要不会在设备上依赖系统 openssl/sha256sum；Business Installer 通过 HTTPS 取得 checksum metadata，然后使用 zsetup 内置 SHA256 校验每个新包。目录和记录缺项、摘要不符、同版本已有不同字节时，在修改配置指针前拒绝发布包。

```sh
python3 -B scripts/package-release.py \
  --zsetup-root /path/to/linkease-tunnel/zsetup \
  --ddnsto-artifacts /path/to/approved-ddnsto-artifacts \
  --require-production-ready
(cd dist/release && sha256sum -c PACKAGE-SHA256SUMS)
```

这里的 production-ready 指构建输入完整且代码提交干净；manifest 仍标记 `artifacts-verified-canary-required`。真实设备安装、网络故障、回滚与观察窗口仍需完成。不要把测试造的 package bytes 用作生产输入。

## 发布布局和切换顺序

| 文件 | 规则 |
|---|---|
| `binary/zsetup/0.2.4/` | 复用六个不可变 release 文件，包含 SHA256SUMS/manifest |
| `binary/{fastnet,ddnsto}/0.1.3/install.sh` | 不可变业务入口；配置引用它，并记录真实 SHA256/size |
| `binary/{fastnet,ddnsto}/install.sh` | 用户一键入口，可变指针内容，与当前索引脚本完全同字节 |
| `binary/zsetup/config.json` | 完整 Product Configuration schema 1；不与本地字段合并 |
| `binary/zsetup/stable` | exact zsetup version；最后激活 |
| `binary/ddnsto/openwrt/{VERSION,VERSION_LITE}` | 业务版本指针；各版本包和 SHA256SUMS 先部署 |
| DDNSTO 旧安装 URL | 兼容副本，业务代码不重复维护；切换必须完成迁移验证 |

三个 primary 固定是 `dl.istoreos.com`、`fw.d4ctech.com`、`fw20.koolcenter.com`，最终 fallback 固定是 `fw.koolcenter.com`。zsetup installer 明确选择 OS/包管理器/架构，不用一条 wildcard 声称支持所有 DDNSTO 平台。

打包工具不上传公网，不修改服务。原 zsetup `upload-fw-koolcenter.sh` **只识别旧 S6 FastNet 布局**，不能用它直接上传新的多业务包。上线时在受控运维流程里把包放到远端同文件系统 staging，验 PACKAGE-SHA256SUMS；依次部署不可变 zsetup/业务脚本/业务包及摘要，然后业务版本与用户入口，再完整 config.json，stable 最后。各可变文件同文件系统原子 rename，不允许在新版指针前缺少目标文件。版本目录有冲突时拒绝覆盖。

跨站点：先完成四站点所有 Artifact 的 HTTPS 内容/摘要、大小、路径与缓存头回读，再激活各指针；不同站点尚未同步时不公布升级。建议不可变路径 `Cache-Control: public, max-age=31536000, immutable`；config/stable/VERSION 使用 no-cache。更新配置的 stable version 与其 artifacts/min_version 必须一致。

回滚：保存上一份完整配置及可变入口/业务版本指针，用原子 rename 恢复完整集合，stable 最后回退；不可变目录保留。只改 version 字符串却不同时回退 artifacts/min_version 是无效配置。客户端尚在运行的脚本持有原字节，不再下载自己。

本次只交付可审查暂存产物、隔离测试与提交；生产候选已可从既有产物自动生成，公网切换仍需设备 canary 和明确目标发布操作。旧源仓库和线上入口保持原状。

本地打包要求 Python 3.11+、Git、POSIX shell，以及 zsetup 发布检查器所要求的 binutils/UPX 等现有工具。它们是维护者构建依赖，不增加设备首次安装的下载器或 SHA 工具依赖。

当前脚本版本为 0.1.3（config_version `scripts-0.1.3`），最低 native 版本为 0.2.4。此前 0.1.1/0.2.3 不可变目录保持原字节；新脚本不能配旧 native 产物。此版本设备端不再调用 awk/sed；维护端 Python/Git/UPX 等依赖不变。


## 业务模块与正式服务器目录

源码 `fastnet/`、`ddnsto/` 与正式 URL `/binary/fastnet/`、`/binary/ddnsto/` 对应，但只上传发布工具选出的文件；不得直接把仓库文件夹整体同步到网站。

| 源码职责 | 发布目录 | 正式入口 |
|---|---|---|
| fastnet/install.sh、业务测试/说明 | binary/fastnet/0.1.3/install.sh、binary/fastnet/install.sh | /binary/fastnet/install.sh |
| ddnsto/install.sh、release.py、采集/业务测试 | binary/ddnsto/0.1.3/install.sh、业务包/摘要、兼容入口 | /binary/ddnsto/install.sh |
| lib/bootstrap.sh、公共构建工具 | 已嵌入业务入口，不单独发布 | 无 |
| 权威 zsetup release + 根 catalog.json | binary/zsetup/0.2.4/、config.json、stable | zsetup install APP |

服务器所需文件已集中到 dist/release/binary/{fastnet,ddnsto,zsetup}/；PACKAGE-SHA256SUMS 与 scripts-release-manifest.json 用于部署审核，放在部署 staging/记录目录。确定性 tar.gz 为传输包，解包后校验，按 binary/ 下的相对路径部署到实际网站的 /binary/ 目录。

上传按文件增量进行，保留服务器已有文件和历史版本。FastNet 的 version.txt 及与其中 SHA256 匹配的各架构二进制由其既有发布流程提供，本仓库只打包 FastNet 安装脚本；新服务器必须预先取得这些产物。DDNSTO 与 native zsetup 的必需产物随完整候选包提供。禁止用清空目录或同步删除的方式部署。

激活顺序：上传并逐站核对不可变 native/业务脚本/业务包和 SHA256 → 确认 FastNet 既有产物可用 → 更新业务版本与公开入口/兼容入口 → 原子更新完整 config.json → stable 最后。所有 primary 与 final fallback 都完成回读后，再对用户公布；保留前一完整配置和可变指针集合用于回滚。

版本路径设置 immutable 缓存；install.sh、config.json、stable、业务 VERSION/version.txt 和未版本化 SHA256SUMS 使用 no-cache。内部 business.sh/main.sh、Python 维护工具、tests、README 不进入静态网站。

开始实际部署前需具备目标服务器、/binary/ 对应的文件系统路径、上传方式/账号、四站点回源关系与 canary 设备。本次整理生成可审查本地候选，不连接未知正式服务器。

旧维护命令 scripts/collect-ddnsto-artifacts.py 保留为 ddnsto/collect-artifacts.py 的兼容符号链接；业务采集实现只维护在模块中。
