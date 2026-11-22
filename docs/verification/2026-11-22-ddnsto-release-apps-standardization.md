# DDNSTO 推荐版本发布记录：2026-11-22 apps 标准化

状态：误用 `/binary/` 根目录的发布已完整回滚；等待按 zsetup-scripts 整体业务重新设计

## 范围与授权

- 变更原因：将 DDNSTO 纳入可直接复制的标准 `apps/` 发布树，并修复 Linux 生命周期固定身份 marker 校验。
- 客户端版本保持 4.2.8；不构建、不替换任何客户端产品包，不修改产品摘要。
- Linux/OpenWrt 固定 zsetup 0.5.0；标准 apps 入口使用站点 stable zsetup，Linux 0.6.4、Windows 0.6.5。
- 目标平台：当前 `app.json` 声明的 Linux/OpenWrt 目标；DDNSTO Windows 独立 CLI 不进入本次 Windows apps 索引。
- 不变平台：macOS、Windows CLI、Synology、Asus 的 DDNSTO 产品版本和安装包元数据均不变。
- 源分支：`main`；准备基线 `1f26f2c173311b585afd51815efa62c9dc60c38a`；
  apps 发布提交 `6e9899ab1f64c77e518919fa912ecd7a64f9f79e`。
- 用户于 2026-11-22 同意继续发布流程，并确认生产 Server 为
  `root@192.168.3.1`，服务器内容自动同步到 `fw.koolcenter.com` 下载站。
- 只读 SSH 核验确认 `/mnt/sata3-1/istore-data/public_html/binary/zsetup/config.json`
  与公网 `/binary/zsetup/config.json` 摘要一致，故生产 Web 根为
  `/mnt/sata3-1/istore-data/public_html/binary`。
- 2026-11-22 曾错误地把 `apps/` 内容直接映射到现有 `/binary/` 根。用户随后明确：
  zsetup-scripts 必须作为整体业务发布，DDNSTO 只是其中一个应用，不能单独发布到
  既有 `/binary/ddnsto/`。该错误映射已回滚，不再作为目标模型。
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

- 发布前四个 `/binary/zsetup/config.json` 只读摘要一致，为
  `2a5813f9b367fb437453f3bfa0fb77b989918e555f369104bba7a87e6e1f4ce0`，stable 0.6.4。
- 生产 release id 为
  `67112af8c8ea5a7cbc03a0affe6f93ffd9b1cba94bffc81f922cfa91a2c76e32`；
  服务器端完整 138 文件逐字节验证通过。
- 不可变阶段先对 12 个版本文件在四个下载域执行 48 次 HTTPS 摘要校验，
  全部通过后才激活配置与入口。
- 激活后四个下载域对 138 个清单文件完成 552 次 HTTPS 摘要校验；最终又对
  `SHA256SUMS`、Linux/Windows 配置、DDNSTO 两个入口和版本安装器执行 24 次
  关键回读，全部通过。
- 上述激活属于错误目标验证，不是最终发布结果。随后执行同一事务的受保护回滚，
  `/binary/zsetup/config.json` 已恢复为发布前摘要
  `2a5813f9b367fb437453f3bfa0fb77b989918e555f369104bba7a87e6e1f4ce0`。
- 本次新增的 `/binary/ddnsto/install.sh`、`ddnsto-install.sh`、`app.json`、
  `source/`、`0.2.4/installer.sh` 及空目录均已删除；四个下载域回读均为 404。
- 本次新增的根 `/binary/SHA256SUMS` 已由回滚删除。
- `install.ddnsto.com/i` 与推荐长入口当前返回 503。
- 本次没有获准操作真实 DDNSTO 设备，未执行空白新装、保留 Token/固定身份升级、
  重复安装或服务连通验收。因此不宣称 DDNSTO 客户端全平台业务验收完成；
  错误目标也已回滚，不能记为标准公共树上线。

## 激活与回滚

- 本地沙箱已验证 mutable snapshot、失败恢复和 rollback；不可变版本文件在回滚后保留。
- 错误发布目标曾为 `root@192.168.3.1` 的
  `/mnt/sata3-1/istore-data/public_html/binary`。该目标上的事务 phase 现为
  `rolled-back`；现有 `/binary/*` 业务已经恢复。
- 可回滚发布包保存在服务器私有目录
  `/mnt/sata3-1/istore-data/.zsetup-scripts-releases/67112af8c8ea5a7cbc03a0affe6f93ffd9b1cba94bffc81f922cfa91a2c76e32`；
  mutable 快照 phase 为 `rolled-back`，用于保留这次误发布和恢复的审计证据。
- 发布工具经过三次封闭优化：精确 release id 的无 Python 目标模式、发布账户所有权及
  去除组/其他写权限、`SHA256SUMS` 自身纳入快照/激活/验证/回滚。误激活期间的 139 个
  公开文件均通过权限检查；回滚后不保留这些错误目标文件。
- 回滚只恢复本次可变入口和配置，不删除不可变版本，不代表客户端降级。
