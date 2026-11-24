# DDNSTO 标准入口文件名

本次仅本地修改，未提交、推送或部署。

- `apps/ddnsto/install.sh`、`install.ps1` 分别复用现有 Shell / PowerShell 推荐入口字节；不再生成 `i`、`i.ps1`。
- `ddnsto-install.sh` 保留原生索引兼容入口；原生索引、0.2.4/0.2.5 安装器及历史摘要文件不变。
- AI 指南更新至 1.2.2，新增摘要快照，旧快照保留。
- 控制台、官网的命令及当前部署说明改用标准文件名。先上线脚本和完整依赖、回读域名映射，再发布前端。旧短路径兼容由运维配置重定向。

验证：

- 先修改站点测试，确认旧目录仍有 `i`、站点缺少标准入口；修复生成器后通过。
- DDNSTO 专项 `python3 -B -m unittest discover -s tests -p 'ddnsto*test.py'`：215 项，172 通过、43 跳过（包含站点 9 项）。
- AI 指南 3 项；标准 Shell / PowerShell 入口、apps 所有权契约通过。
- 产品配置及 apps 构建 `--check`、公开树检查、Shell 语法、diff 检查通过。
- 控制台相关 6 文件：55 通过、1 跳过；生产构建通过，保留既有大 chunk 提示。
- 官网 `npm run validate` 通过，Node 测试 12/12；保留既有 execCommand 弃用提示。

限制：通用 `unittest discover -s tests -p '*test.py'` 不是完整门禁的正确调用方式，277 项中有 26 失败、6 错误、43 跳过。部分原生测试需要独立命令行参数（扫描参数被误当二进制路径），另有旧 module_layout / publication 假设（publication 测试模拟 0.2.5、工具仍固定 0.2.4）。本次未修改这些无关代码，不宣称全仓门禁通过。未运行浏览器、真机或公网验收。
