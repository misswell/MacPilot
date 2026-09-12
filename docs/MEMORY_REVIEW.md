# MacPilot 内存与功能开关代码评审

评审目标：**降低内存占用、消除内存泄漏、所有功能都要有开关，且开关关闭时不得占用内存与性能。**

评审范围：`Sources/` 全部 7 万余行 Swift 代码（含 16 个功能模块、FinderSync 扩展、辅助进程），
按模块并行审计后逐条复核。本文件记录结论、已落地修复与待办清单。

> 说明：本次评审期间工作区里还有另一处未提交的在建改动（闭盖休眠 / 熄屏 / 提权 helper），
> 因此本文件只描述本次评审相关的改动；发版前请把两批改动分开提交。

---

## 一、结论摘要

| 维度 | 结论 |
| --- | --- |
| 内存泄漏 | 发现 **4 处确定性泄漏**，已全部修复（事件 tap 未失效、VideoToolbox 会话未回收、无上限字典缓存、自递归重试任务） |
| 无用内存占用 | 启动时无条件分配/扫描/解码共 **6 处**，已修复 5 处，1 处记录待办 |
| 功能开关 | 16 个功能中，**13 个有关闭即停的总开关**；本轮为「屏幕录制」新增总开关；**Awake、右键菜单、内存监控** 仍缺总开关（见 §四） |
| 退出清理 | 原本 15 个功能只有 6 个挂了退出清理、且其中 3 个是异步调度（必然丢失）；已改为单一同步 `MacPilotModel.shutdown()` |
| 验证 | `swift build` 通过；`swift test --skip shortcutConfigEncodesAndDecodesCarbonModifiers` **558 个测试 / 48 个套件全部通过** |

---

## 二、已修复

### A. 功能关闭时仍在运行的路径（最严重）

| # | 位置 | 问题 | 修复 |
| --- | --- | --- | --- |
| A1 | `Sources/MacPilot/MacPilotApp.swift:1536`（改前） | BLE 关闭时仍在启动阶段安装 8 个进程级通知观察者（4 个 `NSWorkspace` + 4 个 `DistributedNotificationCenter`，含屏保/锁屏通知），且 `BLEUnlock.swift` 全文没有 `removeObserver`/`deinit`，**永不释放** | 观察者改为仅在启用时安装：`BLEUnlockModel.activateFromConfiguration()` 与 `setEnabled(true)` 安装，`setEnabled(false)` 调 `stopObservingSystemState()` 移除 |
| A2 | `Sources/MacPilot/Recording/ScreenRecordingModel.swift:148` | 录屏**没有总开关**；每次启动都 `registerAllHotKeys()`（Carbon 全局热键）+ `refreshCaptureDeviceLists()`（枚举摄像头/麦克风/Continuity 设备），即使用户从不录屏 | 新增 `ScreenRecordingSettings.isEnabled`（Codable，默认 `true` 保持既有行为）、`setEnabled(_:)`、启动/设置页 `onAppear` 全部加守卫；关闭时注销热键、关闭浮层与预览、停止鼠标高亮/放大镜。显式点「开始录制」会自动重新打开开关，避免"关了就没反应" |
| A3 | `Sources/MacPilot/ScreenCapture.swift:666` | 截图功能关闭时，启动仍执行 `CloudManager.apply`、历史解码、**递归遍历输出目录统计磁盘占用**、以及**删除 Captures 目录下所有临时文件** | 把磁盘统计 + 临时文件清理 + QuickAccess 标注接线收进 `refreshCaptureHousekeeping()`，仅在 `screenshotEnabled \|\| isEnabled` 时执行；重新打开开关时补跑 |
| A4 | `Sources/MacPilot/Clipboard/ClipboardModel.swift:154` | 功能关闭时修改快捷键仍会注册系统级 Carbon 热键，该组合被永久吞掉，但面板又打不开 | `setHotkey` 仅在 `settings.isEnabled` 时 `updateBinding`，否则 `hotKeyCenter.stop()` |
| A5 | `Sources/MacPilot/SmoothScrolling/SmoothScrollController.swift:72` | 平滑滚动一旦启用就在激活时启动 `CVDisplayLink`，而空闲时 `eventTemplate == nil` 导致停止条件永远不成立 → 触控板用户会一直跑显示刷新率回调 | 激活时不再 `runtime.start()`；由 `SmoothScrollRuntime.update(event:)` 在首个滚轮事件时懒启动、滑行结束自动停止 |
| A6 | `Sources/MacPilotRightClickKit/RightClickMenuCoordinator.swift:106` | Finder 扩展未启用时，`sendObserveDirMessage()` 每 3 秒自递归，任务既不保存也无法取消，贯穿整个 App 生命周期 | 改为带上限（20 次）的可取消任务并存入 `observeDirTask`；新增 `stop()` 取消心跳与重试 |

### B. 确定性内存泄漏

| # | 位置 | 问题 | 修复 |
| --- | --- | --- | --- |
| B1 | `Sources/MacPilot/Recording/RecordingEngine.swift:318` | `VTCompressionSessionCreate` 探针会话从未 `VTCompressionSessionInvalidate`，而成功路径直接 `return`——**每次 H.264 录制都泄漏一个硬件编码器会话及其缓冲** | 两条路径都先 `VTCompressionSessionInvalidate(session)` |
| B2 | `Sources/MacPilot/PictureInPicture.swift:2359` | PiP 的 CGEvent tap 只 `tapEnable(false)`，从未 `CFMachPortInvalidate`，窗口服务器里的注册会残留，每次启停再叠加一个 | 补 `CFMachPortInvalidate` + `CFRunLoopSourceInvalidate` + `context.setEventTap(nil)` |
| B3 | `Sources/MacPilot/SmartScreenshot.swift:1899,1955` | 截图快捷键/选区两个 tap 同样只禁用不失效（全文无 `CFMachPortInvalidate`） | 两处 teardown 补齐 |
| B4 | `Sources/MacPilot/InputSourceFeature.swift:1236`、`Sources/MacPilot/WindowSwitcher.swift:2498` | 同类 tap teardown 不一致（与 `SmoothScrollController` 的正确写法相比缺 invalidate） | 统一补齐 invalidate + source invalidate |
| B5 | `Sources/MacPilotRightClickKit/IconCache.swift:17` | `[String: NSImage]` 以路径为 key 且**永不淘汰**，启动还预加载；`icon.size` 只改逻辑尺寸，全分辨率表示常驻 | 改为 `NSCache`（`countLimit 256`、`totalCostLimit 8MB`，按像素计费） |
| B6 | `Sources/MacPilotRightClickKit/RightClickMenuCoordinator.swift:45` | 块式通知观察者 token 被丢弃，无法移除 | token 存入 `configObserver`，`stop()` 中移除 |

### C. 退出清理

| # | 位置 | 问题 | 修复 |
| --- | --- | --- | --- |
| C1 | `Sources/MacPilot/MacPilotApp.swift:1442-1458`（改前） | 3 个功能的 `shutdown()` 被包在 `Task { @MainActor in … }` 里；`willTerminate` 返回后立即 `exit()`，这些任务**几乎不可能执行** | 改为单一同步 `willTerminate` 观察者直调 `shutdown()` |
| C2 | 同上 | 15 个功能只有 6 个挂了退出清理；BLE / InputSource / WindowSwitcher / 压缩 / PiP / 右键协调器全无 | 新增 `MacPilotModel.shutdown()`：停安全检查、取消退出/启动任务、逐个调用各模型 `shutdown()`、移除全部观察者；并补上缺失的 `shutdown()` 实现 |
| C3 | `Sources/MacPilot/FileCompression.swift` / `InputSourceFeature.swift` / `WindowSwitcher.swift` | 相应模型没有同步 teardown 入口 | 分别补 `shutdown()`（停 FSEvents / 停轮询+tap+观察者+功能键还原 / `stopRuntime()`） |
| C4 | `Sources/MacPilot/MemoryMonitor/MemoryMonitorModel.swift:11` | `static var cachedMenuSample` 常驻整个进程 | 新增 `clearMenuCache()`，退出时清理 |

### D. 其它

| # | 位置 | 问题 | 修复 |
| --- | --- | --- | --- |
| D1 | `Sources/MacPilot/BLEUnlock.swift:967` | 关闭 BLE 只 `stopScan()`，`CBCentralManager` 及其蓝牙 XPC 会话与 delegate 图常驻 | 关闭时 `delegate = nil; centralMgr = nil`，下次启用由 `ensureCentralManager()` 重建 |
| D2 | `Sources/MacPilot/ScreenControl/MacScreenControlService.swift` | 屏幕保护状态观察者由 BLE 代码持有，而**远程解锁也要读 `screensaverActive`**——简单按 BLE 开关关闭会静默破坏远程解锁 | 观察者迁到共享的 `MacScreenControlService`，由 `MacPilotModel.refreshScreenStateObservation()` 按 `BLE 启用 \|\| 远程启用` 安装/移除；`RemoteControlServer.onRunningStateChanged` 在启用状态变化时回调 |
| D3 | `Sources/MacPilot/RemoteControl/RemoteControlServer.swift:125` | `stop()` 无条件访问 lazy `bleCentral`，会为了关闭而**新建**一个 CoreBluetooth central | 加 `bleCentralStarted` 标志，未启动过就不创建 |
| D4 | `Sources/MacPilot/Recording/RecordingEngine.swift:854` | `finishInputs()` 抛错时 writer 既不 finish 也不 cancel，`.recpart` 文件与输入长期残留 | 出错路径 `cancelWriting()` + 删除工作文件后重抛；`cancel()` 同样补 `cancelWriting()` |
| D5 | `Sources/MacPilot/Recording/RecordingMobileRecorder.swift:175` | `stopRecording()` 以 `captureSession?.isRunning` 为条件，会话被系统中断时**跳过停止**，movie output / 会话 / 文件句柄全部滞留且不回调 | 无条件调用 `output.stopRecording()` |
| D6 | `Sources/MacPilot/Awake/AwakeSessionManager.swift:302` | `sessions` 只 append 与改状态，**永不删除**，长期运行会累积每一次会话 | 新增 `pruneEndedSessions()`，已结束会话上限 20 条 |
| D7 | `Sources/MacPilot/SnapzyQuickAccess/QuickAccessManager.swift:628` | `pinScreenshot(url:)` 独缺 `guard isEnabled`（`addScreenshot`/`addVideo` 都有），关闭状态下仍会创建钉图窗口 | 补守卫与诊断日志 |
| D8 | `Sources/MacPilot/SnapzyCapture/AreaSelectionWindow.swift:2980,3040,3101` | 三个光标是 `static var`，**每次鼠标移动**都重绘 `NSImage` 并新建 `NSCursor`，导致身份守卫永远不命中 | 改为 `@MainActor static let`，只构建一次 |
| D9 | `Sources/MacPilot/ScreenRecordingModel.swift:899` | `refreshCaptureDeviceLists()` 在 `applyLoadedSettings` 中无条件执行（启动路径） | 仅在 `isEnabled` 时执行 |

---

## 三、功能开关矩阵（本轮结束后）

| 功能 | 总开关 | 默认 | 关闭时的行为 |
| --- | --- | --- | --- |
| 退出规则 | `isEnforcing` + 每条 `rule.isEnabled` | 开 | 取消全部退出任务与安全检查 ✅ |
| 启动规则 | `isLaunchSchedulingEnabled` + 每条规则 | 开 | 取消计划 ✅ |
| Awake 防休眠 | **无总开关** ⚠️ | — | 启动仍安装系统观察者（见 §四‑1） |
| BLE 解锁 | `BLEUnlockSettings.isEnabled` | 关 | 不装观察者、不建 CBCentralManager ✅ |
| iPhone 遥控 | `RemoteControlSettings.isEnabled` | 关 | 不监听、不建 BLE central ✅ |
| 输入法切换 | `InputSourceSettings.isEnabled` | 关 | 不装观察者/tap、不轮询浏览器 ✅ |
| 存储压缩 | `automaticallyCompress`（+ 文件夹非空） | 关 | 不启 FSEvents ✅ |
| 截图 | `screenshotEnabled`（智能截图）/ `isEnabled`（定时截图） | 关 | 不做磁盘扫描/临时清理、不注册热键、不建 smart capture 控制器 ✅ |
| 屏幕录制 | `ScreenRecordingSettings.isEnabled`（**本轮新增**） | 开 | 不注册热键、不枚举设备、关浮层 ✅ |
| 画中画 | `PictureInPictureSettings.isEnabled` | 关 | 不装 tap/观察者、停 occlusion ✅ |
| 窗口切换 | `WindowSwitcherSettings.isEnabled` | **开** ⚠️ | 停 runtime、移除 tap/AX/观察者 ✅（默认值策略见 §四‑4） |
| 平滑滚动 | `SmoothScrollSettings.isEnabled` / `reverseScrollingEnabled` | 关 | 全部关时 `requiresInputTap == false`，不建 tap；空闲不再跑 display link ✅ |
| 剪贴板 | `ClipboardSettings.isEnabled` | 关 | 停监听与热键、关面板 ✅（历史仍在内存，见 §四‑3） |
| 右键菜单 | **无总开关** ⚠️ | — | 启动即建协调器（见 §四‑2） |
| 内存监控 | **无开关**（仅页面级） | — | 打开页面才采样；菜单采样有 2s 缓存 ✅（见 §四‑3） |
| 存储压缩监控 | 同「存储压缩」 | 关 | `stopMonitoring()` ✅ |

---

## 四、待办（按优先级）

### 1. Awake 缺总开关（P1，**最高优先**）
现状：`AwakeSettings`（`Sources/MacPilot/Awake/AwakeModels.swift`）没有任何总开关；
`AwakeSessionManager.init`（`AwakeSessionManager.swift:77`）与 `AwakeTriggerEngine.init`（`AwakeTriggerEngine.swift:52`）
各自无条件 `installSystemObservers()`，并在 init 里就采样电源/应用/进程/显示状态。

建议改动：
1. `AwakeSettings` 增 `var isEnabled: Bool`（Codable，默认 `true`，`decodeIfPresent(...) ?? true`）。
2. 两个 engine 的 `installSystemObservers()` 从 `init` 移出，改由 `setEnabled(_:)` / `activateFromConfiguration()` 控制；
   `shutdown()` 已具备完整卸载逻辑，可直接复用。
3. `AwakeSettingsView` 顶部状态卡加总开关；`MacPilotModel` 启动时按开关激活。
4. 关闭时结束活动会话（`endAllSessions()`），否则会留下系统断言。

> 本轮未改：该文件正被另一处在建改动同时编辑，避免冲突；改动本身是自包含的。

### 2. 右键菜单 / FinderSync 缺总开关（P1）
`RightClickMenuCoordinator`（SwiftData + Messager + 图标预加载 + 心跳 + 重试）在
`MacPilotApp.startRightClickMenu()` 无条件启动，`AppState` 只有 `fold*`/`showCommonDirs` 等子选项。
建议在 `AppState` 增 `isRightClickMenuEnabled`，`startRightClickMenu()` 与设置页绑定，
关闭时调用本轮新增的 `RightClickMenuCoordinator.stop()` 并向扩展发送退出通知；
`MacPilotFinderSyncExt` 的心跳（`MacPilotFinderSyncExt.swift:130`）也应在 `.quit` 消息后停止。

### 3. 启动即解码 / 常驻内存（P2）
- `ClipboardModel.history = ClipboardHistory()` 在 `init` 就 `load()` 整个历史（含旧版内联图片/大数据）。
  需要把 `ClipboardHistory` 改成首次访问才加载（`ensureLoaded()`），**并注意**
  `storageLimit` 的 `didSet` 会 `save()`，未加载时保存空数组会**清空用户历史**——必须让
  `applyLoadedSettings` 在加载完成前不触发保存，否则会造成数据丢失。
- 内存监控页无持久化开关；`MemoryMonitorModel.startAutoRefresh()` 只应随页面可见性启停（现有调用点已如此）。

### 4. 窗口切换默认值策略（P2）
`WindowSwitcherSettings.isEnabled` 解码默认 `true`：老配置文件（无该字段）会在启动时
启动隐藏面板、5 个 workspace 观察者与全局快捷键，且需要辅助功能权限才会真正启动。
建议显式决定：要么保持默认开启并在 UI/README 说明，要么改为 `?? false` 让用户显式启用。

### 5. 截图相关大内存峰值（P2）
- `SmartScreenshot.swift:3922` 滚动截图累积**最多 30 张全分辨率 CGImage**（3000×2000 区域约 24MB/张
  ≈ 720MB 峰值），且 `stitch` 在 `@MainActor` 上执行。建议按总像素预算（如 200MP）限制、
  追加时降采样，并把 `stitch` 放到 `Task.detached`。
- `ScreenshotExtras.swift:239` 的 `bestOverlap` 对每对相邻帧建**两份**全分辨率 `[UInt8]` 栅格；
  建议每帧只栅格化一次并复用（或 1/4 线性降采样）。
- `SmartScreenshot.swift` 的 `undoDocuments`/`redoDocuments` 无上限，建议限制深度（如 50）。

### 6. 远程控制面的可被外部放大的增长（P1，安全相关）
- `RemoteControlServer.connections` 与每连接 `idleWatchdog` 无上限，未认证的局域网对端可以在
  180s 配对超时内随意开连接。建议 `accept` 时限制并发数（如 8）。
- `RemoteConnection.pendingFrames` 无数量/字节上限，慢操作（锁屏/解锁）期间可被塞入任意多请求。建议限流并在超限时关闭连接。

### 7. 提权 helper 生命周期（P1）
`PowerHelperConnection` 注册的 root LaunchDaemon 的 plist 带 `RunAtLoad` + `KeepAlive`，
但没有任何 `unregister()`；用户关闭「合盖继续运行」后守护进程仍每次开机以 root 运行。
建议在最后一次释放与 `shutdown()` 时注销。

### 8. 其它已确认但影响较小
- `SmartScreenshot` 的 `deinit` 只禁用 tap，不摘 run-loop source / 不关面板；`ScreenCaptureModel.applyLoadedSettings`
  有直接把 `smartCapture = nil` 而不 `stop()` 的分支。
- `WindowSwitcherModel.thumbnailCache` / `cachedWindows` 保留全分辨率缩略图与 `AXUIElement`，
  仅在 runtime 停止时清空；可考虑对非选中项惰性解析 AX。
- `InputSourceModel.init` 在功能默认关闭时仍枚举 Carbon 输入源列表。
- `macOS` 屏幕锁/解锁的分布式通知（BLE 观察者）在 BLE 关闭时不再安装，因此 `ScreenLockHistory`
  只在功能开启时累积——这是预期行为，已在文档中确认。

---

## 五、复核用的检查清单

新增功能时请对照：

1. **开关**：`Settings` 结构体里有 `isEnabled` 吗？`decodeIfPresent(...) ?? 默认值` 的默认值是显式的吗？
2. **启动路径**：`init` / `activateFromConfiguration()` 在开关关闭时会创建定时器、观察者、事件 tap、
   `CBCentralManager`/`SCStream`/`FSEvents`、枚举设备或遍历磁盘吗？
3. **关闭路径**：`setEnabled(false)` 是否移除了**全部**资源（观察者 token、tap 的 `CFMachPortInvalidate`、
   Timer `invalidate`、Task `cancel`、lazy 单例置 nil）？
4. **退出路径**：是否挂进了 `MacPilotModel.shutdown()`？teardown 必须是**同步**的。
5. **观察者**：块式 API 的返回值存起来了吗？共享状态（如 `MacScreenControlService.screensaverActive`）
   是否由真正共享的持有者安装，而不是借用某个功能的开关？
6. **缓存**：`static var`、字典缓存、历史数组是否有上限/淘汰？是否会在退出时清理？
7. **跨线程回调**：`queue: .main` + `MainActor.assumeIsolated` 是既定写法；
   不要在 `Task { }` 里做终止清理。

---

## 六、验证方式

```sh
swift build
swift test --skip shortcutConfigEncodesAndDecodesCarbonModifiers
```

> ⚠️ **已知既有缺陷（与本次改动无关）**：
> `swift test` 全量运行会在 `QuickAccessTests.shortcutConfigEncodesAndDecodesCarbonModifiers`
> 崩溃（SIGSEGV，`ShortcutConfig.currentLayoutPrintableKeyDisplayString` → CarbonCore）。
> 已从诊断报告确认该崩溃在本轮编辑开始**之前**（21:22:37）就已存在，单独运行该用例同样崩溃，
> 其余 558 个测试 / 48 个套件全部通过。建议后续把该用例改为不依赖当前键盘布局
> （注入 `TISGetInputSourceProperty` 结果，或跳过无键盘布局的 CI 环境）。
