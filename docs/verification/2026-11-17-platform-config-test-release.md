# 分平台推荐配置：测试站发布

状态：测试已发布，公网读回与非安装冒烟通过；本轮真机安装待验收。

用户授权：本轮“更新测试服务器”；不包含正式发布、提交推送或破坏性设备操作。
源码：`3e03abdfeea6a785be9b0501909d7fc3bdded9fb` 加当前未提交的分平台配置、生成器和 SOP 修改。
测试服务器：`tx-nj-02.kooldns.com:2233`；实际推荐目录：
`/home/ddnsto/installer-test/ddnsto-install/0.2.4/recommendation-short-20261109`。

## 范围

- 版本/产品摘要保持原已审核值：原生平台客户端 4.2.8，DSM SPK 4.2.8-7。
- 更新 Shell 推荐入口、Shell 清单、PowerShell 清单，先发布两个新不可变安装器。
- `/i.ps1` 实际映射 `windows-entry-trustedinstaller-20261109/recommended-entry.ps1`，
  已与本地生成入口同摘要；不覆盖其入口或旧目录中的非活跃 PowerShell 入口。
- 保留 native-first；不改 zsetup 核心、Nginx、控制台、Windows GUI 或正式环境。
- 同时发布先前本地验证过的 macOS BSD stat 特殊权限位、镜像优先级、launchd 稳定性与启停修复。
- 当前标准检查的命名空间权限限制及历史测试基线见
  [配置验证](2026-11-17-platform-release-config.md)。本轮没有新增产品包，不重新宣称全平台产品验收。

## 审核字节

| 制品 | 发布前 SHA-256 | 候选 SHA-256 |
|---|---|---|
| Shell 入口 | f93c71b5764726ffb8d7671837b2b44e08c1fbc261a77bfa3c0991ac3c88c1b2 | ce960d70a5176105d199c39405cd17ea2e191eb316e9f677918945da4a6a2ec6 |
| Shell 清单 | 724edeb6deb5284a7e9099fa5cd42b4426effb2b4758fe7012e9bd7a87439520 | 7fa60111c865d95283e15cb268c152ed5fe8c0823fd2a9e72d8e7de5565efa8e |
| Shell 安装器 | 1de460d6296f387978a83d22aa7112c8a584913d45f74f8ec92b7ac469e807ae | b43c801f53464c6d0f1752abb4bff6f38a8b5e08fb9df6b69ddeb3d28aebd8b7 |
| PowerShell 清单 | 7df771fe0cc621ddab02916c897a9f5802d7cabc04cc370feed160083bc8bb2b | b2c638dedd27918c218c7a9ac6cbc4384ec7191cfb4160d5004123732cc7033b |
| PowerShell 安装器 | 4f044f50a96f215ac2c8fa1b2a106ff1e325bdbc93a48ced4a780a521e773911 | ef5563cf8caf3c632e35df832947b45c5981316d9949161b3a62027728407d07 |

活跃 Windows 入口保留摘要：`028512e7884ab84142ed31412c052b6511e6ed40bf0d77cbf281ed86aa88cfa4`。
本地候选：`dist/platform-config-20261117-b43c801f`；review.json 保留生成时未发布状态。

## 发布与验证

2026-11-17 UTC 完成：

- 发布前重新运行 `tests/ddnsto*test.py`：184 项，149 通过、35 跳过；
  生成一致性与 `git diff --check` 通过。
- 备份目录：`/home/ddnsto/installer-test/.backups/platform-config-20261117-b43c801f/`。
  保留旧 Shell 入口、两份旧清单以及候选 review.json。
- 暂存目录：`/home/ddnsto/installer-test/.staging/platform-config-20261117-b43c801f/`。
- 先上传两份新不可变安装器，分别通过公开 HTTPS 下载并与本地逐字节比较通过。
- 持发布锁、再次确认线上旧摘要与备份一致后，按 Shell 清单、PowerShell 清单、Shell 入口
  顺序逐文件原子改名；保留所有旧不可变文件。命令失败恢复钩子未触发。
- `/i`、两份活跃推荐清单均 HTTP 200、`Cache-Control: no-store`，读回字节与本表候选一致。
- `/i.ps1` 公网读回与发布前逐字节相同；Nginx 和入口映射未修改。
- 在开发机执行实际 `/i` 短命令并传 `--help`：退出 0、正确显示帮助；未提供 Token，未安装/停止服务。
  这是入口获取和执行链路验证，不是设备安装验证。
- 本轮未运行真机安装、未进行实际指针回滚演练；备份已保留，发布锁已释放。

用户继续从测试控制台复制原命令，或使用（将占位符替换为控制台 Token）：

```sh
(s=$(curl -qfsS --max-time 60 https://web.toany.net/i) && test -n "$s" && sh -c "$s" -- --token 'YOUR_TOKEN')
```

本轮不把发布成功等同于新装、跨版本升级或设备在线验收；Windows Restricted 执行策略限制未在本次修复。

## 回滚

只在当前摘要仍匹配本表候选摘要时恢复对应入口/清单备份，原子改名并公网读回。
保留不可变安装器和用户配置；指针回滚不会自动降级已安装客户端。
