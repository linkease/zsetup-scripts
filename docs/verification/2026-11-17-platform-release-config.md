# 分平台推荐配置验证（2026-11-17）

## 范围

仅修改 zsetup-scripts。本地配置集中化，原生六平台版本、摘要、华硕包大小保持迁移前值；
未改 zsetup 核心、前端、设备、测试站或正式站。Windows 为 CLI 配置，不包括控制台 GUI 下载入口。

配置文件：`ddnsto/platform-releases.json`。构建入口：`scripts/build-entrypoints.py`。
模板只在维护者机器展开，设备执行带固定产品校验值的自包含脚本。

## 自动测试

- `DDNSTO_TEST_NATIVE=/tmp/ddnsto-zsetup-audit.b6JOZ8/zsetup python3 -B -m unittest discover -s tests -p 'ddnsto*test.py'`：
  184 项，149 通过、35 跳过。缺少 Windows PowerShell/专用运行环境的项目未假报通过。

- 新增配置测试 9 项：输出一致、各平台版本隔离、Linux/OpenWrt 独立选择、非法版本/摘要拒绝、
  缺失平台及群晖客户端/包版本不匹配拒绝、不同 macOS 版本的真实 shell `--plan`、
  过期输出拒绝且不改写、缺失模板拒绝、原健康协议兼容门槛不随推荐版本扩大。
  初始 6 项在生成器实现前失败；缺失模板校验也先观察到失败再补实现。
- 新增推荐打包测试：配置未生成时拒绝打包（实现前失败）；组合入口过期时也拒绝。
- `python3 -B scripts/build-entrypoints.py --check` 和 `git diff --check` 通过。
- `ddnsto/tests/pinned_products_test.py`：6 项通过，既有发布包摘要未改变。
- `ddnsto/tests/macos_behavior_test.py`：61 项通过。
- 标准 `scripts/check.sh --native-bin /tmp/ddnsto-zsetup-audit.b6JOZ8/zsetup`：
  软件、模块、DDNSTO 默认流程、推荐入口、macOS 默认流程 18 项和诊断 12 项、
  有界提取、事务、持久启动器等检查通过；在 `privilege_bridge_test.py` 因环境禁止
  `unshare` 写入 `/proc/self/uid_map` 停止。不能标为完整标准检查通过。

## 旧测试基线对照

另执行 `python3 -B -m unittest discover -s ddnsto/tests -p '*test.py'`：
修改后 482 项，83 失败、1 错误、13 跳过。将修改前 HEAD 用 `git archive` 提取到独立临时目录，
运行相同命令同样为 482 项、83 失败、1 错误、13 跳过。
失败包含旧入口测试未加载 `installer_dispatch`、群晖旧能力断言、旧生命周期测试，
以及脚本式测试不能作为 unittest discover 模块导入和命名空间权限限制。
本次未修改这些历史测试来掩盖失败，不宣称全仓测试全绿。

## 未验收项

- 没有真实发布其他客户端版本；测试中的不同版本仅为本地隔离数据。
- 没有进行本轮真机升级或 Windows PowerShell 运行验收。
- 构建校验不证明 CDN 包版本、可下载性或运行兼容性；实际版本更新仍必须审核产品并验收。
- 推荐配置修改需构建和发布才生效；未启用独立在线 JSON 热更新。
