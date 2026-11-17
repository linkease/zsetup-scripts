# Bash 4.2 POSIX 解析兼容修复

状态：测试站已发布，公网读回、Bash 4.2 执行及原短命令帮助模式通过；用户真机安装待重试。

## 根因和复现

用户报告安装器第 2438 行在 `;;` 处语法错误。该行号对应此前
`1de460d6296f387978a83d22aa7112c8a584913d45f74f8ec92b7ac469e807ae` 安装器；
当前测试站 `b43c801f53464c6d0f1752abb4bff6f38a8b5e08fb9df6b69ddeb3d28aebd8b7`
中同一代码位于第 2470 行，同样受影响。无法仅凭日志确认用户 Shell 版本或取得旧字节的原因。
当前公网文件 SHA 与本地一致，不是已观察到的下载损坏。

已在真实 Bash 4.2 的 POSIX 模式复现：`ACTIVE_ZSETUP=$(...)` 内连续 `case` 模式使用
不成对的括号时，旧解析器误判命令替换边界，随后在 `;;` 处失败。
Dash 和 Bash 5.2 检查通过，因此此前开发机 `sh -n` 和帮助模式没有覆盖此问题。

最小复现：

```sh
x=$(
case "$p" in /*) ;; *) exit 1 ;; esac
case "$p/" in *//*|*/./*|*/../*) exit 1 ;; esac
)
```

修复为成对模式括号 `(/*)`、`(*)` 和 `(*//*|*/./*|*/../*)`。
保持同一目录校验、私有缓存、锁和摘要校验，不修改 zsetup 核心或客户端版本。

## 自动验证

新增 `tests/ddnsto_shell_compat_test.py`，先观察旧解析器在源模块、完整入口和 `--help`
均失败，再修复 `ddnsto/bootstrap-policy.sh` 并重新生成入口；4 项全部通过。
引导策略 21 项通过；生成一致性和差异空白检查通过。

使用只读、禁网、无宿主目录挂载的短生命周期容器：

```sh
DDNSTO_TEST_LEGACY_SHELL='sudo -n docker run --rm -i --network none --read-only bash@sha256:b4624ba1360dbf58914efe2369e91effb24e8024853e606a4bec34c85111f070 bash --posix' \
  python3 -B tests/ddnsto_shell_compat_test.py
```

镜像已下载至开发宿主缓存，测试容器自动移除。未安装或停止 DDNSTO 服务。
SOP 已补充旧 Bash 验证要求，标准检查调用新测试；未提供旧解释器时必须明确记录跳过。

## 发布边界

修复安装器 SHA：`5096a3525f30dd4b6eab6adf93672f1b93bdc262d1abac4bfaffff305fed0d46`。
候选：`dist/bash42-fix-20261117-5096a352`。仅更新测试站 Shell 推荐清单和新增不可变脚本；
入口包装器、PowerShell 制品、Nginx、正式环境和用户配置保持不变。
本轮基于此前测试部署的故障修复，不包含代码提交或推送。

## 发布结果

- 全部 `tests/ddnsto*test.py`：188 项，153 通过、35 跳过；本轮显式提供 Bash 4.2 解释器，
  新增旧 Shell 测试没有跳过。
- 实际推荐目录保持 `recommendation-short-20261109`；Shell 清单摘要由
  `7fa60111c865d95283e15cb268c152ed5fe8c0823fd2a9e72d8e7de5565efa8e` 更新为
  `e5fd6ed736f69d67ecf0f97cef5e7fc9035ac0f4715b1e8ac914ca5e743186e0`，指向 511632 字节的新安装器。
- 备份：`/home/ddnsto/installer-test/.backups/bash42-fix-20261117-5096a352/`。
  保存旧 Shell 清单与候选 review.json；旧不可变制品保留。回滚前必须核对当前清单仍为本次新摘要。
- 新不可变脚本先上线并公网逐字节读回，在禁网 Bash 4.2 容器中执行 `--help` 成功，
  然后持锁核对旧清单并原子切换；公网清单 HTTP 200、no-store、摘要一致。
- 第一次公网读回遇到开发环境临时 DNS 解析失败，重试成功；读回成功前未切换清单。
- 激活后的实际 `/i` 短命令 `--help` 退出 0。Shell 包装器和 PowerShell 清单摘要保持不变。
- 未进行用户设备安装、客户端版本变更或实际回滚演练，未修改正式环境。
