# KSpeeder Windows 接入准备

当前仅交付共享 `../lib/bootstrap.ps1` 和 `tests/windows_bootstrap_test.py`；还没有公开 Windows 业务入口或 catalog 映射，不宣称真实业务安装已经验收。非 Windows 四业务入口及 legacy 原样保留。

bootstrap 在 PowerShell 5.1 获取 win32 Rust：`zsetup/stable-windows` → `zsetup/<完整版本>/SHA256SUMS` → `zsetup/<完整版本>/zsetup-windows-i686.exe`。三 HTTPS primary 顺序尝试，fw.koolcenter.com 最后 fallback。Windows 首期最低 Rust 版本0.3.0（开发 fixture 可为0.3.0-dev）；完整 --version 文本必须精确匹配，不以数值兼容代替身份。SHA 必须存在、匹配，PE 必须 I386，验证后原子激活 `<ZSETUP_ROOT>/rescue/<完整版本>/zsetup.exe`，不覆盖系统 PATH 中的 zsetup。既有匹配 SHA/完整版本的实例复用，损坏缓存重取；失败保留旧文件。

`ZSETUP_ROOT` 必须绝对路径，默认 TEMP 下 zsetup；`ZSETUP_BIN` 是可复用候选，仍需校验。`ZSETUP_BOOTSTRAP_BASES` 是 HTTPS 测试/部署来源覆盖；正常业务下载不使用 PowerShell transport。`ZSETUP_CA_FILE` 提供测试或私有 CA 时仅用于当前请求的链及主机名校验，不修改系统根证书；Rust 后续下载继续 canonical webpki/显式 CA 协议。metadata 最大64KiB、stable最大128字节、依赖文件最大16MiB，OutFile 流式落盘；版本探测等待最多5秒并显式等待子进程结束。

全部 HTTPS 获取失败后，bootstrap 才能询问是否允许首次依赖的 HTTP；默认拒绝，无交互时拒绝。与既有 POSIX 同名的 `ZSETUP_CONFIRM_FILE` 可提供一个明确答复，文件最大1KiB。HTTP 不能传给 Rust 下载器，业务下载也没有 HTTP 例外。重定向不自动跟随。

原生安全测试（已有 Python/OpenSSL 放入 PATH、TEMP 指向隔离 D 盘目录）：

```powershell
python -B kspeeder/tests/windows_bootstrap_test.py D:\tests\zsetup.exe --report D:\tests\bootstrap.json
```

测试只运行 zsetup --version、隔离 TLS/HTTP 和临时文件；不执行 KSpeeder 安装、服务或修改机器 PATH。测试必须在 Windows 运行，交叉编译不算通过。Windows10 x64 WOW64/PS5.1 已通过8组，原生 Windows11 仍缺环境。

业务接入前置：实际 Windows amd64 产品须由业务服务器提供不可变版本路径、真实 SHA256/size；当前官方 ks-cli-version.txt 缺 Windows 摘要。参考 ks-cli 默认菜单的安装动作即使管理员启动仍会 UAC，需用户决定保留菜单并等待业务方修正，或新入口默认 installer install --elevated。此库不构建/打包 Go 业务产物、不撤销旧入口、不切公网配置指针。
