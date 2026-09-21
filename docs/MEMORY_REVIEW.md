# MacPilot 内存与功能开关代码评审

评审目标：**降低内存占用、消除内存泄漏、所有功能都要有开关，且开关关闭时不得占用内存与性能。**

本文件是**第二轮评审**，覆盖 `c2639ad`（含闭盖休眠提权 helper、iPhone 亮度/音量控制、iOS 唤醒按钮）。
第一轮的结论在 §二 被逐条复核，**其中 4 条被推翻或夸大**，已就地更正。

**第三轮（内存方案落地）见 §七**：空闲常驻 −10.2 MB、滚动截图峰值按字节收口、更新链路四处修复，并记录了**三处评估后不做**的项与一份**没能验证**的清单。

关联提交：第一轮 `67f95eb`，第二轮见文末 §六。

---

## 一、第二轮结论

| 维度 | 结论 |
| --- | --- |
| 新增攻击面 | 提权守护进程**参数固定、无命令执行面、有签名校验**（team + bundle id 白名单），未发现提权漏洞 |
| 真实泄漏 | 新增 4 处：Finder 扩展图标缓存、iPhone 端 `NWBrowser` 从不取消、合盖会话的 XPC 连接常驻、更新暂存目录 |
| 自引入缺陷 | 第一轮的修复引入 **3 个新缺陷**（退出时重新安装观察者、平滑滚动相位机被重置、图标缓存成本算错），本轮已修 |
| 未生效的"已修复" | 2 处：`RightClickMenuCoordinator.stop()` 无人调用、`IconCache` 的 8MB 上限实际不可达 |
| 功能开关 | 本轮补齐 **Awake**（此前完全缺失，且 `init` 里无条件装 9 个系统观察者）与 **自动检查更新** |
| 验证 | `swift build` 通过；`swift test --skip shortcutConfigEncodesAndDecodesCarbonModifiers` → **571 测试 / 49 套件全部通过** |

---

## 二、第一轮报告的更正（重要）

| 第一轮结论 | 实际情况 |
| --- | --- |
| §一「发现 4 处确定性泄漏，**已全部修复**」 | **夸大**。`SmartScreenshot.deinit` 仍只 `tapEnable(false)`，第三处 CGEvent tap teardown 未修 → 本轮修复 |
| §C1/C2「已改为**单一同步** shutdown」 | **不成立**。`ScreenRecordingModel.shutdown()` 内部是 `Task { await session.cancel() }`，录制中退出时 writer 不会 cancel、`.recpart` 残留 → 本轮补 `cancelImmediately()` |
| §A6 / §C2「右键协调器已加 `stop()` 并纳入退出清理」 | **不成立**。`stop()` 定义了但**零调用点**，`MacPilotModel.shutdown()` 里没有它 → 本轮接入，并补上 bootstrap / 重试任务的取消 |
| §B5「NSCache + 8MB 按像素计费」 | **不成立**。成本用的是刚被设成 32×32 的**逻辑尺寸**，每个图标恒定 4096B，8MB 上限永远不可达；全分辨率表示实际免费 → 本轮改为按位图表示计费 |
| §四-2「扩展心跳可在收到 `.quit` 后停止」 | **半对**。`Messager.sendQuitNotification()` 全仓零调用，扩展的 `.quit` 处理器只打日志，10 秒心跳实际永不停止 → 本轮修复 |
| §四-7 提权 helper 生命周期 | **准确但低估**。除"每次开机以 root 运行"外，还有 (a) helper 消失时 `disablesleep=1` 可能永久卡住、(b) 自更新后守护进程不会重建、(c) 撤销注册会强制重新授权，因此**不应**在每次退出时 unregister |
| §二-D6「会话不增长」 | **只有一半**。已结束会话限 20 条，**活跃会话无上限**——菜单点 100 次就是 100 个活跃会话 → 本轮加活跃上限 |
| §二-B5「`IconCache` 已修」 | 同功能下还有两处无上限缓存：扩展自身的 `iconCache`（本轮已修）与 `FileTypeIconProvider.cache`（**按扩展名为键，实际有界，审计结论过重，维持现状**） |

---

## 三、本轮修复

### A. 第一轮修复引入的缺陷

| 位置 | 问题 | 修复 |
| --- | --- | --- |
| `MacPilotApp.swift` `refreshScreenStateObservation()` | `shutdown()` 里 `ble.shutdown()` 先移除屏保观察者，其后的 `remoteControl.stop()` 回调 `onRunningStateChanged` 又把它们**重新装上**（谓词仍为 true） | 加 `guard !hasShutdown` |
| `SmoothScrollController.activate()` | 无条件 `runtime.stop()` 会 `phaseMachine.reset()`；`activate()` 在每次设置变更时都被调用，若此时正在滑行，目标 App 收不到配对的结束相位 | 仅在 `!activeSettings.isEnabled` 时 stop |
| `IconCache.cost(of:)` | 按逻辑尺寸计费 → 上限不可达 | 改为累加 `image.representations` 的像素 ×4 |
| `IconCache.cacheSize` | 返回 `countLimit` 常量，语义是假的 | 删除（全仓无调用方） |
| `SmartScreenshot.deinit` | 仍只禁用 tap，窗口服务器注册与 run-loop source 泄漏 | deinit 内补 `CFMachPortInvalidate` + `CFRunLoopSourceInvalidate` |

### B. 未完成的第一轮修复

| 位置 | 问题 | 修复 |
| --- | --- | --- |
| `ScreenRecordingModel.shutdown()` | 用 `Task` 取消录制 → 退出时丢失 | 新增 `ScreenRecordingEngine.cancelImmediately()`（同步 cancel writer + 删 `.recpart`），shutdown 直接调用 |
| `RightClickMenuCoordinator` | `stop()` 零调用；bootstrap / 重试任务不可取消，`stop()` 后仍会自启 | `stop()` 接入 `MacPilotModel.shutdown()`；保存并取消 bootstrap 与重试任务；`start()` 加 `isStopped` 守卫；`stop()` 里补 `sendQuitNotification()` |
| `AwakeSessionManager` | 活跃会话无上限 | `pruneExcessActiveSessions(keeping:)`，活跃上限 8 |
| `PowerHelperConnection.invalidate()` | 死代码，功能关闭后 XPC 连接常驻 | 提升为 `PowerHelperServicing` 要求（带默认实现），释放成功后调用 |
| `AwakeAssertionController` 释放失败 | 保留旧 ID 并上报失败——**复核后认为行为正确**（断言确实仍被持有，`isSystemAssertionActive` 报告为 true 是诚实的），不做改动 | 保持，并在此记录 |

### C. 守护进程 / 提权路径

| 位置 | 问题 | 修复 |
| --- | --- | --- |
| `SleepDisabledManager.runPMSet` | `standardError = Pipe()` 从不读；XPC 全在一条串行队列上，子进程写满 stderr 会**永久卡死守护进程** | 改为 `FileHandle.nullDevice` |
| `ClosedLidSleepController` | 释放失败时同时清掉 `ownsSleepDisabled`/`isActive`，导致 `shutdown()` **跳过**同步释放，系统 `disablesleep` 可能一直为 1 | 新增单调标志 `mayOwnSleepDisabled`：启用成功置位，仅在**确认释放**后清零；`shutdown()` 以它作为释放条件 |

### D. 开关补齐

| 功能 | 之前 | 现在 |
| --- | --- | --- |
| **Awake / 合盖休眠** | **完全没有开关**；`AwakeSessionManager.init` 与 `AwakeTriggerEngine.init` 无条件安装 9 个系统观察者并采样电源状态 | `AwakeSettings.isEnabled`（`decodeIfPresent ?? true` 保证老配置不失效）；观察者改由 `applyLoadedSettings` / `setEnabled(_:)` 安装；关闭时结束全部会话、移除观察者、停合盖监控、交还 `disablesleep`；触发器引擎通过 `setFeatureEnabled(_:)` 同步；设置页顶部新增总开关（`awakeEnabled` / `awakeEnabledHint` / `awakeDisabledHint`） |
| **自动检查更新** | 每次启动无条件发 GitHub 请求（2 秒后），无任何设置 | `StoredConfiguration.automaticUpdateChecks`（默认 true，`version` 22→23）；启动任务加守卫；设置页新增开关 |

### E. 有界化

| 位置 | 之前 | 现在 |
| --- | --- | --- |
| `RemoteControlServer.accept` | 连接数无上限，局域网可无限开连接 | 上限 8；超限直接 `cancel()` / 关 L2CAP 流 |
| `RemoteConnection.enqueue` | `pendingFrames` 无上限（单帧可达 256KB） | 32 帧 / 1MB 上限，超限关闭该会话 |
| `MacPilotFinderSyncExt.iconCache` | 永不淘汰的字典，按路径累积全分辨率图标 | 统一走 `storeIcon(_:for:)`，256 条后清空 |
| `AppIconCache`（`MacPilotApp.swift`） | `NSCache` 但没有任何 limit | 256 条 / 8MB |
| Finder 扩展心跳 | `asyncAfter` 自递归，永不停止 | 可取消 `Task`，收到 `.quit` 即停；主程序退出时发送该通知 |

---

## 四、仍未解决（按优先级）

| # | 项目 | 说明与建议 |
| --- | --- | --- |
| 1 | **提权守护进程从不注销** | plist 为 `RunAtLoad`+`KeepAlive`，用户启用过一次后 root 进程每次开机启动。**不能**在每次退出时 unregister（会导致每次启动重新授权）；正确触发点是"用户关闭合盖休眠且无任何会话需要它"、App 被删除、以及**版本更新后**（Apple 明确要求改过可执行文件后要 unregister→register）。需要 `PowerHelperServicing.unregister()` 与按构建号触发一次的迁移逻辑 |
| 2 | **`disablesleep` 可能永久卡住** | helper 在持有设置时消失（用户撤销批准、App 被删、更新后守护进程启动失败），`SleepDisabledManager.disable()` 因"非本 App 所有"拒绝释放，且所有权只存在可丢失的状态文件里。建议加独立的对账路径：启动时若 `pmset -g` 显示 `SleepDisabled 1` 而自身无注册，向用户提供「恢复睡眠」动作 |
| 3 | **审批状态只读一次** | `ClosedLidSleepController.isServiceReady` 零调用；用户在系统设置里批准后 App 不会察觉，横幅一直停在"需要批准"。建议在页面出现 / `didBecomeActive` / 打开系统设置后重新读 `service.status` |
| 4 | **XPC 无超时** | 守护进程活着但卡住时 `perform` 的 continuation 永不恢复，心跳循环停摆，90 秒后守护进程看门狗释放断言而 App 仍以为已启用。建议给每次 `perform` 加超时。另：客户端也应校验服务端身份（`setCodeSigningRequirement`），并在拒绝连接时 `invalidate()` + 限流日志 |
| 5 | **右键菜单仍无可用总开关** | 设置页那个开关只打开系统设置面板。`RightClickMenuCoordinator` 仍然无条件注册观察者、开 SwiftData 容器、预加载图标、跑心跳与重试。**注意**：开关要落到 `AppState`（SwiftData 模型）上，涉及 schema 迁移且与 Finder 扩展共享存储，需要单独评估后再做 |
| 6 | **iOS 端无停止开关** | `RemoteDiscoveryService.stop()` 仍零调用；`.background` 停掉了 supervisor / BLE / 连接但没停 `NWBrowser`；`.failed`/`.cancelled` 后 `browser` 非 nil 导致**再也无法重启**；`cancelPairing()` 没有 `stopConnectSupervisor()`，会重新拨号。iOS 目标不由 SwiftPM 构建，改动无法在本机编译验证，建议在 Xcode 工程里单独处理 |
| 7 | **更新暂存目录泄漏** | `launchInstaller` 抛错时 `MacPilotUpdate-<uuid>/`（数十~数百 MB）不会被删除；`ditto`/`pluginkit` 的输出管道在 `waitUntilExit()` 之后才读，超 64KB 会死锁；归档被复制成两份；SHA-256 用整包 `Data(contentsOf:)` |
| 8 | **滚动截图内存峰值** | 最多累积 30 张全分辨率 CGImage（约 720MB 峰值），`stitch` 在 `@MainActor` 执行；`bestOverlap` 每对帧建两份全分辨率栅格。建议按总像素预算限制 + 降采样 + 把 stitch 移出主线程 |
| 9 | **L2CAP 写队列无上限** | `L2CAPStreamTransport.pending` 无字节上限，且 `send()` 入队即回调成功，调用方无法感知积压；实际由 90 秒空闲看门狗兜底（BLE 速率下约数 MB） |
| 10 | **Awake 子系统缺 `deinit`** | `AwakeSessionManager` / `AwakeTriggerEngine` / `LidStateMonitor` / `ClosedLidSleepController` 都没有 `deinit`；IOKit 回调用 `passUnretained(self)`，对象若未 `stop()` 就释放会 use-after-free。生产中由 app 生命周期模型持有并在 `shutdown()` 停止，属潜在风险 |
| 11 | **`MenuBarView` 的默认参数陷阱** | `AwakeSessionManager = AwakeSessionManager()` 作为默认参数会静默构造第二个管理器（多装 5 个观察者且无 teardown）。当前唯一生产调用点显式传参，建议删掉默认值 |
| 12 | **低级项** | `getSleepDisabled` 整条特权 IPC 面无人使用；`PowerStateProvider.startMonitoring` 丢弃 token 导致无法移除；`MacPilotModel.shutdown()` 无法取消启动时那个未保存的 `Task`；`ScreenshotExtras` 全分辨率缓冲；`undoDocuments`/`redoDocuments` 无上限；`BookmarkManager` 安全作用域书签 start/stop 不平衡 |

---

## 五、开关矩阵（第二轮结束后）

| 功能 | 总开关 | 关闭时的行为 |
| --- | --- | --- |
| 退出规则 / 启动规则 | `isEnforcing`、`isLaunchSchedulingEnabled` + 每条规则 | 取消全部任务 ✅ |
| **Awake 防休眠** | **`AwakeSettings.isEnabled`（本轮新增）** | 不装观察者、不采样电源、结束会话、交还 `disablesleep` ✅ |
| BLE 解锁 | `BLEUnlockSettings.isEnabled` | 不装观察者、释放 `CBCentralManager` ✅ |
| iPhone 遥控 | `RemoteControlSettings.isEnabled` | 不监听、释放 BLE central、上限 8 连接 ✅ |
| 输入法切换 | `InputSourceSettings.isEnabled` | 不装观察者/tap、不轮询 ✅ |
| 存储压缩 | `automaticallyCompress` + 文件夹非空 | 不启 FSEvents ✅ |
| 截图 | `screenshotEnabled` / `isEnabled` | 不做磁盘扫描、不注册热键 ✅ |
| 屏幕录制 | `ScreenRecordingSettings.isEnabled` | 不注册热键、不枚举设备 ✅ |
| 画中画 | `PictureInPictureSettings.isEnabled` | 不装 tap/观察者 ✅ |
| 窗口切换 | `WindowSwitcherSettings.isEnabled`（**默认开**，策略待定） | 停 runtime、移除 tap/AX ✅ |
| 平滑滚动 | `SmoothScrollSettings.isEnabled` / `reverseScrollingEnabled` | 不建 tap；空闲不跑 display link ✅ |
| 剪贴板 | `ClipboardSettings.isEnabled` | 停监听与热键（历史仍常驻，见遗留） |
| **自动检查更新** | **`automaticUpdateChecks`（本轮新增）** | 启动零网络请求 ✅ |
| 右键菜单 | **仍无（见遗留 5）** ⚠️ | 启动即建协调器 |
| 内存监控 | 仅页面级 | 离开页面停止采样 ✅ |

---

## 六、验证

```sh
swift build
swift build --target MacPilotFinderSync
swift test --skip shortcutConfigEncodesAndDecodesCarbonModifiers
```

结果：构建零 error / 零 warning（含 FinderSync 扩展目标）；**571 个测试 / 49 个套件全部通过**。

> ⚠️ **已知既有缺陷（与本次改动无关）**：全量 `swift test` 会在
> `QuickAccessTests.shortcutConfigEncodesAndDecodesCarbonModifiers` 崩溃（SIGSEGV，
> `ShortcutConfig.currentLayoutPrintableKeyDisplayString` → CarbonCore）。
> 已由诊断报告确认该崩溃在本轮编辑之前（21:22:37，另一处会话触发）即存在，
> 单独运行该用例同样崩溃。

---

## 七、第三轮：空闲常驻与瞬时峰值分开收口

方案来源是一份十节的重构计划（`§10` 的顺序：先量、再主窗口、再切换器、再 Helper、再生命周期、再峰值）。这一轮按那个顺序做到第 7 步，**三处经评估后不做**，**三条交互验收没跑成**。细节叙述在 `SUMMARY.md` 第六十三节，这里只记评审结论。

### 尺子

`Scripts/measure-memory.sh`：按当前 UID + 可执行文件路径识别四类角色（main / finder-sync / power-helper / dock-helper），`footprint` 取 `phys_footprint` 与 peak，5 次采样取中位数，`--deep` 加 malloc 分区，`--diff` 出按角色的 delta，`--only <路径片段>` 用于并排跑两个 bundle。快照写在 gitignore 的 `build/memory/`（含 pid 与本机路径，不进仓库）。

两条口径纠正：

- **RSS 与 footprint 不是一回事**，实测同一进程 87 MB / 130 MB。以前按 RSS 得出的结论要重新看。
- **闲置 30 秒不够**：同一进程 30 秒时 101 → 103 MB，六分钟后 87 MB。分配器还页有延迟，短窗口只能看「有没有涨」，不能看「降了多少」。

### 本轮修复

| 位置 | 之前 | 现在 |
| --- | --- | --- |
| `MacPilotApp.swift` `Window` scene | 启动即建整棵 `ContentView`，`orderOut` 只是隐藏，视图图常驻 | `MainWindowContentState` 门控：登录启动不加载，`willClose` 延后一拍释放（代号防重开竞态），`lastMainSection` 记住页面 |
| `WindowSwitcher.startRuntime` | `panelController?.prepare()` 功能一加载就建面板且**从不释放** | 删除；首次 `show()` 才建；关闭 15 秒交还缩略图、60 秒交还面板；`MemoryPressure` 告警时两档一起（正在显示不动） |
| `DockHelperPanelController.warmLifetime` | 300 秒，且待命时面板/图标全留着 | 45 秒（常量移入 `MacPilotDockGroupsCore.DockHelperWarmLifetimePolicy`，可测）；`dismiss()` 释放面板 + `model.releaseContent()`；待命期间内存告警直接退出 |
| `UpdatePackageValidator.sha256(of:)` | `Data(contentsOf: .mappedIfSafe)` 整包 | `FileHandle` 1 MB 分块（与 `FileCompression.swift:977` 已有写法一致） |
| `UpdatePackageValidator.run` | `waitUntilExit()` 在读管道**之前**，>64 KB 输出会死锁 | 先 `readDataToEndOfFile()` 再 wait |
| `launchInstaller` | `process.run()` 抛错时两个暂存目录（含上百 MB 解包 app）不删 | catch 内删除后再抛 |
| `UpdatePackageValidator.prepare` | 先把 zip 复制进暂存目录再 `ditto -x -k`：归档在磁盘上同时存在两份，且源文件就躺在要写入的目录里 | 直接解下载好的那份，删掉复制 |
| `SmartScrollingCaptureWindowController` | `frames.count < 30`，全屏 Retina 一帧 ~24 MB → 峰值 ~700 MB | `SmartScrollingCaptureBudget`：256 MB 字节预算 **且** 30 帧；触顶时 HUD 换橙色提示（替换而非追加，面板定高） |
| `ScreenCaptureVerticalStitcher.raster` | 每对帧两份全分辨率 RGBA 栅格 | 横向缩到 256 列、纵向保持精确：28.8 MB → 2.5 MB / 对 |
| `SmartScrollingCaptureWindowController.finish` | `@MainActor` 上拼接几十帧 → HUD 与全 App 卡死 | `Task.detached` + `autoreleasepool`，`isStitching` 防连点 |
| 进程级内存压力 | 无 | `Sources/MacPilot/MemoryPressure.swift`：一个 `DispatchSource` 供多方订阅，最后一个订阅者走时销毁 |

### 量到的结果

同机、同默认配置、两个 bundle 副本并排闲置两分钟取中位数：main **97.5 → 87.3 MB（−10.2 MB）**，peak 147.4 → 149.4 MB（噪声内）。`--deep` 的 malloc 分区指向同一处：基线 116.2 M allocated / 65.0 M free，本轮 120.6 M / 29.0 M free——**真正被占住的堆少了约 36 MB**，而总分配量没涨。

### 评估后不做（三处）

1. **缩略图缓存 `totalCostLimit = 6 MB`**：预览最宽 256×160 px，30 张顶天 ≈ 4.8 MB，字节上限不可达。条数上限已经锁住字节，再加一套按像素计费就是 §二 里 `IconCache.cost(of:)` 那种「永远碰不到的上限」。已在 `WindowSwitcherThumbnailCachePolicy.maximumCount` 上写明。
2. **CPU/内存菜单快照的 TTL 自清理**：`static let menuSampler` + `cachedMenuSample` 存的是每 App 一行的结构体与 pid→计数器字典，量级几十 KB，且采样只在菜单展开时同步发生（没有定时器）。为它加一个 5 秒清理任务是净负担。
3. **`FeatureRuntime` 协议（方案第 5 阶段）**：九个子系统里真正持有「可交还且能重建」状态的只有切换器与截图链路，已经各自接上 `MemoryPressure`；其余多数是常驻观察者与热键，deactivate 与 stop 语义重复。协议会先带来九个空实现。

### 仍未解决（在 §四 基础上追加）

| # | 项目 | 说明 |
| --- | --- | --- |
| 13 | **窗口真正关闭后，`.macPilotShowMainWindow` 没有活着的观察者** | 观察者挂在窗口内容上（本轮从 `ContentView` 上移到 `MainWindowRoot`，覆盖范围是旧的**超集**：隐藏但存在的窗口现在也能响应）。深链 / `applicationShouldHandleReopen` 在窗口已关闭时不生效，**改前改后一样**。要根治只能自建 `NSWindow`（见下条） |
| 14 | **方案的「移除 `Window` scene + `MainWindowCoordinator`」没有执行** | 内容门控已拿到本轮最大单笔收益；换 scene 会一起动掉自动生成的窗口菜单（Cmd-W/Cmd-M）、`.windowToolbarStyle(.unified(showsTitle: false))`、状态恢复，而这一轮**在这台机器上无法验证**（见下条）。留作下一轮，且需要先在能看能点的机器上做 20 次开关的回归 |
| 15 | **三条交互验收未跑** | 20 次开关窗口、切换器首屏延迟、分组浮层开合。原因：`LSUIElement` 进程 System Events 报 `count of windows = 0`（隐藏/关闭不可区分）、`set frontmost` 不生效、`key code` 会落到当时真正的前台 App、`screencapture` 返回全黑。**副作用**：确认该路径不可靠之前发过两次 Cmd-W，可能关掉了用户前台 Chrome 的标签页 |
| 16 | 切换器 `cachedWindows` 仍长期持有 `WindowSwitcherItem`（含 `AXUIElement` 与每 App 一份 `NSImage`） | 有界（按窗口/App 数），且清掉会直接违反「首屏 ≤ 现在 +50 ms」，只在内存告警时随缩略图一起交还 |

### 验证

```sh
swift build            # 零 error / 零 warning
swift test             # 823 条，3 条负载抖动，单独跑全绿
./Scripts/build-app.sh # 签名与 designated requirement 校验通过
```

新增 `Tests/MacPilotTests/MemoryLifecycleTests.swift` 15 条：主窗口内容状态机 5（含延后一拍的重开竞态）、切换器回收 3、字节预算 2、宽帧拼接 2、Helper 待命时长 1、内存压力登记 2。
