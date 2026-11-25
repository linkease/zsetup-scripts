# DDNSTO 标准入口

DDNSTO 是 [apps layout v2](../apps-layout-v2.md) 的参考实现。

```text
apps/ddnsto/
  app.json
  install.sh
  install.ps1
  install.md
  versions/0.3.0/
    install.sh
    install.ps1
```

POSIX 标准入口覆盖 Linux、OpenWrt 和 macOS；PowerShell 标准入口覆盖 Windows；
`install.md` 是 AI Agent 和人工安装的标准指南。清单和三个标准入口都在应用目录内，维护源码与模板位于 `sources/ddnsto/`，测试位于
`tests/apps/ddnsto/`。不生成兼容别名。

运维将 `run.ddnsto.com` 的 `/install.sh`、`/install.ps1` 和 `/install.md`
直接映射到上述三个文件。域名不产生第二份目录或文件副本。不生成 `_sites`、
`current`、`agent/versions`、`i`、`i.ps1`、`ddnsto-install.sh` 或其他兼容结构。

在仓库根目录运行 `python3 -B scripts/build-ddnsto-products.py` 和
`python3 -B scripts/build.py`，提交生成的入口和配置；`apps/SHA256SUMS` 仅在本地生成并
由 Git 忽略，整体发布时由协调器重新生成并打包。整体发布使用
`scripts/publish-apps.py`；仅生成文件不表示已经上线。
