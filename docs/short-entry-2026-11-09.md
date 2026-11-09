# 测试版短安装命令

## 群晖适配（当前 Shell 推荐）

测试控制台已加入群晖命令安装提示，统一 `/i` 不变。当前 Shell 摘要为
`bde55c2ee88dd7325d0556945ef6dc47dc3948aef7856096e8ae9f65e43428e5`，398498 字节。
DS220j / DSM 7.1 的新装、升级和启动已通过真机验收；正式环境未更新。
高级固定入口为 `/ddnsto-install/0.2.4/20261109-bde55c2ee88d/`。
下文 OpenWrt 摘要是前一版本，保留不可变文件。
详见 [群晖验证及测试发布](verification/2026-11-09-synology-auto.md)。

## OpenWrt 修复（最新 Shell 推荐）

`/i` 地址及薄入口不变，推荐 Shell SHA256 已切换为
`0edfd92285b8cec8796e8904a3a3ec9872a74c01984f5c1c19eb924e8758c59b`。
修复首次自举遇到镜像 302 而退出、无法识别官方 OpenWrt 架构版本后缀的问题。
授权设备使用公网短命令和全新 native 缓存验证启动成功，配置不变。
Windows 推荐数据与旧不可变脚本不变；下文首发 Shell 摘要是历史记录。
详见 [真机与发布记录](verification/2026-11-09-openwrt-bootstrap-fix.md)。

## Windows TrustedInstaller 兼容修复（2026-11-09 后续）

用户确认 `C:\` 的合法所有者为 `NT SERVICE\TrustedInstaller`，其他祖先目录属于
当前用户或 SYSTEM。推荐入口先前只信任用户 / SYSTEM / Administrators，因此在下载
业务安装器之前误报“缓存所有者不安全”。本次仅在非私有祖先检查中信任 TrustedInstaller
的精确服务 SID；缓存目录及文件不扩展信任名单，其他用户的写入/删除/改权限检查保持。
无需用户修改系统目录所有者或清理缓存，不记录账号 Token。

`/i.ps1` 现直接映射新长地址：
`/ddnsto-install/0.2.4/windows-entry-trustedinstaller-20261109/recommended-entry.ps1`。
它仍读取原 `recommendation-short-20261109` 下的数据清单，缓存键及业务安装器均不变。
以下首发记录中的旧 PowerShell 长地址保持原字节，不再是 `/i.ps1` 的当前映射；
Shell `/i` 不变。没有重发控制台或正式环境。

修正版入口 SHA256：`028512e7884ab84142ed31412c052b6511e6ed40bf0d77cbf281ed86aa88cfa4`，
12530 字节，UTF-8 BOM。公网短/长地址均与本地字节一致，短地址仍 200 / UTF-8 / no-store。
Nginx 只替换 `/i.ps1` 的 alias，先核对旧配置摘要、备份并通过 `nginx -t` 后 reload；
备份为 `/etc/nginx/conf.d/web.toany.net.conf.pre-ti-20261109`。

回归先失败再通过，覆盖合法祖先、合法维护 ACE、外部用户写入拒绝和私有缓存拒绝；
推荐入口测试 31 项中 25 项通过、6 项 Windows 专属测试跳过。PowerShell 语法检查与
4 项 Nginx 配置测试通过。测试在 Linux PowerShell 上模拟 Windows ACL，不能替代
用户 Windows 真机的完整安装复测。再次运行全仓 `check.sh`，仍在既有
`privilege_bridge_test.py` 因环境禁止写入 `uid_map` 中断，没有计作全量通过。代码尚未提交。

## 决策与边界

本次目标是缩短控制台复制的命令，而不是删除长地址。仅 development / staging
构建启用；production 保留原添加设备流程。仅测试站 `web.toany.net` 发布，不修改
下载站、zsetup 核心或其他应用。没有提交、推送授权。

- 默认 curl；wget 和下载后执行位于折叠区。Windows 保留 PowerShell 语法。
- 控制台将当前账号 Token 作为引用后的字面参数传入；不会放到 URL 中。
- HTTPS 及证书检查不可关闭。下载失败或空内容不会执行。
- `/i` 和 `/i.ps1` 直接提供小入口，不跳转；响应为 UTF-8、no-store、只允许 GET/HEAD。
- 小入口继续读取推荐数据，检查不可变安装器的完整大小和 SHA256，然后从私有文件执行。
  大安装器不能直接放入 `sh -c` 的单个参数，短命令没有取消这一限制。
- 同版本启动、旧版本更新、不降级及账号检查仍由现有业务执行器完成。
  安装成功、启动成功与设备在线继续区分；本次不增加在线判断。
- 旧长地址及不可变产物保留，新候选使用独立目录，避免覆盖已缓存内容。

## 使用

登录测试控制台，打开“添加设备”，复制默认命令到目标设备。无需手选设备平台。
下例 Token 是占位符；控制台自动填入实际账号 Token：

```sh
(s=$(curl -qfsS --max-time 60 https://web.toany.net/i) && test -n "$s" && sh -c "$s" -- --token 'TOKEN')
```

GNU wget 替代命令：

```sh
(s=$(wget --no-config --check-certificate --https-only --max-redirect=0 --timeout=60 --tries=1 -qO- https://web.toany.net/i) && test -n "$s" && sh -c "$s" -- --token 'TOKEN')
```

wget 支持范围是提供 HTTPS 与相关安全选项的 GNU Wget，并不代表所有 BusyBox /
uclient-fetch 都能使用此命令。不支持时使用 curl；禁止通过忽略证书验证继续安装。
`-q` / `--no-config` 防止本地配置暗中关闭 TLS 校验或跟随跳转。
第一层命令信任 HTTPS 站点；后续摘要用于核对推荐数据与安装器字节，不等同于独立签名。

## 发布布局

短路由对应新目录：
`/home/ddnsto/installer-test/ddnsto-install/0.2.4/recommendation-short-20261109/`。
其中 `recommended-*.txt` 是可变数据，必须 no-store；`immutable/<sha256>/` 不可覆盖。
旧 `/ddnsto-install/0.2.4/recommendation/` 保持原字节。

发布顺序：本地测试 → 生成并审核安装器摘要 → 上传独立暂存目录 → 回读校验 →
原子改名 → 定点增加 Nginx 路由并 `nginx -t` / reload → 发布 staging 控制台 →
公开 HTTPS、浏览器及无业务安装的 `--help` 验证。

## 2026-11-09 测试部署回执

已部署至 `test-toany`，控制台桌面与移动产物为 `index-BvmEwd55.js`。
添加设备入口：`https://web.toany.net/app/#/workbench?action=install-device`。
高级调试固定目录为 `/ddnsto-install/0.2.4/20261109-117c9a7399b2/`。

| 内容 | SHA256 |
| --- | --- |
| 最终 Shell 安装器（372012 字节） | `117c9a7399b2bdd1ef1d5bf8aa9ede148fad84cba750a54737e9464d937021ea` |
| PowerShell 安装器（46153 字节，未修改） | `4f044f50a96f215ac2c8fa1b2a106ff1e325bdbc93a48ced4a780a521e773911` |
| `/i` 薄入口（11104 字节） | `1f9791196df36996f04648916833dfd214596f372b497a7b096c65dbfb51e465` |
| `/i.ps1` 薄入口（12185 字节） | `3c2af534cf8ea629713dcf0819cbf4b8c9ce6c838c4ce2f54173b113ddbeab1f` |

先核对暂存目录实际摘要、大小与清单，再改名到新目录。Nginx 由线上现有配置定点增加
四条精确路由，保留独立门户等已有配置；修改前核对旧摘要，`nginx -t` 成功后 reload。
旧长入口摘要仍是 `03d19344ca9c7f4f329cdffe032159cf4d06d296ecb51ad8ec2721dde199afef`，没有覆盖。

验证：

- 前端相关 31 项单元测试通过，包括实际 curl + 本地 HTTPS、恶意 `.curlrc`、证书错误、
  重定向、空下载、部分下载、特殊 Token，以及实际 PowerShell 运行时的字面参数与异常测试。
- production / staging 构建通过；production 产物不含新入口和测试流程。既有大 chunk 提示仍存在。
- 本地及已部署站点的浏览器测试各 4 项通过：调试、明暗命令对比度、折叠替代方式、手动兜底及窄屏。
  只用 API 夹具模拟账号，不修改真实账号或设备。
- 固定引导策略 17 项通过；wget 隔离测试 35 项通过，包含真实 HTTPS、无 curl、到原生 zsetup 的下载交接、
  无效证书、超时、错误响应、配置污染与缓存边界。macOS 服务操作仍使用夹具，不等于真机验收。
- 生成入口 `--check`、Shell 语法与差异空白检查通过。全仓 `check.sh` 在既有
  `privilege_bridge_test.py` 受环境限制中断：`unshare: write failed /proc/self/uid_map: Operation not permitted`。
  没有把该检查或跳过的 Windows 真机相关测试记为通过。
- 公网两条短入口与两条清单均为 200 / UTF-8 / no-store，POST 为 403；不可变安装器仍为
  immutable 缓存，缺失文件为 404。入口回读与本地逐字节相同。
- 浏览器检查 `/i`：`document.characterSet= UTF-8`，中文断言通过。
- 实际执行公网 curl 短命令及 PATH 中无 curl 的 GNU wget 短命令，参数仅 `--help`：
  获取清单、验证不可变脚本、输出帮助均成功；使用专用临时缓存，未安装宿主服务或绑定设备。
  首轮曾遇短暂 DNS/下载不可用，入口明确非零退出、没有执行安装；后续直接重试成功。

备份：

- 前端：`/home/ddnsto/shared/ddnsto-static/.backups/console-2026/20261109-092100`
- Nginx：`/etc/nginx/conf.d/web.toany.net.conf.pre-short-20261109`

回退应只恢复对应前端目录及本次四条路由，先检查是否有后续发布；保留不可变产物。
复核期间未激活的 `4d6cf3a1fc03` 暂存包保留在站点根目录外的隐藏 staging 中，不属于公开入口。
本次未发布正式环境、未提交或推送；上述验证不代表全平台真机安装验收。
