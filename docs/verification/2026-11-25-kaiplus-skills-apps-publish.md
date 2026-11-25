# KaiPlus Skills 固定安装入口：完整 apps 发布记录

状态：验收完成，准备发布。用户已于 2026-11-25 明确授权部署最新 zsetup-scripts。

目标和任务树：父工作区 `docs/plans/kaiplus-skills-script-update-2026-11-25.md`。

## 候选与范围

- Release ID：`885aa737c6e114cf4fe126c69c622d2213f7575fc06a709a0eead13c30b5fab5`。
- KaiPlus 功能提交：`8043ae883`，客户端尚未部署到设备。
- 固定入口：`https://fw.koolcenter.com/binary/zsetup-scripts/apps/kai-skills/install.sh`。
- 入口 SHA256：`68b06457651679807cbd37870c3f7e9a067b33bbe873cf134ee353eadcf62823`。
- 内部参数：`--source kaiplus --system 实际系统 --context 私有上下文`。
- KaiPlus 更新全部系统的公共与专属内容，保留启用选择和旧会话；普通安装继续按单个系统/技能选择。
- 完整 apps 包含 106 个清单文件；预计 92 次不可变检查及 424 次最终四站 HTTPS 字节检查。
- 相对实时源站基线 `0e00b2c06fc06b4d1e40ff1ab5179e80463d290506833dc01d148c595aa758cf`，
  31 个既有文件变化、7 个新增、无删除。完整范围包括原有 DDNSTO 0.3.2 和共享自举修复，
  详见[DDNSTO 范围记录](2026-11-25-ddnsto-release-kaiplus-apps.md)。

## 两轮验收

第一轮发现并修复两项遗漏，均由新增测试先复现失败：更新完成事件被正在进行的状态请求吞掉；
手动检查清掉失败后的会话恢复入口。第二轮验证通过，未使用第三轮。

- 五个相关 Go 包 `go test -race` 通过，包括真实 shell/worker/父进程快照激活的隔离测试。
- 62 项前端相关测试、TypeScript 检查、普通 Web 与 desktop-entry 生产构建通过。
- `scripts/check.sh --native-bin` 执行退出 0；使用本机已有 zsetup 0.6.6，保留可选环境跳过的边界。
- 历史 Shell 专项使用实际 GNU Bash 4.2.0，4 项通过、无跳过；KaiPlus 标准入口也通过该解释器语法检查。
  测试解释器仅在 SSD 临时构建，没有安装或替换系统 Bash。源码为
  [GNU bash-4.2.tar.gz](https://ftp.gnu.org/gnu/bash/bash-4.2.tar.gz)，归档 SHA256
  `a27a1179ec9c0830c65c6aa5d7dab60f7ce1a2a608618570f96bfa72e95ab3d8`。
- 普通安装的完整现有回归、生成一致性、来源/系统参数转交和错误参数拒绝均通过。
- 未重跑全部客户端空白安装和所有设备矩阵；既有原生设备证据明确保留，安装脚本发布不等于客户端升级。

## 部署和回退

SSH：`root@192.168.3.1`。
公开目录：`/mnt/sata3-1/istore-data/public_html/binary/zsetup-scripts/apps`。
协调器：`scripts/publish-apps.py`，使用上述精确 ID，先暂存/校验不可变文件，再激活入口和配置。
原始基线、差异及验收记录保存在父工作区 `build/verification/kaiplus-skills-update-20261125/`。

发布结果、源提交和回退命令待实际激活后填写。
