# DDNSTO 小入口与标准链路测试

状态：测试已部署并完成 macOS 重复安装验收；未提交、未正式发布。

## 范围与实现

用户授权开发完成后先在测试环境部署验证。源码仍在 zsetup-scripts；不修改原生 zsetup、
控制台、ddns-server 或 ddnsto-static。未发布的 0.3.3 完整安装器包含此前 Linux 和 macOS 修复。

- 标准 Shell 入口由生成器包装为完整函数，解析完成再调用，stdin 重定向到 /dev/null。
  明确交互使用既有 /dev/tty，不让子进程读取 curl 的脚本文本。
- `scripts/package-ddnsto-test.py` 复用标准生成器，生成隔离的测试安装资源分组与索引。
  不复制第二套下载器，不改产品版本表，不写回正式 apps，不自动上传。
- 核心 bootstrap 来源保持官方；配置、索引和候选正文从测试服务器下载。
  安装器正文与当前 apps 候选逐字节相同，由 zsetup 按索引验证 SHA-256 后执行。
- 测试包有唯一目录、SHA256SUMS；已有目录禁止覆盖。

## 部署

- 目标：test-toany，复用 `/home/ddnsto/installer-candidates/` 与现有 nginx 静态路由。
- 最新地址：`https://web.toany.net/ddnsto-candidates/20261125-0.3.3-entry-r5/ddnsto/install.sh`。
- 小入口 28741 字节，SHA-256 `9de242bf1309281fd1d777a4c8b54e430e8c8ac2d9ba63f0b298bb7115959e8e`。
- 完整 Shell 正文 SHA-256 `0a83be1cc1eef281c433c62a1a5ffaca26d4d9d39f66bc21b8de8629a43e042c`。
- 本地交付：`/tmp/ddnsto-test-entry-20261125-r5`。
- 临时目录上传、服务端逐文件校验后原子重命名；未改 nginx 或重启业务服务。
- r3、r4 是失败诊断候选，保留不可变目录，不交付用户使用：r3 主源与 fallback 重复，
  r4 只传 fallback，均被 zsetup 0.6.5 拒绝；r5 使用单 primary，不追加重复 fallback。
- 正式入口、索引、下载站未更新。默认客户端业务环境仍为 production。

## 验证证据

1. 新增测试先复现不完整管道仍启动 bootstrap 的问题；修复后截断脚本拒绝执行，
   完整脚本启动且子进程不消费输入流。候选索引指向测试地址，版本正文/摘要保持一致，
   重复准备拒绝覆盖。专项 3 项通过。
2. 标准应用接口测试 5 项通过；两阶段生成检查与 diff 检查通过。
   `python3 -B -m unittest discover -s tests -p 'ddnsto*test.py'`：172 项，126 通过、46 跳过。
   此次未设置原生/旧 Shell 专项测试环境，也非 Windows 执行环境；跳过不算平台验收。
3. 公共 HTTPS 对照两个入口、两份配置、两份索引、两个完整正文，逐字节一致且 no-store。
4. macOS 192.168.9.197 / builder，UTF-8 locale，真正执行 `curl | sh`，开启 pipefail：
   status 返回 local_service=running；连续两次默认安装均 pipeline_exit=0，客户端 4.2.8，
   launchctl state=running、pid=13760。配置与设备身份文件 SHA-256 前后相同。
   诊断目录后缀 MjFOik、QVfiOa；没有使用或输出设备 Token。
5. 同机原生 zsetup 下载完整候选，故意传入全零 SHA-256：返回 11，明确报完整性失败，
   最终文件不存在、未执行。没有破坏设备安装或更改线上索引。

本轮真机只验证 macOS 已安装 4.2.8 的标准链路及幂等；不代表旧版升级、新装、Windows、
OpenWrt、群晖、华硕或 Linux 真机矩阵全部通过。旧版 4.2.1 自动迁移的隔离证据见前一记录。
设备云端在线不属于本安装器的成功标准。核心、入口及索引的信任仍依赖 HTTPS 和发布权限，
不能将摘要一致称为独立签名认证。

## 交付与撤回

分享 r5 小入口命令，不直接管道执行完整安装器。撤回测试只涉及本次独立候选地址，
不改变设备客户端版本。正式发布继续遵循完整 apps 的审核、提交和单独授权流程。

## r6：安装阶段进度与中文结果

用户反馈 r5 长时间无输出，另行要求按建议修改。新增 `sources/ddnsto/entry-progress.sh`：
立即提示系统检查、准备工具、安装信息/索引、安装器下载校验及执行；阶段超过 8 秒
定期提示仍在处理，不伪造百分比。阶段失败保留退出码并标明阶段和下一步。
bootstrap 新增可选进度回调，仅 DDNSTO 定义该回调，报告实际镜像尝试、重试和已有工具复用。
其他应用入口因共享 bootstrap 重新生成，但本次未部署其他应用。

macOS 进一步显示版本判断、客户端下载校验、启动检查；经小入口执行时展示原生客户端
下载进度，不再吞掉该下载输出。普通默认安装隐藏内部状态字段；明确 `--action status`
及未启用人类输出模式的既有调用仍保留机器可读格式。当前 Windows CLI 输出未作同等改造。
原生 install 协调器自身无逐字节进度时，使用阶段等待提示，不声称有真实百分比。

- 新地址：`https://web.toany.net/ddnsto-candidates/20261125-0.3.3-entry-r6/ddnsto/install.sh`。
- 仍使用新目录上传、全量摘要检查、原子激活，保留 r5。不改正式入口。
- 新增进度测试 3 项通过：失败退出码、耗时阶段提示、入口进度接入。
- macOS 默认流程 27 项通过，包含中文结果、重复安装和 status 格式保留。
- DDNSTO 顶层回归 175 项：129 通过、46 跳过；未配置原生/旧 Shell 等专项环境的跳过不算验收。
- bootstrap 回归 17 项：16 通过、1 跳过；平台专项 1 项通过；标准入口契约通过。
- 两阶段生成检查和 diff 检查通过。入口、配置、索引、完整正文 HTTPS 逐字节回读一致。
- macOS 192.168.9.197 / builder，在 UTF-8 环境真正执行 `curl | sh`：各阶段可见，
  显示复用工具、当前 4.2.8 无需下载、正在启动检查、中文启动成功，pipeline_exit=0。
  配置和设备身份摘要前后相同，诊断目录后缀 LlpIZQ。没有重跑其他平台真机验收。
