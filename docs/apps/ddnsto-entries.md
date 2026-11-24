# DDNSTO 标准入口

DDNSTO 是 [apps layout v2](../apps-layout-v2.md) 的参考实现。

```text
apps/ddnsto/
  app.json
  install.sh
  install.ps1
  versions/0.3.0/
    install.sh
    install.ps1
```

POSIX 标准入口覆盖 Linux、OpenWrt 和 macOS；PowerShell 标准入口覆盖 Windows。
清单和标准入口都在应用目录内，维护源码与模板位于 `sources/ddnsto/`，测试位于
`tests/apps/ddnsto/`。不生成兼容别名。

`run.ddnsto.com` 的推荐入口属于网站运行时，生成到
`apps/_sites/run.ddnsto.com/`。运维将 `/install.sh`、`/install.ps1` 和
`/ddnsto-install/*` 映射到该目录，网站 URL 不再决定应用目录内的文件内容。
不生成 `i`、`i.ps1`、`ddnsto-install.sh` 或其他兼容别名。

在仓库根目录运行 `python3 -B scripts/build-ddnsto-products.py` 和
`python3 -B scripts/build.py`，提交生成文件及 `apps/SHA256SUMS`。整体发布使用
`scripts/publish-apps.py`；仅生成文件不表示已经上线。
