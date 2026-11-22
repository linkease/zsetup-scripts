# zsetup 兼容与稳定通道策略

`apps/<id>/app.json` 中的 `min_zsetup` 是应用所需能力的**最低版本门槛**，不是要求设备安装
该精确版本。`scripts/build.py` 将这个值写入产品配置的 `installers[].min_version`。

各平台入口始终选择该平台已发布的最新稳定通道：Linux/OpenWrt 使用 `zsetup/stable`，
macOS 使用 `zsetup/stable-macos`，Windows 使用 `zsetup/stable-windows`。DDNSTO 与其他应用
遵守同一规则，不维护私有 zsetup 版本或摘要表。

核心执行规则：

1. 当前核心版本低于应用的 `min_version` 时拒绝执行应用。
2. 当前核心等于或高于最低版本时允许执行，包括未来更高版本。
3. 当前核心等于或高于配置中的平台 stable 时继续使用当前核心，配置不得触发降级。
4. 只有当前核心低于平台 stable 时才收敛到 stable。
5. 若新核心破坏旧应用，应先更新并验证旧应用，再提升 stable；不得用应用私有版本钉死规避兼容责任。

提升任一平台 stable 前，使用候选核心执行全部 apps 兼容门禁：

```sh
scripts/check-zsetup-candidate.sh /absolute/path/to/zsetup
```

该命令生成一致性检查、执行所有应用/契约测试并以候选核心运行集成测试。它通过后才可进入
核心自身的跨平台发布验收和 stable 切换；某个平台未运行原生门禁时，不得据其他平台结果提升
该平台 stable。
