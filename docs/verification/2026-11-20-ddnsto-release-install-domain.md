# DDNSTO 发布记录：独立安装域名与业务环境

状态：本地开发中，未发布。

## 范围与授权

- 用户于 2026-11-20 确认：固定 install.ddnsto.com，源码与发布包仅由 zsetup-scripts 管理；移除业务网关/静态仓库承载职责。
- 参数区分客户端正式/测试业务环境，不增加脚本测试渠道。测试分发为后续事项。
- 允许本地代码、测试、构建、文档修改；不部署、不连接真机、不验收未部署域名，不自动提交或推送。
- 源基线：main / 2fbc399。当前改动未提交。
- 客户端所有平台推荐版本和安装包摘要不变，不重新审核或上传客户端包；不修改 zsetup 核心。
- 入口策略由打包参数显式决定；本地包不代表线上策略已切换。
- 用户随后明确简化环境规则：未指定环境、旧安装缺少环境记录均默认正式；不能因缺少记录拦截普通安装。仅显式测试参数选择测试业务环境，明确环境冲突仍确认切换。

## 验证记录

- 独立站点打包测试：先失败（工具不存在），实现后通过。
- AI 指南契约测试：先失败（旧同域占位链接），改为固定域名和业务环境约束后 3 项通过。
- 默认环境兼容回归（`unittest discover -s ddnsto/tests -p '*environment_test.py'`）：107 项，106 通过、1 项 PowerShell 运行时因环境缺失跳过。覆盖 Linux 旧 unit/缺失 unit、有无 boot；macOS 旧 plist/缺失 plist/job/保留配置与 boot；Windows 静态契约及待执行 fixture。保留 Token/identity，不把缺少记录当作拒绝条件。
- Linux 首次正式安装保持原注册路径，不因业务环境功能新增 jq 门槛；显式测试首次安装才要求 jq。原有账号核验等流程的既有依赖保持。
- DDNSTO 根目录回归（`unittest discover -s tests -p 'ddnsto*test.py'`）：204 项，163 通过、41 跳过；跳过项不计为通过。
- 控制台安装入口相关 7 个测试文件：57 通过、3 跳过；在隔离网络 namespace 内执行，仅允许本地 fixture。
- Shell 兼容测试：4 项通过，包含隔离容器中的 Bash 旧版 POSIX 解析与 `--help`。
- 统一入口重新生成及 `--check`、独立站点打包测试、AI 指南 3 项测试、Git diff 检查通过。Meta 校验通过（1662 links / 57 records）。
- 以上环境与 DDNSTO 回归在隔离网络 namespace 内执行，不代表真机或公网链路验收。平台支持矩阵见部署模型。
- 仓库级 `scripts/check.sh --native-bin …` 未全绿：在未改动的 `windows_scoop_contract_test.py` 断言 `windows-apps-0.2.0`，而未改动的 `catalog-windows.json` 已为 `windows-apps-0.2.1` 时停止；两文件均与 HEAD 一致，为既有 Scoop 契约不一致，本轮不跨业务修复。此前执行的 DDNSTO/Mac/推荐入口等检查通过，后续聚合检查未执行，不能将整套检查标为通过。

## 客户端能力的只读证据

- `ddns-client` 的 `v4.2.8` 标签解析为 `bbde564c36ef2068753b9ac521ac97f62c276912`。`cmd/cli_ddnsto/config.go` 在读取加密启动记录后应用 `DDNSTO_TEST_SERVER_ASSIGNMENT_JSON`；无需修改客户端源码。配置中的显式服务器参数仍需预检拒绝，不能只设置环境变量就假定覆盖所有历史配置。
- 本地 `clients/ddns-client/bin/cdn-upload-4.2.8-publish/` 的 Windows CLI ZIP 和 macOS TAR 摘要分别为 `5b09cf2be048e1592668b8b5fed922206849b35f9fe6469122b0460aeee64688`、`8bb1e102160c8e52f670839051ca341f0a083720634da79c2142a1de6d13f446`，与当前推荐配置一致。只读解包流确认包含该环境变量名；未执行客户端。
- Linux 当前推荐包摘要沿用 `docs/ddnsto-artifacts-2026-11-03.json` 已有审核记录。本轮找到的本地 Linux 归档摘要不同，不将其视为当前推荐包的验证；测试环境安装对已校验目标二进制再做负向能力检查，缺失所需能力时不启动。字符串存在不等于联网验收通过。
- assignment 是启动配置，注册后服务端仍可下发更新；本轮不承诺传输隔离或云端在线。环境参数不删除或解密设备身份记录。

## 未执行事项

没有公网回读、设备安装、业务连通、正式发布或回滚操作。安装域名仍未部署。
本地 fixture 不证明实际设备升级/切换环境和联网成功；正式发布前须取得授权后完成验收。
