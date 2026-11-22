# KS-CLI 标准二进制安装器

脚本版本 0.1.2，最低 zsetup 0.5.0。支持 Linux x86_64/aarch64/armv7、
macOS Intel/Apple Silicon、Windows x86_64/arm64。Shell 与 PowerShell 入口均由
共享源码生成，并以同字节 payload 发布到 `apps/ks-cli/0.1.2/`。

安装器从四站点 `/binary/kspeeder/release.txt` 读取业务版本和不可变发布 ID，
再从 `releases/RELEASE_ID/` 获取 `SHA256SUMS` 与平台二进制。下载摘要和程序
`version` 输出必须一致；同版本不同字节拒绝替换。

默认只做用户级二进制安装，不执行 KS-CLI 业务命令、不安装或启动 KSpeeder 服务。
POSIX 命令位于 `~/.local/bin/ks-cli`；Windows 命令位于
`%LOCALAPPDATA%\KSpeeder\bin\ks-cli.exe`。可用 `--installer-prefix` 和
`--installer-work-dir` 指定持久目录。

```sh
zsetup install ks-cli --foreground
sh -c "$(curl -fsSL https://fw.koolcenter.com/binary/zsetup-scripts/apps/ks-cli/ks-cli-install.sh)"
```

产品同步、发布 ID 布局和回滚规则见
[`../../docs/kspeeder-product-mirror.md`](../../docs/kspeeder-product-mirror.md)。
