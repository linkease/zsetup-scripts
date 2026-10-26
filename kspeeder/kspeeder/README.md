# KSpeeder 二进制安装器

唯一源码是本目录的 `business.sh`、`main.sh` 及 `../lib`；根生成器输出
`kspeeder-install.sh`。软件标识为 `kspeeder`，脚本版本 0.1.0，最低 Linux
zsetup 0.5.0。本地候选尚未发布，独立发布后入口为：

```sh
zsetup install kspeeder --foreground
sh -c "$(curl -fsSL https://fw.koolcenter.com/binary/kspeeder/kspeeder-install.sh)"
```

默认安装到 `~/.local/lib/linkease/kspeeder/versions/VERSION/bin/kspeeder`，
命令链接为 `~/.local/bin/kspeeder`。支持 `--installer-prefix` 与
`--installer-work-dir` 指定持久目录；与 ks-cli 共用所有权保护、下载校验、
精确版本检查及 current/previous 切换。

这是二进制部署入口，不安装 ks-cli、不注册或启动系统服务、不改变端口或
缓存配置。安装成功不代表加速服务已就绪。未来服务工作流必须显式引用
此处的最终命令路径；不能再运行会把产品复制到默认目录的官方安装器。

版本与摘要读取 `https://kspeeder.com/bin/version.txt`，Linux 产品命名
`iStoreEnhance-linux.amd64/arm64/arm`，安装后的命令名为 `kspeeder`。
原生 `.exe`/Mac 产品有自己的摘要，但本轮未接入桌面安装与服务管理。
Linux 支持范围及来源覆盖与 [`../ks-cli/README.md`](../ks-cli/README.md) 一致。
服务端实测约12MB；缺精确size字段时采用32MiB上限，不扩展为完整服务验收。

测试见 `../tests/binary_install_test.py`，未来同步流程见
[`../../docs/kspeeder-installers.md`](../../docs/kspeeder-installers.md)。
