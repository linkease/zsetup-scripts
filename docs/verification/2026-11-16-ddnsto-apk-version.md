# APK 3 已安装版本读取修复

日期：2026-11-16。仅更新测试站，用户负责真机测试；未提交或推送代码。

## 根因与修复

用户设备为 aarch64 iStoreOS，apk-tools 3.0.5，同时存在 `/bin/opkg` 和 `/usr/bin/apk`。`opkg status ddnsto` 无输出，`apk info -v ddnsto` 返回描述、URL 和包大小，而不是版本。脚本误将该输出按 `ddnsto-VERSION` 解析，产生 E_VERSION。

用户的只读命令 `apk list --installed ddnsto` 返回：

```text
ddnsto-4.2.2~aa64-r1 noarch {feeds/linkease_nas/feeds/linkease_nas/network/services/ddnsto} () [installed]
```

修复 `ddnsto_ensure_ow_version`：APK 分支改用上述命令，只接受唯一的已安装记录，然后沿用既有架构后缀、发布版本及修订号检查。该记录识别为 4.2.2，对固定目标 4.2.8 选择 update。空记录、重复记录、无 installed 标记、非目标包、异常后缀及查询失败仍拒绝；不调用客户端二进制猜版本，不强制覆盖，不降级或换绑。

核对官方 APK 3.0.5 `src/app_list.c`：installed 过滤只查安装记录，正常输出包含包名-版本、架构及 `[installed]`。实际安装继续使用 zsetup 提供的 package_manager；本次不修改核心或包管理器选择。已有本地预览优先探测 opkg 的逻辑不等于实际安装选错包管理器，未将其作为本次根因修改。

## 测试

- 先添加用户完整输出的回放测试，旧代码以退出码 2 失败，再修复。
- `tests/ddnsto_auto_openwrt_test.py`：9 项通过，包含 APK 3 记录、opkg 共存不回退、升级决策、不降级、异常记录拒绝及原 opkg 行为。
- `python3 -B -m unittest discover -s tests -p 'ddnsto*test.py'`：146 项，113 通过、33 因 Windows/专用隔离环境缺失跳过。
- 生成入口检查、Shell 语法和 `git diff --check` 通过。
- 没有真机安装验收，没有执行真实包安装或修改用户配置。

## 发布

目标：`tx-nj-02.kooldns.com:2233`。
目录：`/home/ddnsto/installer-test/ddnsto-install/0.2.4/recommendation-short-20261109/`。

仅新增不可变 Shell 安装器并原子替换 `recommended-shell.txt`，入口 `/i`、PowerShell、Nginx、客户端归档及正式环境均不变。与上一线上安装器相比仅版本读取函数发生变化（主程序及生成的提权程序各一处）。

- 旧安装器：`5c3eaad0eac55b0c44c3b32536a7dcf2ddfa9b6ab5ac3cfac482036224d0af9e`。
- 新安装器：`fd5f5136949fd429c52294974006a42640764f9a6d82d304fccfa8dca67f5a9a`，506874 字节。
- 新推荐清单 SHA-256：`4c90df1dcf156bee8881356bab78a85cca6aa913261e5b02f2f4a38774e01f65`。
- 入口摘要保持 `c13ae6d0c87ff8179ec955300a2a3f3b9ed0425d719cb1a613e3d4438f21885e`。
- 旧清单备份：`/home/ddnsto/installer-test/.backups/apk-version-20261116/recommended-shell.txt`。

公网不可变文件摘要及清单回读匹配；重新下载 `/i` 执行 `--help` 完成下载、校验和帮助输出。用户重新执行原命令即可取得修复。

回滚先核对当前清单仍为本次摘要，再将备份清单复制到同文件系统暂存文件，校验后原子替换；不覆盖或删除不可变安装器。
