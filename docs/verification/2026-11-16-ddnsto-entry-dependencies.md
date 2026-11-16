# 推荐入口校验依赖兼容与测试站验证

日期：2026-11-16。范围：Shell 推荐入口；不修改 zsetup 核心、客户端安装包或正式环境。

后续状态：用户确认固件确实没有 stat 后，本次初步 BusyBox 兼容已被同日的[无 stat 入口优化](2026-11-16-ddnsto-statless-entry.md)替代。以下保留为第一次发布的历史证据，不代表当前入口仍要求 stat/cmp 或保留长期推荐缓存。

## 问题与调整

此前 `stat wc cmp mktemp` 任一命令不可见都会产生同一条“缺少校验依赖”错误，无法从报错判断具体缺少哪项。尚未取得报错设备的工具清单，不能断定它具体缺少哪一项。

- 优先使用 PATH 中的独立命令；缺少时检查 BusyBox 的完整 applet 名称。
- BusyBox 提供对应功能时，入口使用显式函数兼容，并在经过安全检查的私有工作目录创建临时命令转接，供安装器子进程继承；退出时随工作目录清理。不修改系统命令链接。
- 两种来源都不可用时逐项列出缺少的命令，提示检查 PATH 或补齐依赖；仍以 code=2 拒绝执行安装。
- 保留所有权、权限、文件大小、SHA-256 和 HTTPS 校验，不以跳过校验解决兼容问题。

## 验证

- `python3 -B tests/ddnsto_recommendation_test.py`：41 项，30 项通过，11 项因缺少 PowerShell/Windows 环境跳过。
- 新增用例覆盖入口与子进程兼容、逐项报告缺失、无需 BusyBox 的原生命令路径、篡改拒绝、近似 applet 名称拒绝。
- `alpine:3.20` 断网临时容器：隐藏四个独立命令入口，使用真实 BusyBox 执行推荐入口的依赖检查/缓存准备部分；子 shell 的 stat、wc、cmp、mktemp 均成功。未执行客户端安装。
- `sh -n ddnsto/recommended-entry.sh`、`python3 -B scripts/build-entrypoints.py --check`、`git diff --check` 通过。
- 当前环境缺少全仓检查需要的原生 zsetup 工具，未运行全仓 native 检查；未声称通过报错 OpenWrt 真机安装验收。

## 测试站发布

仅原子替换 `tx-nj-02.kooldns.com` 上的：

`/home/ddnsto/installer-test/ddnsto-install/0.2.4/recommendation-short-20261109/recommended-entry.sh`

入口：`https://web.toany.net/i`。其对应长地址为 `https://web.toany.net/ddnsto-install/0.2.4/recommendation-short-20261109/recommended-entry.sh`。

候选文件使用线上原有不可变安装器重新打包；与线上旧入口相比，仅依赖检查及临时命令转接两处发生变化。未上传或替换推荐清单、不可变安装器、PowerShell 入口或 Nginx 配置；历史 `/recommendation/` 路由保持不变。

- 原入口 SHA-256：`3b72052057eeed7066f5d16456dddc872e663bb8be4c51714b31a11642b74639`
- 新入口 SHA-256：`c2274f29ee907c7c4818ef22cb5dfa632d75b3dc5308b23eb7a18e29497008a5`
- 备份：`/home/ddnsto/installer-test/.backups/dependencies-20261116/recommended-entry.sh`
- Shell 安装器保持 `bc7c349c95a623dfaf2431e1cd53b0648e1b03bad1f49b9d073362201be829ad`，500716 字节。
- PowerShell 安装器保持 `4f044f50a96f215ac2c8fa1b2a106ff1e325bdbc93a48ced4a780a521e773911`，46153 字节。

发布后通过公网 HTTPS 回读，两入口 SHA-256 均符合预期。使用独立临时缓存执行下载后的入口 `--help`，完成线上清单下载、安装器校验和帮助输出，未安装或改变本机 DDNSTO 服务。

回滚时先检查线上仍是上述新 SHA，再将备份复制到同文件系统的暂存文件，经校验后原子替换入口。不要直接覆盖可能正在被读取的文件。
