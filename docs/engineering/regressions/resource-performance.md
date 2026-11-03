# resource-performance — CPU、内存、定时器与后台资源（含 Clipboard / Pinned pin 功能级不变量）

规则：`perf-001-unbounded-accumulation`。证据链见 [../REGRESSION_CATALOG.md](../REGRESSION_CATALOG.md) H1 与 A5。

## 不变量

### 资源累积

- 重复事件必须节流去重（BLE 扫描同日两修的根因：重复 scan 事件无界累积）；定时器、监听器、任务随对象释放注销；禁止随时间累积的无用任务列表。
- 功能关闭即停任务/释放缓存（见 helper-lifecycle.md help-002-on-demand-processes 的完整按需生命周期要求）；页面关闭后不继续持有不必要资源。
- **性能测试锁数量与状态机**（任务数、注册数、发布次数、对象释放），不锁墙钟时间——全量 suite 的 MainActor 饥饿会让时序断言在隔离 0.06s、全量 3.98s（见 AGENTS.md 已知抖动清单与 tests-main-actor-starvation 经验：时序测试必须注入调度器）。取消任务后旧回调不得继续更新 UI。
- 资源阈值验收：`Scripts/measure-memory.sh` + `Tests/Performance/README.md` + `docs/MEMORY_REVIEW.md`。

### 剪贴板历史与预览（原 AGENTS.md 全文）

- 在加载/裁剪持久记录**之前**把配置的 `storageLimit` 传进 `ClipboardHistory`。初始化之后再应用上限会按默认上限永久丢弃历史及其内容文件。
- 历史不因年龄过期。保持计数/2 GiB 内容上限与重复合并；两种 UI 语言都披露这些行为。不删除已持久化的设置键。
- 预览可见性变化只调整面板右缘，无 AppKit/SwiftUI 动画。保持 1 秒 hover 延迟与行→预览的短宽限期；不保留第二份延迟折叠布局。
- 用隔离的 `Clipboard` 套件验证（含 Model 设置 → 首次历史加载 → flush/reload）。**绝不修改用户实时历史或通用 pasteboard。**
- 多屏选择测试必须到达 `SnapzyAreaSelectionController` 与 `FrozenAreaCaptureSession`，不能只测旧裁剪 helper。注入 presentation/cursor 效果让测试窗口不可见。直接 handler 通过不等于 WindowServer 真实指针事件路由正确。
- 智能元素 resolver 返回屏幕坐标；overlay 选择 delegate 接受 view 本地坐标。每个边界**恰好换算一次**（含 content-view inset）。覆盖已识别元素单击与非零原点显示器上的手动/智能拖拽。

### 钉住的截图 hover（原 AGENTS.md 全文）

- pin 只有在拥有指针所在像素时才可响应。菜单、combobox 下拉、tooltip 画在 pin 的 `floating + 2` 层之上；按几何 frame 命中响应曾让 pin 抢 key 窗口状态并关闭别的 app 的弹窗——重叠在 pin 上的条目永远点不到。用 `QuickAccessPinHoverCoverage`；**短或空的 window-server 扫描答案是 "exposed"，绝不是 "covered"**。
- Dock 自己的窗口横跨整屏（level 20）而 Dock 只画条带，所以**绝不**算覆盖面：`isDockSurface` 丢弃 Dock 层及以下的 `com.apple.dock` 窗口。曾把它算进来导致主屏的 pin 永不 hover、无 Dock 的副屏正常。Dock 菜单在 popup 层，仍算。
- 覆盖判定要跑一次 `CGWindowListCopyWindowInfo`，所以走**边沿触发 + 间隔节流**（`sweepIsWorthRunning`）——exposed 且已 key 的 pin 零次扫描。不要把调用搬进每个指针事件，保持坐标换算只做一次（一块主屏高度、一次减法）：每窗口重建 `DisplayMapping` 在这条路径上太贵。
- 锁定的 pin 保持几何鼠标穿透：永不取 key 状态、无 hover chrome，覆盖与否不改变点击可达性。
- pin 共享一对本地/全局鼠标 monitor。hover 状态只在转换时发布；重复指针位置不得让每个 pin 的 SwiftUI view 失效。关闭/挂起最后一个 pin 移除两个 monitor。缩放缓动跨刷新率走时间基准，每个手势复用 HUD 隐藏 timer。`QuickAccessPinPerformanceTests` 覆盖发布次数、共享 monitor 生命周期与缩放行为，不显示窗口。

## 必跑测试

`ResourceLifecycleTests`、`FeatureResourceLifecycleTests`、`MemoryLifecycleTests`、`MemoryMonitorTests`、`ProcessCacheTests`、`CPUMonitorTests`、`BLEUnlockPerformanceTests`、`QuickAccessPinPerformanceTests`、`DockGroupsPerformanceTests`、`MonitorMenuSnapshotCacheTests`、`Clipboard*` 隔离套件、`QuickAccessTests`。

## 人工验收

`Scripts/measure-memory.sh` 长时间运行对比基线；实机观察 pin 与 Dock 菜单/tooltip 的交互（模拟测试不可全替的 WindowServer 行为）。
