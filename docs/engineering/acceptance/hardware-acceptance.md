# acceptance/hardware-acceptance — 真实硬件验收清单

**模拟（mock）测试通过 ≠ 真实验收通过。** 下表场景在 mock 测试里永远只能算「逻辑正确」，不能标记为「实机通过」。没有实际执行的项目保持「待验收」，禁止伪造通过记录。

**边界：未经用户明确授权，绝不在用户当前工作环境执行真实锁屏、黑屏、休眠、关闭显示器或修改电源策略；绝不替换用户当前安装的 `/Applications/MacPilot.app`。** 需要真实屏幕/电源状态验收时，要求用户明确授权并尽量使用隔离的 AgentSpace 会话与可逆恢复。

## 待验收项（每次涉及对应模块的发布/重大修改后执行）

| # | 场景 | 触发模块 | 参考文档 | 状态 |
|---|---|---|---|---|
| 1 | 黑屏与亮屏（背光 0 ↔ 恢复），内屏 | display-recovery | docs/DISPLAY_CONTROL_MANUAL_TESTS.md | 待验收 |
| 2 | 外接显示器 DDC 黑屏→断电→重连→恢复 | display-recovery | 同上 | 待验收 |
| 3 | 显示器热插拔、新旧拓扑切换期间未完成事务 | display-recovery | docs/DISPLAY_CONTROL_DESIGN.md | 待验收 |
| 4 | 系统睡眠与唤醒（含合盖）、唤醒后监控恢复 | ble-presence / display-recovery | docs/AWAKE_MANUAL_TESTS.md | 待验收 |
| 5 | 锁屏与 BLE 自动解锁/手动锁屏不被覆盖 | ble-presence | docs/RELEASE_REGRESSION_TESTS.md | 待验收 |
| 6 | 手机息屏后台挂起 vs 真实离开的判定 | ble-presence | docs/BLE_FALSE_LOCK_DIAGNOSIS.md | 待验收 |
| 7 | FinderSync 系统扩展启用态、Finder 右键菜单 | helper-lifecycle | zsh Scripts/verify-findersync.sh（只读） | 待验收 |
| 8 | 真实 AppKit 菜单事件分发（逐项点击） | menu-bar-lifecycle | — | 待验收 |
| 9 | 关窗后从菜单/Dock/Finder 深链重开主窗口 | window-lifecycle | — | 待验收 |
| 10 | 更新→安装→relaunch 全流程（含 FinderSync 启用机） | updater-release | — | 待验收 |
| 11 | 键盘背光恢复、DDC 唤醒 | display-recovery | docs/DISPLAY_CONTROL_MANUAL_TESTS.md | 待验收 |
| 12 | macOS 14 最低目标系统清单 | 全部 | acceptance/macos-compatibility.md | 待验收 |

执行后把「待验收」改为「已于 YYYY-MM-DD 在 <设备/系统> 验收通过/失败 <证据>」。失败的项回到对应 regressions/ 文档的规则里追加证据。

## 已被自动化覆盖、无需实机的部分（对照，防止重复人工劳动）

- 显示恢复事务日志/最后一块屏保底：`ScreenControlSafetyTests` 等（逻辑层）。
- BLE 挑战 cadence 重武装：`ProximityGATTProductionRestartTests`、`BLEReversePresenceTests`（mock）。
- 菜单动作分发存活：`MenuBarOwnedMenuTests`（AppKit 对象语义，仍建议实机点一遍）。
