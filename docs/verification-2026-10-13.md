# DDNSTO 安装器迭代验证（2026-10-13）

起点为 `64352fc`，本轮工作区候选为 scripts-0.1.4；不是发布公告。未上传公网、未修改宿主机服务、未执行真实包安装。

## 本轮变更

- macOS 修复换行 Token 判断；加入配置保留、安装锁、非托管安装保护、XML 转义、同文件系统候选替换及失败恢复。用户级 LaunchAgent 仅在登录后运行。
- Windows 在受保护目录中停止旧计划任务后替换程序，保留 YAML/工作目录及身份文件，失败恢复程序/配置/任务。首次失败只移除本次拥有的文件；恢复失败保留事务备份。
- 桌面下载调用已安装 zsetup 并固定归档 SHA256；Windows 额外固定 EXE 摘要。未完成桌面自举或索引接入。
- POSIX/macOS 新增 `--token-file`，Windows 对应 `-TokenFile`；拒绝冲突、多行值，错误不回显未知参数。Token 文件应限制读取权限。
- 结果区分本地运行/仅请求启动和 `cloud_status=unverified`，引导控制台确认。
- 桌面打包默认关闭，仅显式 `--include-desktop-candidates` 放入不可变 `ddnsto/desktop-candidate-0.1.4/`，不创建稳定别名；保留历史候选。
- 发布核验工具只读检查入口/索引/摘要元数据，不下载产品、不宣称设备在线。

## 已通过

从本仓库根目录运行：

```sh
PWSH_BIN=/path/to/pwsh python3 -B ddnsto/tests/cross_platform_installer_test.py
python3 -B tests/publication_test.py
python3 -B tests/desktop_package_test.py
python3 -B tests/module_layout_test.py
python3 -B scripts/build-entrypoints.py --check
python3 -B ddnsto/tests/ddnsto_test.py /path/to/zsetup-linux-x86_64 /path/to/tunnel --direct-only
```

- macOS：8 个实际 shell 用例，覆盖重复安装/配置与身份保留、更新与首次启动失败、下载失败、错误 OS、多行 Token、非托管任务和竞争锁。
- Windows：PowerShell 7.4.13 **Linux 解释器**执行脚本，覆盖安装、重装、配置/身份保留、启动失败恢复、下载失败不停车、多行 Token、竞争锁和首次失败清理。Windows 平台/ACL/下载/计划任务 API 为替身，不等于 Windows 或 PowerShell 5.1 验收。
- POSIX 参数：2 个用例；发布核验：3 个用例（缺失/完整/陈旧配置、非法摘要）；桌面候选隔离/字节不可变性：1 个用例。
- 布局、生成入口一致性、变更 shell/Python 语法及 `git diff --check` 通过。
- Linux/OpenWrt 直接入口使用真实 zsetup 0.3.0 和本地 TLS 服务；覆盖 opkg/apk × 四架构选择、Linux、Lite/Standard 阈值、摘要/缓存、失败恢复及信号清理。包管理器/服务为替身，不是实际四架构运行。

zsetup Linux x86_64 来自官方 0.3.0 发布目录，SHA256 `67abbda6c92e314c269db8d145b5e87094cf684a2efd5e450c319769f8520489` 与公开 SHA256SUMS 一致。

## 阻断与验证边界

### 索引安装失败

去掉 `--direct-only` 即复现默认完整测试。真实 0.3.0 的 `install --list` 能列出夹具中的 ddnsto；`install ddnsto --foreground -- --token ...` 返回 17，stderr 为 `zsetup: install_failed`。本地服务器尚未收到安装脚本请求，不能归因于业务包下载或桌面服务。夹具 native 版本/摘要/大小已采用真实值，问题仍存在。根因未确定，需权威 zsetup 源码/环境定位；不通过降低默认断言将索引入口标为通过。

### 完整发布包未执行

工作区缺少权威 zsetup 源码中的 `check-release-artifacts.sh` 和 `generate-product-config.py`，未运行完整 `scripts/check.sh ZSETUP_ROOT` / `tests/package_test.py ZSETUP_ROOT`。桌面候选拷贝单元测试不替代整个发布工具链。新增的完整打包测试（默认无别名、显式候选、历史保留）待该环境执行。

### 公网不满足发布条件

`python3 -B scripts/check-publication.py` 以 fw.koolcenter.com 为目标：10 项中 2 个版本指针可读，8 项不通过。

- `ddnsto/install.sh`、本地新候选 `ddnsto/0.1.4/install.sh`：404（新版本未部署）。
- `zsetup/config.json`：缺少匹配当前候选的 DDNSTO 记录。
- `ddnsto/linux-binary/SHA256SUMS`：404。
- OpenWrt standard/standard-apk 4.2.6、lite/lite-apk 4.2.2 的 SHA256SUMS：404。

这是时间点元数据证据，不表示业务二进制不存在。上线前必须从实际产物生成摘要，不可伪造或跳过校验；还需逐个镜像检查和设备 canary。

### 原生设备未验收

Windows x64/PowerShell 5.1 的权限、ACL、任务停止/进程退出、重启自启，以及 macOS Intel/Apple Silicon 的 launchd、登录、实际二进制执行、升级和身份连续性均未验收。Linux/OpenWrt 真机更新和重启也未验证。Linux 只报告 `start-requested`；OpenWrt 不具备完整包级回滚；同版本重装夹具不能证明跨版本升级。

## 后续顺序

1. 取得权威 zsetup 源码/检查器，定位索引失败，完成发布包检查。
2. 业务发布者补齐镜像产品摘要，以明确部署目标完成候选发布与回读。
3. Linux/OpenWrt 真机验证安装、更新、重启、身份保留、控制台在线，再开放官网首期命令。
4. 桌面自举/索引接入及原生验收后创建稳定入口。签名包、Keychain、安装会话和 NAS 统一适配后续迭代。
