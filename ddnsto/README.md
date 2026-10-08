# DDNSTO

唯一对外脚本为 `install.sh`，由本目录 `business.sh`、`main.sh` 和共享 `../lib/bootstrap.sh` 生成。OpenWrt/Linux 业务函数均在本模块维护；普通执行和 `zsetup install ddnsto` 使用同一业务实现。依赖 zsetup >=0.2.4，不调用 awk/sed。

发布后用户入口：

```sh
zsetup install ddnsto -- --token 'YOUR_TOKEN'
sh -c "$(curl -fsSL https://fw.koolcenter.com/binary/ddnsto/install.sh)" -- --token 'YOUR_TOKEN'
```

OpenWrt 支持 opkg/apk × x86_64/aarch64/armv7/mipsel；总内存低于 900 MiB 自动选 Lite，可传 `--force-version lite|standard`。token 可选；`--verify-status` 请求服务检查。Linux 支持 x86_64/aarch64，默认 Standard 4.2.3，无终端时必须提供 token。参数、退出码及交互详情见 [统一协议](../docs/ai-contract.md)。

本模块包含：

- business.sh/main.sh/install.sh：维护源码与唯一生成入口。
- collect-artifacts.py：沿用已验证旧 CDN，通过 zsetup HTTPS 采集已有包并计算摘要。
- release.py：校验业务输入、Linux tar 成员及摘要，生成版本化业务目录。共享摘要/不可变复制复用 scripts/release_common.py。
- tests/：双入口、平台、参数、缓存、失败回收、采集和业务打包测试。

服务器模块目录：

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

兼容 URL 发布为与 install.sh 相同的实际文件，无须服务器支持符号链接。旧源仓库与已上线旧文件不得在迁移验证前删除。business/main、Python 工具、测试和 README 不发布。

模块命令（从仓库根目录执行）：

```sh
python3 -B ddnsto/collect-artifacts.py --zsetup-bin /path/to/zsetup/dist/release/zsetup-linux-x86_64
python3 -B ddnsto/tests/ddnsto_test.py /path/to/zsetup/dist/release/zsetup-linux-x86_64 /path/to/linkease-tunnel
python3 -B ddnsto/tests/artifact_package_test.py /path/to/zsetup
python3 -B ddnsto/tests/collect_ddnsto_test.py
```

已有产物目录可直接交给统一 package-release.py 的 --ddnsto-artifacts，避免重复网络采集。完整配置必须与 FastNet、native zsetup 一起生成；发布顺序见 [发布文档](../docs/release.md)。
