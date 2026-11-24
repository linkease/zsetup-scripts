# Agent 安装文档发布

`install.md` 是面向 Agent 的唯一安装指南。前端复制固定文档链接、账号输入及业务环境要求；后续更新指南不需要重新构建控制台。

- 固定地址：`https://run.ddnsto.com/ddnsto-install/agent/install.md`。
- 唯一维护及打包仓库：`zsetup-scripts`；不再由 `ddns-server` 渲染 Host，不进入 `ddnsto-static`。
- 文档使用真实固定域名，不再含 `.invalid` 模板。
- `scripts/build.py` 复用站点打包器将指南与推荐入口生成到 `apps/ddnsto/`；历史指南位于 `ddnsto-install/agent/versions/<SHA256>/install.md`。
- `run.ddnsto.com` 可由运维以 301/302 按路径指向下载站 apps/ddnsto。读取时最多五次 HTTPS 跳转，拒绝 HTTP 降级；固定入口及指南使用 no-store，不可变正文可长期缓存。

## 发布与回滚

1. 修改指南时递增文档版本和末尾标记。审核目标确认、权限、平台、业务环境、失败及验收约束。
2. 本地执行 `python3 -B tests/apps/ddnsto/internal/agent_guide_test.py`；测试使用假 curl，不执行真实安装。
3. 按 `docs/ddnsto-install-deployment.md` 生成并审核 apps 内的完整产物，提交生成文件及校验清单；提交源码不等于发布。
4. 获单独发布授权后先传历史文档，再原子切换固定文档。固定文档与历史文档应为相同字节，不进行服务器动态渲染。
5. HTTPS 回读检查内容、UTF-8、缓存、跳转和末尾标记；失败停止发布。回滚从审核的历史文档恢复固定文件，保留所有历史字节。

业务环境由调用参数决定：生产默认，测试要求 `--env test` / `-Environment test`。Windows GUI 不自动进入测试环境，测试需求需明确选择 CLI。文档更新不应偷偷切换设备现有环境。

本轮仅本地准备，域名未部署、未做公网或真实 Agent 安装验收。未来 skills 和生成远程访问链接不属于当前能力。
