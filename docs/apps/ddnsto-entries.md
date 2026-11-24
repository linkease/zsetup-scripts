# DDNSTO 安装入口

`apps/ddnsto/` 随完整 `apps/` 同步到 `/binary/zsetup-scripts/apps/ddnsto/`。

- 控制台通用 Shell 入口：`i`，对应 `https://run.ddnsto.com/i`。
- 控制台 Windows CLI 入口：`i.ps1`，对应 `https://run.ddnsto.com/i.ps1`。
- 推荐清单、按摘要固定的执行脚本、AI 安装指南：`ddnsto-install/`。
- `install.sh` / `ddnsto-install.sh`：现有 zsetup 原生索引入口，平台范围由 apps 索引决定。
- 维护源码与模板位于仓库 `sources/ddnsto/`，不随部署目录发布。

在仓库根目录运行 `python3 -B scripts/build-ddnsto-products.py` 和
`python3 -B scripts/build.py`，提交生成文件及 `apps/SHA256SUMS`。
发布沿用 `scripts/publish-apps.py`，域名须由运维按路径映射；仅文件入库不表示已上线。
详细步骤见仓库 `docs/ddnsto-install-deployment.md`。
