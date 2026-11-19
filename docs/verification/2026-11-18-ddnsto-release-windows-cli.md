# 测试发布：Windows CLI 与控制台安装引导

状态：测试站已发布，Windows 公共命令真机验收通过，线上前端浏览器检查 7 项通过。

## 范围与授权

- 2026-11-18 用户明确要求更新测试服务器；沿用此前 Windows 真机验证授权。
- 目标仅 tx-nj-02.kooldns.com:2233 / web.toany.net。正式环境不变，不提交或推送。
- Windows CLI 保持 4.2.8，产品包及其摘要不变。修复推荐入口缓存替换、已校验脚本执行方式、生成 PowerShell BOM。
- Shell 推荐入口与清单不变，其他平台及 native-first 策略不变。
- scripts 源 HEAD aa8b2e99e6ba2b3254dd85f9c39b0cf483160f93 + 本轮未提交修复。
- 前端使用当前工作分支 staging 构建，仅更新 app 与 app/mobile；不覆盖其他静态目录。
- 产品、真机、测试及已知限制沿用 [Windows 验证记录](2026-11-18-windows-cli-entry.md)。没有宣称空白新装、跨版本升级或重启系统验收通过。

## 已审核字节

- Shell：5096a3525f30dd4b6eab6adf93672f1b93bdc262d1abac4bfaffff305fed0d46（不变）。
- Windows install.ps1：f2631f66338cccf3c55e9818e0cce1a47241961c60e763364d65f868e0bdad14。
- 实时旧 Windows 清单：b2c638dedd27918c218c7a9ac6cbc4384ec7191cfb4160d5004123732cc7033b。
- 实时旧 i.ps1：028512e7884ab84142ed31412c052b6511e6ed40bf0d77cbf281ed86aa88cfa4。
- 实时旧控制台 index：df1b2f644c87abf58ef08aaf132c03d4cc7f0d20f0188603d29b87819bacb7d9（桌面与移动一致）。

## 发布与验收

2026-11-18 07:13–07:15 UTC：不可变文件先上传并 HTTPS 回读匹配，持发布锁核对旧摘要、备份，再原子切换 Windows 清单与入口。

| 文件 | 发布后 SHA-256 | 公网读回 |
|---|---|---|
| i.ps1 | 9f2346bdb283efe18b33ec403864983ebaacaad0777d6afbb7ac9c570572dc82 | 一致，HTTP 200/no-store |
| recommended-powershell.txt | eb1590f0a36fee32e080ae3e8404f00b018d7dd9a2b57182ac4104ca24bcc951 | 一致，HTTP 200/no-store |
| immutable/f2631f66…/install.ps1 | f2631f66338cccf3c55e9818e0cce1a47241961c60e763364d65f868e0bdad14 | 一致，46282 字节 |
| app/index.html 与 app/mobile/index.html | 5a9f4270c5e90e3f7092aa83be5cd7e86cc99c1482614d1231ecb7e74e61d22f | 均一致 |
| candidate-install-step-D7vYQWeJ.js | 6ee2e6110bf828aa43daf76023f945730c6e55f35fc766fe096a0cf2bba72ebd | 一致 |

- 候选目录：dist/windows-cli-20261118-f2631f66，包含 review.json；入口策略保持 native-first。
- 脚本备份：/home/ddnsto/installer-test/.backups/windows-cli-20261118-f2631f66/。
- 前端备份：/home/ddnsto/shared/ddnsto-static/.backups/console-2026/windows-cli-20261118/app/，含 mobile。
- 前端 source master/0760b13940866d977d51b82c1e495211aa27ca93 + 本轮未提交 UI 修改；pnpm build:staging 与 staging analytics 检查通过。
- 仅同步 app、app/mobile，资源先行、index 最后原子替换，不删除旧 hash 资源，不修改本地 ddnsto-static 的既有其他工作区修改。
- Shell 入口 SHA 保持 ce960d70a5176105d199c39405cd17ea2e191eb316e9f677918945da4a6a2ec6；Shell 清单 SHA 保持 e5fd6ed736f69d67ecf0f97cef5e7fc9035ac0f4715b1e8ac914ca5e743186e0。
- Windows 192.168.9.199 使用控制台实际公共 /i.ps1 命令、原授权账号 Token 重复 ensure 成功，返回版本 4.2.8 / local_service=running。
- 诊断日志后缀 fe9603d562d9427fa26f4dedb7d9f1c0；进程数 1、PID 10472、计划任务 Running、执行策略仍 Restricted，配置/身份/管理标记与测试前 SHA 比较一致。
- 同一公共命令再次执行通过，覆盖已有新版本缓存的替换路径；第二次诊断日志后缀 2ccd3c395077452c90981661a3553055。
- 本轮公共命令验证不使用本地 transport fixture。未做空白新装、跨版本升级、系统重启或云端在线验收。
- INSTALLER_TEST_BASE_URL=https://web.toany.net/app/ 的 installer.spec.ts 浏览器测试 7 项通过：加载真实线上静态文件，使用模拟账号/API 数据，不修改真实账号；覆盖 CLI 折叠及命令、GUI/AI、复制、移动端、明暗主题与调试页。

回滚只恢复本轮入口与清单或控制台 index，先核对当前摘要；保留新旧 hash 资源及用户配置。
未执行回滚演练；未发布正式环境；未提交或推送。
