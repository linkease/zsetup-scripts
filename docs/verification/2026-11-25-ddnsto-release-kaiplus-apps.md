# 完整 apps 最新版发布中的 DDNSTO 范围记录

状态：随完整 zsetup-scripts/apps 正式发布并通过源站及四站字节核验。

用户于 2026-11-25 明确要求在 KaiPlus Skills 更新功能完整验收后部署最新 zsetup-scripts。
因此发布范围为完整已提交 apps 树，不单独拼接 kai-skills 子目录。本轮不操作任何
DDNSTO 客户端设备，不改变客户端推荐版本、产品 URL、摘要或服务策略。

源站为 `root@192.168.3.1`，固定公开目录为
`/mnt/sata3-1/istore-data/public_html/binary/zsetup-scripts/apps`。
发布前完整清单摘要为 `0e00b2c06fc06b4d1e40ff1ab5179e80463d290506833dc01d148c595aa758cf`。
本地基线为 `9c012ef`，已有 DDNSTO 安装器 0.3.2，源站旧 app 元数据仍引用旧版。
完整候选还包含共享 shell/PowerShell 标准入口修复，不能将生产差异描述为只改了 KaiPlus。

## 已有证据与不变项

- [0.3.1 标准入口修复](2026-11-24-ddnsto-release-entry-repair.md)。
- [0.3.2 macOS 目录修复](2026-11-25-ddnsto-release-macos-directory.md)。
- [0.3.2 既有五台设备回归](2026-11-25-ddnsto-full-device-regression.md)：4 台成功，
  华硕已装 4.2.9，高于推荐 4.2.8，触发防降级保护；不声称华硕安装成功。
- 源站旧不可变 `versions/0.3.0/install.sh`、`install.ps1` 与本地历史字节一致，
  新增 0.3.1/0.3.2 版本不覆盖旧路径。
- 客户端产品版本和摘要继续使用已审核的 `sources/ddnsto/platform-releases.json`；
  本轮不重新构建或发布产品二进制，不以安装器脚本发布替代新的设备验收。

## 本轮检查与部署

本机完整 `scripts/check.sh --native-bin`、旧 Shell 兼容补验、源站和四站 HTTPS
校验的最终结果及精确发布 ID 已填写于
`docs/verification/2026-11-25-kaiplus-skills-apps-publish.md`。
所有新文件先暂存，公开不可变字节核验后才切换标准入口、配置与完整 SHA256SUMS。
回退使用本次协调器快照，只回退安装入口和索引，不删除历史文件或自动降级任何设备。
