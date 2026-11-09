# OpenWrt 默认安装失败修复（测试站）

## 原因与复现

- 授权设备 `192.168.30.244`：iStoreOS 24.10.1，x86_64，已安装并运行 `ddnsto 4.2.8~8664-r1`。
- 公网 `/i` 配合原 UCI Token（不输出凭据），现有缓存下报 `E_VERSION`：版本解析不支持官方打包的架构后缀。包 Makefile 的 PKG_SOURCE_DATE / PKG_SOURCE_VERSION 对应 `4.2.8~8664`。
- 独立私有 ZSETUP_ROOT 下复现用户的 E_EXECUTOR / exit 1 / stage=checking。设备实际 GET dl.istoreos.com 的 zsetup 0.5.0 返回 302，Location 指向 fw.koolcenter.com。策略拒绝重定向后停止；默认流程隐藏了原始错误。

## 修复与验证

- 仅 DDNSTO bootstrap 使用直接 HTTPS 镜像：fw.koolcenter.com、fw.d4ctech.com、fw20.koolcenter.com。显式测试源、native 产品源及共享 bootstrap 不变。
- 不跟随重定向、不关闭 TLS、不放宽 SHA256，未修改 zsetup 核心。自举失败记录 E_BOOTSTRAP 与安全提示，不输出原始子进程日志或 Token。
- 只识别与设备匹配的官方架构标记 8664 / aa64 / aa32 / 1b0c，未知标记及预发布格式继续拒绝。
- 回归先失败再通过：自举 19 项、下载 35 项、OpenWrt 生命周期 29 项、自动 OpenWrt 6 项、默认流程 11 项。
- 生成入口一致性、Shell 语法和差异空白检查通过。全仓 `check.sh --native-bin` 在既有 privilege_bridge_test.py 因 `unshare: write failed /proc/self/uid_map: Operation not permitted` 中断；未宣称全仓通过，平台专属跳过项也未计作验收。
- 原生测试使用既有 zsetup 0.5.0（SHA256 `9563b8442a75957792bb82a2d98a736142fc52be57dd2dc42005490096897617`）。曾误选另一缓存版本，测试摘要校验正确拒绝；换用匹配版本后通过。
- 候选真机原缓存、新缓存均成功；最终公网 `/i` 与全新 native 缓存也返回 0，init 状态 running。配置摘要不变，未卸载或换绑。
- 未把已安装同版本启动测试当成全新 opkg 安装验收，未判断云端在线。最终脱敏记录 `/tmp/ddnsto-result.lhjNOM/events.log`，私有 canary 临时目录保留供排查。

## 测试站发布

- `/i` 薄入口不变，仍读取 recommendation-short-20261109/recommended-shell.txt。
- 新不可变路径：`/ddnsto-install/0.2.4/recommendation-short-20261109/immutable/0edfd92285b8cec8796e8904a3a3ec9872a74c01984f5c1c19eb924e8758c59b/install.sh`，373851 字节。
- 上传不可变文件，经设备 HTTPS 回读 SHA256 一致后，备份并原子替换 Shell 清单与 review.json。未改 Windows 入口或清单、Nginx、前端、正式环境。
- 原推荐目录备份 `.recommended-shell.pre-openwrt-20261109`、`.review.pre-openwrt-20261109`；旧不可变脚本保留。回退前检查后续发布，再恢复这两份数据。
- 本机回读一度遇到 DNS 失败，改由设备公开 HTTPS 回读验证成功，没有绕过证书。代码未提交或推送。
