# ks-cli 二进制安装器

唯一源码是本目录的 `business.sh`、`main.sh` 及 `../lib`；根生成器输出
`ks-cli-install.sh`。软件标识为 `ks-cli`，脚本版本 0.1.0，最低 Linux
zsetup 0.5.0。Linux入口已于2026-10-26独立发布，以下公网命令已生效。

```sh
zsetup install ks-cli --foreground
sh -c "$(curl -fsSL https://fw.koolcenter.com/binary/ks-cli/ks-cli-install.sh)"
```

默认安装到 `~/.local/lib/linkease/ks-cli/versions/VERSION/bin/ks-cli`，
命令链接为 `~/.local/bin/ks-cli`，已有其他来源命令会拒绝覆盖。
指定持久目录：

```sh
sh ks-cli-install.sh --installer-prefix /persistent/software/ks-cli \
  --installer-work-dir /persistent/staging/ks-cli
```

安装只接受共享的前置 `--installer-*` 参数；不转发或执行业务参数。
安装完成后由调用者执行实际命令，不默认安装、启动或探测 KSpeeder 服务。
stdout 为 `application/version/command/prefix` 四行字段，进度写 stderr；
失败保留原退出码，不能将后台启动成功当作最终安装成功。

元数据来源 `https://kspeeder.com/bin/ks-cli-version.txt`；选择
`SHA256_linux_amd64/arm64/arm`，产品为同目录 `ks-cli-linux-ARCH`。
使用 zsetup 下载与 SHA256 复验、精确版本检查；同版本不同摘要拒绝替换。
默认保留 current/previous，失败或取消保留旧入口。大小元数据尚缺，按实际
约15MB产物设置32MiB下载上限及共享空间预算，不声称精确空间估计。

首期索引为普通 Linux（linux/ubuntu/debian/centos/rhel），
x86_64/aarch64/armv7；ARM 是命名/协议 fixture 覆盖，不是设备运行验收。
OpenWrt 不套用普通 Linux 包，继续使用它自己的包管理路径。
Windows/macOS 客户端缺发布摘要，未登记或生成可用安装入口。

来源覆盖 `KSPEEDER_PRODUCT_BASES` 是以空格分隔的 HTTPS 根地址（不含 `/bin`），
可选 `KSPEEDER_PRODUCT_FALLBACK`；仅用于受控部署和隔离测试，与 zsetup
bootstrap/安装器镜像分离，不自动将官方产品映射到我们的服务器。
测试见 `../tests/binary_install_test.py`，未来同步流程见
[`../../docs/kspeeder-installers.md`](../../docs/kspeeder-installers.md)。
