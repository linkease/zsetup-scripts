# 复用现有下载站与 zsetup0.4.0 验证

日期：2026-10-14 UTC。用户要求继续复用现有 zsetup 下载地址完成一键安装，不新增下载基础设施。

## 核实的现状

- 官方 `https://fw.koolcenter.com/binary/zsetup/` 已有0.4.0；`stable`、`stable-windows` 均为0.4.0。
- `config.json` 当前只有 FastNet installer，`config-windows.json` 的 installers 为空。直接 DDNSTO 入口无需修改它们。
- 上游 `0.4.0/release-acceptance.json` 将 Linux/Windows 列为激活平台，macOS仍为未原生验收的候选。本轮未据此扩大 DDNSTO 平台通过范围。
- 正式 DDNSTO 入口及 Linux/OpenWrt 业务 SHA256SUMS 仍缺失；业务 VERSION/VERSION_LITE 可读取。完整写入清单见 [现有站点发布说明](publish-existing-download-site.md)。

## 真实 native 与来源验证

从现有官方下载文件，在执行前与官方 SHA256SUMS 核对：

| 文件 | SHA256 |
|---|---|
| Linux x86_64 0.4.0 | `553d01dce8b36b82b83662ab89d38c00234cdc5b2855d9a0925f44d7a5374d6e` |
| Windows i686 0.4.0 | `858633b03f4808417bc4724f28e8ab0cb17c9f09fe4e665c9532f488cc1f83a3` |

- Linux二进制实际执行 `--version`、`--help`、`context --json` 成功。
- 真实0.4.0 `download` 从现有 fw.koolcenter.com 获取 Windows native并按上述摘要验证成功；未关闭 TLS。
- 真实维护源码 `lib/bootstrap.sh` 在全新临时目录执行 `bootstrap_zsetup`，以官方站为源自动读取 stable、获取0.4.0并核对摘要，成功返回新目录中的 rescue native；没有在测试站复制 native 或搭建新下载服务。
- Windows文件实际为 PE32/i686，摘要已核对；本轮不在 Linux 上执行 PE，也不宣称完成 Windows 原生 canary。

## 测试证书兼容性诊断

首次使用0.4.0运行业务夹具，在首次 HTTPS metadata 下载时报退出14（secure connection failed），没有进入安装。

最小差分探针保持同一 IP SAN、同一信任 CA和同一原生下载命令：

- 直接把 CA证书作为服务器叶子证书：退出14。
- 使用同一 CA签发 `CA:FALSE` 的服务器叶子证书：退出0。

这排除了自定义 CA参数完全失效或 loopback IP不能校验的猜测，定位为旧测试夹具的证书用法。修正 `ddnsto/tests/ddnsto_test.py` 为独立 CA和叶子证书，继续使用 `--ca-file` 验证，无忽略证书或 HTTP降级。修正后旧0.3.0及新0.4.0直接入口回归都通过。

## 0.1.7 改动与回归

- Windows自动引导改用已发布0.4.0及固定官方摘要；先更新行为测试并观察旧实现校验失败，再修改生产脚本。
- Linux/OpenWrt自动引导本来就跟随官方stable，无需更改下载内核或业务调用协议。macOS保留0.3.0，未盲目跟随候选0.4.0。
- 版本/config升级为0.1.7；FastNet仍0.1.3。构建 `dist/ddnsto-entrypoints-0.1.7/`，只有业务入口与本地manifest/摘要，不含 native或客户端包。
- 两个 native版本分别运行 direct-only业务矩阵：Linux、OpenWrt opkg/apk × 四架构选择、冷引导、摘要/缓存/失败路径通过。包管理器及服务管理边界是隔离夹具，不是真实四架构设备安装。
- macOS12项、POSIX输入5项、Linux服务8项、Windows行为/引导两组通过；Windows测试由 Linux pwsh执行。
- 发布核验4项、独立入口打包1项、桌面隔离1项、模块布局、生成文件一致性和 diff检查通过。
- 额外尝试0.4.0索引安装夹具，仍返回17 `install_failed`，没有记录业务入口下载。它未被标为通过，亦未修改全局索引来掩盖失败。直接入口路径不依赖索引模式。

复现（脚本仓库根目录）：

```sh
python3 -B ddnsto/tests/ddnsto_test.py /path/to/zsetup-0.4.0-linux-x86_64 /tmp --direct-only
PWSH_BIN=/path/to/pwsh python3 -B ddnsto/tests/cross_platform_installer_test.py
python3 -B scripts/build-entrypoints.py --check
python3 -B scripts/package-entrypoints.py --output /new/candidate-directory
```

## 发布状态与限制

本轮只读访问正式站点，未写入、未激活0.1.7、未新建下载服务器，未覆盖此前测试站0.1.6候选。没有重新执行真实 DDNSTO设备服务安装；此前0.1.6的 Linux OpenRC真实证据仍有效，但不得转述为0.4.0全平台原生安装通过。

尚缺现有下载站的发布脚本/上传方式、准确服务器目标和目录；已向维护者询问。原生 canary、业务元数据补齐以及正式别名切换仍是发布门槛。源码改动和候选均未提交或推送。
