# FastNet

唯一对外脚本为 `fastnet-install.sh`，由本目录 `business.sh`、`main.sh` 和共享 `../lib/bootstrap.sh` 生成。普通执行和 `zsetup install fastnet` 汇合到同一 `fastnet_install` 函数；参数原样传给 FastNet。当前存储候选要求 Rust zsetup >=0.5.0，不调用 awk/sed。

发布后用户入口：

```sh
zsetup install fastnet
sh -c "$(curl -fsSL https://fw.koolcenter.com/binary/fastnet/fastnet-install.sh)"
```

支持 Linux/OpenWrt 的 x86_64、aarch64、armv7；FastNet 的菜单和非交互参数由业务程序定义，不在安装器中虚构。平台/不可变路径记录位于根目录 catalog.json。本轮脚本候选为 0.1.8，尚未上线。独立发布范围和实际服务器差异见 [FastNet 独立发布](../docs/fastnet-independent-release.md)。

服务器模块目录：

```text
binary/fastnet/
  0.1.8/fastnet-install.sh   # 候选：索引引用的不可变版本
  fastnet-install.sh # 用户的一键入口
  install.sh         # 原 URL 的同字节兼容副本
  version.txt        # 既有 FastNet 发布流程提供
  FastNet-<VERSION>.<amd64|arm64|armv7>  # 既有产物，保留
```

统一打包器发布本模块脚本，不负责重新构建或采集 FastNet 二进制。目标服务器必须保留与 version.txt 中版本/摘要匹配的既有业务产物；新服务器首次上线时由 FastNet 业务发布流程提供这些文件。business.sh/main.sh/tests/README 不上传公网。

模块测试：

```sh
python3 -B fastnet/tests/fastnet_bootstrap_test.py /path/to/zsetup/dist/release/zsetup-linux-x86_64
python3 -B fastnet/tests/fastnet_zsetup_test.py /path/to/zsetup/dist/release/zsetup-linux-x86_64 /path/to/linkease-tunnel
```

所有命令从仓库根目录执行。共享构建、完整验收和发布顺序见 [发布文档](../docs/release.md)。旧 fastnet-install.sh 源码归档在 [legacy/](../legacy/README.md) 供参考，当前入口为 fastnet/fastnet-install.sh。
