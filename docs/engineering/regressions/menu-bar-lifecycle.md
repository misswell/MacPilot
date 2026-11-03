# menu-bar-lifecycle — 菜单栏、NSMenu 与动作分发

规则：`menu-001-status-item-popup-placement`（弹窗定位）、`menu-002-session-release-vs-action-dispatch`（session 释放 vs action 派发）、`menu-003-status-item-reattachment`（图标消失）、`menu-004-menu-rebuild-cost`（重建成本）。证据链见 [../REGRESSION_CATALOG.md](../REGRESSION_CATALOG.md) A2–A5。

## 不变量

### 入口存活（原 AGENTS.md「Dock and menu-bar icons」全文）

- **至少一个入口永远存活。** 两个入口（Dock 图标、菜单栏图标）新装后都显示，用户可在设置里隐藏其一——但绝不能两个都藏。`AppPresenceSettings.normalized()` 在存储的组合两者皆无时恢复菜单栏图标；`allowingDockIconChange` / `allowingMenuBarIconChange` 拒绝去掉最后一个的变更，设置开关在该状态禁用而不是静默拒绝。手改配置或未来构建写出的双藏组合绝不能让运行中的 app 无路可回。
- **只有菜单栏仍提供入口时，Dock 图标才跟随主窗口。** `AppPresencePolicy.showsDockIcon` 在两者都启用时返回窗口状态，在 Dock-only 配置下永远 `true`——那里图标是唯一入口，必须比窗口活得久。关窗切到 `.accessory`，重开（菜单栏、Dock 点击、深链）切回 `.regular`；`LSUIElement` 在 Info.plist 保持 `true`，策略在运行时应用。
- **`willClose` 是唯一的关闭信号。** 登录启动路径 `hideRegularWindows` 里的 `orderOut` 不得隐藏 Dock 图标：隐藏的窗口不是关闭的窗口。
- **status item 必须永远留下 item。** `MenuBarDisplayController.scheduleReinsert` 移除 item、等待、重装；离开那个移除窗口的每个出口——包括取消的睡眠——都必须恢复它，否则 `reinserting` 置位却无 item 无 task，图标消失直到重启（v1.2.2-beta.59 native-menu 改造后的实测事故）。`scheduleReinsert` 在下一轮前同步恢复；`selfHeal()`（由 `startWatchdog` 驱动）兜底。
- **状态 item 能显示的每条警告都必须在首页点名。** 三角形是 `AwakeSessionManager.hasAttentionIssue`；`HomeView` 渲染同一 `attentionIssues` 列表，图标永远不能指向 app 无法解释的失败——包括 Awake 功能被关闭、其页面不可达之后。退役未用电源服务时出现的合盖失败保持 `ClosedLidSleepFailure.stage == .retirement`，绝不能被描述成失去睡眠保护。`HomeAttentionTests` 钉住图标/列表一致性与中英文案。

### 菜单定位与动作分发

- **status item 必须挂真实 `NSMenu`，绝不自己定位弹窗。** `MenuBarDisplayController` attach 菜单并在 `menuNeedsUpdate(_:)` 填充，AppKit 负责定位、高亮、跟踪。`NSMenu.popUp(positioning:at:in:)` 无法复刻——它的锚点相对 *button* 而非菜单栏，任何手算点都偏高（macOS 27 实测 `bounds.minY` 高 24pt、`bounds.maxY` 仍高 6pt，而 AppKit 自挂菜单顶边在菜单栏底边下方 1pt）。那 6pt 就是「右键菜单顶进菜单栏」反复修不掉的 bug。禁止重新引入 click action + `performClick`、锚点辅助函数或任何 `popUp` 调用；`MenuBarOwnedMenuTests` 在 item 停止拥有 AppKit 定位的菜单时失败。
- **快照每次打开固定。** `menuNeedsUpdate` 在显示前填充挂载的菜单。
- **`menuDidClose` 不得同步释放 session。** macOS 27 在 `menuDidClose` 之后（同一 run-loop turn，实测）才派发所选 item 的 action，`NSMenuItem` 持弱引用 target——立即释放清零所有 `ActionRelay`，每个菜单动作静默失效而点击照常关闭弹窗。controller 在 `menuDidClose` 停止持有 session，捕获引用延后一个 main-queue turn 释放；`MenuBarOwnedMenuTests.relayTargetsSurviveThePostCloseActionDispatchAndDropOneTurnLater` 钉住两半。

### 性能

- **status item 只允许图标。** 绝不在状态图标旁画数字或文本 badge：带文本的 SwiftUI label 每次模型 tick 重建整棵菜单命令树（实测空 60ms、30 行 909ms、1704ms@90 行），且用户明确移除了 CPU 百分比 badge。弹窗读打开瞬间的固定 `MenuBarMenuSession` 快照；button 只持有 image。CPU 数字只存在于 CPU Monitor 页面与其菜单 section。

## 必跑测试

`AppPresenceTests`、`MenuBarDisplayControllerTests`、`MenuBarMenuSessionTests`、`MenuBarOwnedMenuTests`、`MenuBarStatusItemVisibilityTests`、`HomeAttentionTests`、`MonitorMenu*`、`ConfigurationSchemaContractTests`（presence 走配置键）。

## 人工验收

- 真实 AppKit 菜单逐项点击（设置 / 显示器 / 快速搜索 / 退出）——分发链路是系统行为，模拟测试不可全替。
- 右键/左键菜单顶边与系统状态菜单平齐（最新 macOS）。
- 开关两个入口图标、试图双藏；睡眠→取消睡眠后图标仍在。
- 开着的菜单在后台数据刷新时不整树闪烁；大规模行数下打开延迟不可感知。
