# DDNSTO 完整安装站点纳入 apps 发布树

状态：本地实现及验证完成；未提交、未推送、未发布。

授权范围：从 main 8e83153 开始，生成控制台使用的完整安装资源到
`apps/ddnsto/`，使用 run.ddnsto.com，更新控制台及部署说明。
不改变客户端版本、产品摘要、zsetup 核心及其他应用安装行为。
正式发布和真机操作需要另行授权。

现有标准 install.sh 继续走 apps 原生索引；新增 i/i.ps1 保留控制台的
跨平台推荐协议，不把未验收平台添加到原生索引。
测试先验证公共树缺失文件和部署阶段缺失摘要路径识别，再实现生成。

## 实现与验证

- `scripts/build.py` 复用现有推荐/站点打包器，生成 `apps/ddnsto/i`、`i.ps1`、
  `ddnsto-install/current/` 和 `ddnsto-install/agent/`，纳入 `apps/SHA256SUMS`。
- 本次使用原打包器默认 shell-first；不启用另行审核的 native-first。
- `--check` 阻止缺失或漂移的成品；未展开模板标记导致构建失败。
- 旧摘要文件保留；发布协调器及 shell 事务将摘要正文/历史指南先暂存，后切换可变文件。
- 控制台、调试维护命令和 AI 指南统一使用 run.ddnsto.com；环境参数规则不变。
- 客户端元数据、标准 install.sh、0.2.4/installer.sh、原生索引均无字节变更。

| 验证 | 结果 |
|---|---|
| TDD 缺失公共入口与摘要暂存识别 | 修改前 2 项失败，修改后通过 |
| TDD 未展开推荐模板 | 修改前错误地成功，修改后拒绝构建 |
| TDD 控制台域名 | 修改前 2 项失败，修改后通过 |
| 新增 apps 站点测试 | 5 项通过；包含漂移拒绝、历史保留、stage/activate/verify/rollback |
| 独立候选兼容打包 | 1 项通过 |
| DDNSTO 顶层测试 | 206 项：163 通过、43 跳过，无失败 |
| tests/contracts 全部脚本 | 通过，包含全树校验和完整发布事务 |
| AI 指南协议 | 3 项通过 |
| build.py / 产品生成器 --check、public-tree、SHA256SUMS | 通过 |
| Shell 入口及 publish.sh 语法 | 当前 sh 通过 |
| 前端相关测试 | 55 通过、1 跳过 |
| production / staging 前端构建 | 均通过，保留既有大 chunk 警告 |
| meta 文档验证 | PASS：links=1662 records=57 |

跳过项涉及 Windows/PowerShell、显式可销毁容器、真实 native 集成、旧 Shell 解释器；
未配置这些环境，不计为验收通过。未执行完整依赖 native 的 check.sh、浏览器 E2E 或真机安装。
首次回归发现 pull 遗留旧 ddnsto/kai-skills 目录只有 Python 缓存；已可恢复移出，
重新执行后所有上述检查通过。其他仓库缓存和历史 dist 未清理。

当前本地摘要（不是上线授权）：

- `apps/ddnsto/i`：`ada4030e9b5b8c9b883992d5a9f47b7e6ad706f7e8272bbb2404e152fe5a6f9f`
- `apps/ddnsto/i.ps1`：`4b953049c5b5d1505b12ff158c6d02857cea257d8392113c2153d3a0053ccad7`
- `apps/SHA256SUMS`：`3ff69fe9db86a37d1c89aa23c2e5c54fa990bf887ae53319f6a34d5453f4f5af`

## 后续目录收敛

用户确认后，将维护源码、模板、平台推荐配置和 app.json 移至 `sources/ddnsto/`，
入口说明和 review.json 移至 docs；公共目录仅保留运行产物。生成器、发布元数据、
测试路径与公共树检查同步适配。新增两个目录边界测试先失败、实现后通过。
完整顶层 DDNSTO 回归为 208 项：165 通过、43 跳过；发布契约测试全部通过。
现有标准执行脚本和索引未改变，两个短入口摘要与整理前一致。
此调整未删除远端旧源码，也未提交、推送或部署。

## 发布交接

后续先审核并获准提交/推送，再使用已有 publish-apps.py prepare/plan 取得干净候选，
按精确 release ID 单独授权发布。未绕过已提交门禁创建正式候选。
运维需按 docs/ddnsto-install-deployment.md 将 run.ddnsto.com 的 i、i.ps1 和
ddnsto-install 路径映射至下载站对应文件；目前未操作该路由或任何服务器。
公网资源与设备验收仍未进行，不能将本地通过写为已经上线。
