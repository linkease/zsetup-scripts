# DDNSTO

Linux/OpenWrt 的唯一统一入口为 `install.sh`，由本目录 `business.sh`、`main.sh` 和共享 `../lib/bootstrap.sh` 生成。Windows 和 macOS 使用同目录的原生入口 `install.ps1` 与 `install-macos.sh`；它们直接安装已发布的 DDNSTO CLI 归档，并各自注册平台服务生命周期。依赖 zsetup >=0.2.4 的统一入口仍只适用于 POSIX/Linux/OpenWrt。

发布后用户入口：

```sh
zsetup install ddnsto -- --token 'YOUR_TOKEN'
sh -c "$(curl -fsSL https://fw.koolcenter.com/binary/ddnsto/install.sh)" -- --token 'YOUR_TOKEN'
```

OpenWrt 支持 opkg/apk × x86_64/aarch64/armv7/mipsel；总内存低于 900 MiB 自动选 Lite，可传 `--force-version lite|standard`。token 可选；`--verify-status` 请求服务检查。Linux 支持 x86_64/aarch64，默认 Standard 4.2.3，无终端时必须提供 token。Windows 入口支持 x86_64 CLI 4.2.1，在 Windows 10 x64 WOW64 / PowerShell 5.1 验证范围内使用计划任务启动；macOS 入口支持 Intel/Apple Silicon CLI 4.2.1，使用用户级 launchd。Windows/macOS 的 4.2.1 归档 SHA256 固定在入口脚本中，升级新版本前必须更新脚本、测试和发布配置。参数、退出码及交互详情见 [统一协议](../docs/ai-contract.md)。

本模块包含：

- business.sh/main.sh/install.sh：维护源码与唯一生成入口。
- release.py：将同一 install.sh 发布到旧兼容 URL；产品包不在本仓库构建或打包。
- tests/：通过隔离 HTTPS 产品服务器验证双入口、平台、参数、缓存、进度和失败回收。

服务器完整模块目录（产品文件由业务发布流程提前部署，本仓库仅发布 install.sh 及兼容入口）：

```text
binary/ddnsto/
  0.1.3/install.sh
  install.sh
  openwrt/VERSION
  openwrt/VERSION_LITE
  openwrt/<standard|lite|standard-apk|lite-apk>/<VERSION>/包与 SHA256SUMS
  linux-binary/ddnsto-standard-4.2.3.tar.gz
  linux-binary/SHA256SUMS
  openwrt/<install_ddnsto.sh|install_ddnsto_business.sh|setup_ddnsto.sh>
  linux-binary/install_ddnsto_linux.sh
```

兼容 URL 发布为与 install.sh 相同的实际文件，无须服务器支持符号链接。旧源仓库与已上线旧文件不得在迁移验证前删除。仓库中的历史源码位于 [legacy/](../legacy/README.md)，不进入发布包；当前入口为 ddnsto/install.sh。business/main、Python 工具、测试和 README 不发布。

模块命令（从仓库根目录执行）：

```sh
python3 -B ddnsto/tests/ddnsto_test.py /path/to/zsetup/dist/release/zsetup-linux-x86_64 /path/to/linkease-tunnel
python3 -B ddnsto/tests/cross_platform_installer_test.py
```

业务发布者从其实际发布字节生成 SHA256SUMS，并先部署 OpenWrt 每个版本目录中的主包、LuCI/语言包和摘要，以及 Linux tar 和摘要，最后更新 VERSION/VERSION_LITE。安装脚本只从服务器读取版本和摘要，再调用 zsetup download 校验产品。完整安装配置仍与 FastNet、native zsetup 一起生成；发布顺序见 [发布文档](../docs/release.md)。
