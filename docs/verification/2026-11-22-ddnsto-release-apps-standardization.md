# DDNSTO 推荐版本发布记录：2026-11-22 apps 标准化

状态：正式发布准备中（本地候选已验证；生产 Web 根已只读确认）

## 范围与授权

- 变更原因：将 DDNSTO 纳入可直接复制的标准 `apps/` 发布树，并修复 Linux 生命周期固定身份 marker 校验。
- 客户端版本保持 4.2.8；不构建、不替换任何客户端产品包，不修改产品摘要。
- Linux/OpenWrt 固定 zsetup 0.5.0；标准 apps 入口使用站点 stable zsetup，Linux 0.6.4、Windows 0.6.5。
- 目标平台：当前 `app.json` 声明的 Linux/OpenWrt 目标；DDNSTO Windows 独立 CLI 不进入本次 Windows apps 索引。
- 不变平台：macOS、Windows CLI、Synology、Asus 的 DDNSTO 产品版本和安装包元数据均不变。
- 源分支：`main`；准备基线 `1f26f2c173311b585afd51815efa62c9dc60c38a`；提交号待生成。
- 用户于 2026-11-22 同意继续发布流程，并确认生产 Server 为
  `root@192.168.3.1`，服务器内容自动同步到 `fw.koolcenter.com` 下载站。
- 只读 SSH 核验确认 `/mnt/sata3-1/istore-data/public_html/binary/zsetup/config.json`
  与公网 `/binary/zsetup/config.json` 摘要一致，故生产 Web 根为
  `/mnt/sata3-1/istore-data/public_html/binary`。
- 标准发布模型为 `apps/` 的内容直接映射到 `/binary/`；不额外套
  `zsetup-scripts/` 目录，否则配置内 `ddnsto/...`、`zsetup/...` 等路径会错位。
- `install.ddnsto.com` 独立安装站不在本次标准 `apps/` 发布范围内。

## 产品审核

本次不改变客户端产品。4.2.8 各平台产品 URL、大小和摘要继续由
`ddnsto/platform-releases.json` 与既有审核记录维护；没有用本地重打包文件替换线上证据。

## 本地验证与候选

| 命令/检查 | 结果 | 证据 |
|---|---|---|
| `scripts/build-entrypoints.py --check` | 通过 | 生成入口无漂移 |
| `scripts/build.py --check` / public-tree policy | 通过 | 10 apps，Linux 125、Windows 5 条记录 |
| DDNSTO POSIX 跨平台聚合 | 通过 | 18 组；PowerShell runtime 因无 `pwsh` 明确跳过 |
| DDNSTO/LinkEase 隔离服务与包事务 | 通过 | service + opkg/apk matrix |
| `scripts/check.sh --native-bin` | 通过 | 官方 zsetup 0.5.0 固定摘要与私有路径 |
| 完整 apps 发布沙箱 | 通过 | stage / activate / verify / rollback；保留服务器无关文件 |

- DDNSTO Shell：`d35a332d1c901b175e1c60a5895468ad1d58649a4b287d5aa83718b91bc284f2`。
- DDNSTO PowerShell：`917d6eee6de2d8a555864cf0253956f61825b29a0cf698cebe9f7b7833b0a46d`。
- 标准 DDNSTO entry：`911a00891a3b627bb1c9c2b0ab636182a15eb888383dda4abe9abfa599b33d19`。
- Linux apps config：`ab2597b792c037f643208d6a74780b81212d0f013b2cb09201d743cf41e166d3`。
- Windows apps config：`d01598737c4e07cdf0a6f78550b1a9d8321dc71a0ac03a430f468e3a68467012`。
- `apps/SHA256SUMS`：`67112af8c8ea5a7cbc03a0affe6f93ffd9b1cba94bffc81f922cfa91a2c76e32`。

## 真机与公网验收

- 四个现有 `/binary/zsetup/config.json` 只读摘要一致，仍为
  `2a5813f9b367fb437453f3bfa0fb77b989918e555f369104bba7a87e6e1f4ce0`，stable 0.6.4。
- `/binary/ddnsto/ddnsto-install.sh`、`/binary/ddnsto/install.sh` 和
  `/binary/ddnsto/0.2.4/installer.sh` 当前均返回 404。
- `install.ddnsto.com/i` 与推荐长入口当前返回 503。
- 未执行公网写入、真机安装或业务连通验收，不能写为已上线。

## 激活与回滚

- 本地沙箱已验证 mutable snapshot、失败恢复和 rollback；不可变版本文件在回滚后保留。
- 正式目标已确认为 `root@192.168.3.1` 的
  `/mnt/sata3-1/istore-data/public_html/binary`；激活采用不可变文件先行、
  可变配置和入口最后切换、HTTPS 回读及摘要校验。
- 回滚只恢复本次可变入口和配置，不删除不可变版本，不代表客户端降级。
