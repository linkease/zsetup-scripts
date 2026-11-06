# DDNSTO OpenWrt 真机验证（2026-11-06）

## 范围

用户明确授权在 `192.168.30.244` 验证和修复。设备为 iStoreOS 24.10.1
（2025052311）、x86_64、opkg，约 2 GiB 持久 overlay。
初始已有 DDNSTO 4.2.8，已绑定并运行，没有未提交 UCI 修改。
本次仅修改 zsetup-scripts；不修改、编译 zsetup-rust，不推送或发布 CDN。

原生程序由脚本自动取得官方 Linux zsetup 0.5.0，设备 SHA256：
`9563b8442a75957792bb82a2d98a736142fc52be57dd2dc42005490096897617`。
与官方已验证摘要及 bootstrap pin 一致；无需用户手动下载 native。

## 复现、修复与验证

原候选 `--plan` 成功，但 `--action status` 返回 2，错误要求已有 native：
OpenWrt 管理操作误入 Linux/systemd 适配路径。

修复采用独立 OpenWrt 适配模块，复用既有 package ownership、UCI 恢复逻辑和
`/etc/zsetup/install-locks/ddnsto` 全机锁。状态/本地生命周期无需 native 下载；
升级仍使用发布 zsetup、受保护持久目录、限额下载及 SHA256 校验。
重复 install 拒绝隐式重绑定；只有显式 configure 可以更换 Token。
升级不预先卸载现有包，在禁用 UCI/停止旧进程后执行包钩子，随后恢复完整 UCI。
旧 global/未知配置不自动转换，失败保留配置，不声称包管理器能完整回滚。

| 真机操作 | 结果 |
| --- | --- |
| 自动 native bootstrap、3 个 IPK 下载和校验 | 通过；首次从正式镜像下载，后续缓存复用 |
| `--action update` | 成功；UCI 与操作前备份逐字节一致；恢复运行 |
| `--action status` | 无需 native，正确报告 running/stopped |
| stop → status → start → restart | 通过；最后运行；配置与原始备份逐字节一致 |
| 重复 install | 返回 2，提示 update/configure，配置不变 |
| stop → update → status | 升级后仍 stopped，没有擅自启用 |
| `--action update --verify-status` | 通过 |
| `--action repair` | 通过；保留原 Token/身份，运行且开机启用 |
| 最终清理 | 全机锁释放，package-result phase=complete/exit=0，无待提交 UCI |

最终软件包：ddnsto `4.2.8~8664-r1`、luci-app-ddnsto `4.2.8-r1`、
luci-i18n-ddnsto-zh-cn `26.119.35588~d3ed445`。

## 设备保留材料与复测

设备私有目录 `/root/ddnsto-verification.JdlCph` 保留：

- `uci-original`：原始配置（敏感，不提交、不回传）。
- `init-original`、`ddnstod-original`、`packages-before`：操作前恢复参考。
- `candidate.sh`：本次测试脚本，SHA256
  `a40e0d1db10fc7f5e9f7610a3a7765f5a5da5f3ff1d566e39ed3665ddc9c34cf`。

在该设备 root shell 可运行：

```sh
sh /root/ddnsto-verification.JdlCph/candidate.sh --action status
sh /root/ddnsto-verification.JdlCph/candidate.sh --action update
sh /root/ddnsto-verification.JdlCph/candidate.sh --action restart
```

原生缓存位于 `/tmp/zsetup/rescue/0.5.0/zsetup`，已验证 IPK 输入在
`/opt/linkease/ddnsto/.packages/opkg-4.2.8-standard-x86_64/`。
未删除用户数据；未重置 Token/身份；未重启整机或修改网络设置。

## 自动化与未验证范围

- `python3 -B ddnsto/tests/openwrt_lifecycle_test.py`：29 项通过。
- `python3 -B tests/ddnsto_openwrt_adapter_test.py`：5 项通过。
- pinned products：6 项通过（含 16 个 OpenWrt 包选择组合）。
- extra platforms 4 项、entry integration 2 项、standalone/desktop packaging 各 1 项通过。
- 生成器 `--check` 与 `git diff --check` 通过。

模拟测试包括包钩子改写配置、部分失败、配置恢复失败留存备份、Token 交互与保留身份。
不将 fixture 通过等同于真机验证：这台设备没有进行卸载、清空后首次安装、换 Token、
断电/网络中断注入、APK 或其他架构测试。云控制台在线状态未验收，始终显示
`cloud_status=unverified`。全仓其他平台迁移和正式发布检查仍需另行完成。
