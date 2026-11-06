# MacPilot 历史回归目录册（REGRESSION_CATALOG.md）

本册只记录**有提交证据的历史问题**，每个问题给出：首次出现、复发时间、根因、为什么当时的修复不彻底、最终原则、禁止再用的实现、自动化测试与人工验收。它是 `REGRESSION_INDEX.json` 的人类可读版本，两者由 `Scripts/regression-plan.py --validate` 保持一致（索引引用的每个测试套件必须真实存在）。

状态分三级：

- **已确认复发**（confirmed-recurring）：同一根因有 ≥2 个修复提交，实际发生过二次以上的事故。
- **已确认隐患**（confirmed-potential）：根因确认存在、修复方向明确，但尚未二次触发。
- **未证实**（unverified）：只有线索，无提交证据；不作为门禁依据，只做记录。

不要把 SUMMARY.md 复制进本册；SUMMARY.md 保留完整叙事历史。

后续新增问题简短记入 [BUG_FIX_LOG.md](BUG_FIX_LOG.md)，以下历史证据链不重复抄写。

---

## A. 主窗口 / 菜单栏（module: window-lifecycle / menu-bar-lifecycle）

### A1. 菜单/Dock 打不开主窗口 — 已确认复发（5 修 + 1 Revert，最顽固的 UI 家族之一）

- 首次：2026-09-28 `5ecdb66`（Window 菜单抬窗内容空白）。
- 复发：2026-10-29 `8d8daa6` → 同日 Revert `9d71f61` → `42453ac` 重做；2026-10-30 `d080766`（pendingRequest 死路）；2026-10-31 `dc224ff` 才找到真正根因（见 A2）。
- 根因：`MainWindowOpener` 的生命周期与场景窗口解耦失败；以及 `guard let showWindow else { pendingRequest = true }` 这种没有 drain 路径的标志位死路。
- 为什么不彻底：`d080766` 修的是 opener 侧的现象，而真正根因在菜单侧（`menuDidClose` 同步释放 session 清零弱引用 target）——修错模块，症状暂时缓解后必然复发。
- 最终原则：窗口内容立即加载、下一 turn 抬窗；激活被拒仍 `orderFrontRegardless`；无可用窗口必须走 `openWindow(id: "main")`，禁止无人 drain 的 pending 标志；结果全部写 `DiagnosticLog`。
- 禁止：`makeKeyAndOrderFront` + `orderFrontRegardless` 换成 `NSRunningApplication.activate`；从菜单 action 同步抬窗。
- 测试：`MainWindowOpenerTests`、`MainWindowContentStateTests`。
- 人工：关窗后从菜单/Dock/Finder 深链重开多次；激活被拒时窗口仍可见。

### A2. menuDidClose 同步释放 session → 所有菜单动作静默失效 — 已确认复发（修复A引发B）

- 引入：2026-10-30 `591ecd0`（改真 NSMenu 时在 `menuDidClose` 里 drop session）。
- 爆发与修复：2026-10-31 `dc224ff`。macOS 27 在 `menuDidClose` **之后**（同一 run-loop turn）才派发所选 item 的 action，`NSMenuItem` 持弱引用 target——同步释放清零全部 `ActionRelay`，点「设置/退出」都无声失效，而弹窗照常关闭。
- 为什么不彻底：`d080766`（前一天）把这当成 opener 问题修，提交正文明确承认误判。
- 最终原则：controller 在 `menuDidClose` 停止持有 session，捕获引用延后一个 main-queue turn 释放。
- 测试：`MenuBarOwnedMenuTests.relayTargetsSurviveThePostCloseActionDispatchAndDropOneTurnLater`。
- 人工：真实 AppKit 菜单逐项点一遍（模拟测试无法完全替代系统分发链路）。

### A3. 状态栏右键菜单偏上（手算 popUp 锚点）— 已确认复发（3 修 + 文档固化）

- 引入：2026-10-28 `6f6c9e5`（snapshot 菜单 + `popUp`）。
- 复发：2026-10-29 `ced94af` 调锚点仍差 6pt；2026-10-30 `591ecd0` 根治。
- 根因：`NSMenu.popUp(positioning:at:in:)` 的锚点相对 *button* 而非菜单栏，任何手算点都偏高（macOS 27 实测：`bounds.minY` 高 24pt，`bounds.maxY` 仍高 6pt；AppKit 自挂菜单顶边在菜单栏底边下方 1pt）。
- 为什么不彻底：`ced94af` 是在错误坐标系里继续微调数值——错误的抽象不可能调对。
- 最终原则：status item 挂真实 `NSMenu`、`menuNeedsUpdate(_:)` 填充，AppKit 负责定位。
- 禁止：任何 `popUp` 调用、锚点辅助函数、`performClick` 点击动作。
- 测试：`MenuBarOwnedMenuTests`。
- 人工：最新系统上菜单顶边与系统状态菜单平齐。

### A4. 菜单栏图标消失（reattachment 出口不全）— 已确认复发（同日两修）

- 2026-10-26 `838e7a8` → 同日 `fd5d355`（补上「取消睡眠」出口：`reinserting` 置位后无 task 无 item，图标消失直到重启）。引入点是 v1.2.2-beta.59 的 native-menu 改造。
- 最终原则：`scheduleReinsert` 的每个出口都必须恢复 item；`selfHeal()` 兜底；`orderOut`（登录启动路径）不得当关闭信号。
- 测试：`MenuBarDisplayControllerTests`、`MenuBarStatusItemVisibilityTests`、`AppPresenceTests`。

### A5. 菜单命令树随模型 tick 重建（文本 badge → 909ms）— 已确认复发（同族 5 修）

- 2026-10-26 `dba5c85`（SwiftUI hosting 子菜单被数据刷新打断 native tracking）→ 2026-10-28 `6f6c9e5`（文本 badge 每 tick 重建整棵命令树：空 60ms / 30 行 909ms / 90 行 1704ms）→ 同日 `7de504f`、`61381d4`、`f745b3f` 防复发簇。
- 最终原则：status item 只允许图标；弹出内容固定为打开瞬间的 `MenuBarMenuSession` 快照。
- 测试：`MonitorMenu*`、`MenuBarMenuSessionTests`。

## B. BLE（module: ble-presence）

### B1. 解锁状态机未在系统事件后重新武装 — 已确认复发（10+ 修，全仓最大热点）

- 2026-08-04 `b0b73dc`（system wake）→ 2026-08-21 `a60d7c7`（display wake）→ 2026-09-16 `d267712`（stalled monitoring）→ 2026-09-17 `295c621`（display wake 后 retry 掉臂）→ 2026-09-30 `121be7a` → 2026-10-09 `cebe1b6` → 2026-10-12 `47a1467`/`98553a0` → 2026-10-15 `6c69d24`/`43a646d`/`5a4aab0`。
- 根因家族：每次只修「当前这条事件路径没有重新武装」，从不回答「这个状态还能被什么事件触发」。
- 最终原则：任何取消/完成路径都必须证明存在重新武装的来源；瞬态条件（无 manager、未上电、空订阅）不得当作终止条件。
- 测试：`BLEWakeRecoveryTests`、`BLEMonitoringRestorationTests`、`BLERediscoveryTests`、`BLEManualLockSuppressionTests` 等全族。
- 人工：真实睡眠/唤醒、合盖、走回范围、手动锁屏（须授权）。

### B2. 地址轮换误判离开 / 历史地址泄漏定时器 — 已确认复发（连续 4 修）

- 2026-10-20 `f85d169` → 2026-10-21 `8fa6374`/`c45bb5c` → 2026-10-26 `0948e7b`。
- 测试：`BLEIdentity*`、`BLERediscoveryTests`。

### B3. 后台会话静默挂起误判为设备离开 — 已确认复发（4 修）

- 2026-09-26 `adba110` → 2026-10-25 `db243ce` → 2026-10-26 `3742e53`/`b011e5e`。
- 测试：`BLEBackgroundSessionTests`、`BLEAdvertisementLivenessTests`。

### B4. 反向 presence 挑战任务被取消后永久失联 — 已确认复发（4 修，含藏在 docs 提交里的代码修复）

- 2026-10-23 `b0e1454` / `270d991` / `fbcff94` → 2026-10-29 `5f95fb3`。
- 根因样本：`issuePresenceChallengesIfNeeded` 把瞬态当终止条件 cancel 任务，而重新武装只依赖一个不会再来的 subscribe 回调；恢复路径用 `Task.sleep` + app timer，后台被 iOS 挂起永不执行。
- 最终原则：cadence 生命周期只属于 `startProduction`/`stopProduction`；反向链路转换必须写 `DiagnosticLog`（ring buffer 安装版看不到，导致此前无法诊断）；首个样本的 unlock retry 必须保留。
- 测试：`BLEReversePresenceTests`、`ProximityGATTProductionRestartTests` + 远端协议包套件。

## C. 显示控制（module: display-recovery）

### C1. 显示恢复不持久 — 已确认复发（5 天 8 修）

- 2026-10-26 `7a225d3`/`8b2cbd2` → 2026-10-29 `af8f9a6`/`90c5222`/`414c759`/`bc0d4ef`/`2be9bc4` → 2026-10-30 `133e466`。
- 根因：恢复操作是内存态一次性调用，无 journal、无 durable 请求，崩溃/重启/拓扑变化即丢。
- 为什么不彻底：每修补一条丢失路径（lease、stale service、retry、session、async、跨重启、identity），直到 `bc0d4ef` 才引入 journal-before-hardware。
- 最终原则：恢复意图先落 journal 再动硬件；helper 重启后仍能识别未完成操作；恢复失败不得上报成功；不得关掉最后一块可用显示器。
- 测试：`DisplayRecovery*`、`DisplayBlankRecoveryTests`、`DisplayPowerTests`、`KeyboardBacklightTests`、`ScreenControlSafetyTests`。
- 人工：实机 DDC、热插拔、长时间黑屏（见 acceptance/hardware-acceptance.md）。

### C2. 合盖电源服务注册状态过期 — 已确认复发（4 修）

- 2026-09-16 `b903366` → 2026-09-25 `edaff85` → 2026-10-07 `ba3a62f`/`9503072`。
- 最终原则：注册状态 re-read 系统，不缓存。
- 测试：`ClosedLid`、`SleepDisabledPlannerTests`、`PowerHelper*`。人工：docs/AWAKE_MANUAL_TESTS.md。

## D. 辅助进程与系统扩展（module: helper-lifecycle）

### D1. FinderSync 注册跨更新丢失 — 已确认复发（9 修，第二大热点）

- 2026-09-03 `d5bb97f` → 09-07 `fc5afe5` → 09-08 `0576285` → 09-30 `d3d227a` → 10-10 `3beb514`/`24b55f2` → 10-12 `0c788bc`/`fc49e0f`/`35dfe94`。
- 根因：app 记录的注册状态与 PlugInKit 真实状态脱节，且跨安装不隔离。
- 最终原则：选举变更必经 `FinderSyncRegistration` + 跨进程锁下先记 `FinderSyncRecoveryJournal`；确认必须来自新鲜 PlugInKit 查询的 `+` 且路径精确匹配；用户手动禁用的不得自动恢复。
- 测试：`FinderSyncRegistrationTests`、`FinderSyncRecoveryJournalTests`、`FinderSyncHeartbeatLifecycleTests`。
- 人工：`zsh Scripts/verify-findersync.sh` 只读核对；更新后 Finder 右键菜单验收。

### D2. 按需资源与辅助进程生命周期 — 已确认隐患（2026-10-28 用户要求固化）

- 尚无复发提交，但要求明确：关功能即停任务/定时器/监听/tap/采集/连接并释放缓存；专属 helper 随功能退出，共享 helper 按租约计数；注册状态与运行状态分离；快速开关、崩溃恢复、延迟回调不得误杀新会话。
- 测试：`FeatureResourceLifecycleTests`、`ResourceLifecycleTests`、`PowerHelper*`、`DockHelperLifecycleTests`。
- 人工：活动监视器核对进程退出与不被拉起。

### D3. Dock 分组跨进程编辑 — 已确认隐患（设计期防御）

- `DockGroupStore.update` 的独占 `flock` 是唯一写路径；40 队列并发写测试钉住。只有主 app 再生 helper bundle。
- 测试：`DockGroupsCoreTests`、`DockHelperPanelPlacementTests`。

## E. 配置兼容（module: configuration-migration）

### E1. 降级清空全部配置（v1.1.482-beta.5）— 已确认复发家族

- 2026-09-29 `555dad3` 根治：删除一个 struct 字段使旧版整文件解码失败，fallback-to-defaults 清空所有功能配置。改为逐 section 解码 + 隔离。
- 同族隐患（本次审计新发现，已修）：`QuickSearchSettings.fileScope` 等持久化枚举仍是裸 `decodeIfPresent`——未知 rawValue 抛错会清空整个 quickSearch 节（matchScope 已容错但无测试钉住）。
- 最终原则：键只增不删不改名；新字段 `decodeIfPresent`；逐 section 隔离；持久化枚举未知值落默认值。
- 测试：`ConfigurationSchemaContractTests`（键集 append-only）、`ConfigStoreTests`、本次新增的未知枚举值容错测试。

## F. 更新与发布（module: updater-release）

### F1. Designated requirement 不一致（v1.1.355 以下搁浅）— 已确认复发（同日两修）

- 2026-09-16 `7cf637c` → 同日 `c262185`（build-app.sh 把 DR 覆盖成弱化形式）。让 codesign 自推 DR 导致跨机器/跨身份字节不一致，升级判定「不是同一个 app」。
- 最终原则：DR 只在 `Scripts/signing-requirement.sh` 定义；四条签名路径同字节；三道门 + `SigningRequirementTests`；绝不弱化 requirement 换取过门。
- 人工：最终包 codesign/stapler/Gatekeeper 全套验证。

### F2. 更新源可用性（匿名 API 限额 / beta 无 latest 回退）— 已确认复发（3 轮）

- 2026-09-08 `9460230` → 09-17 `34ccc93`/`fe1ef24` → 10-31 `19b99f0`（beta 通道 403 被报成 invalid release）。
- 最终原则：403/限额 = 源不可达 ≠ 无效版本；beta 经公开 releases 页取数。
- 测试：`SoftwareUpdateTests`、`ReleaseCatalogServiceTests`、`UpdateChannelTests`。

### F3. 更新后 relaunch / 版本切换卡死 — 已确认复发（7 修）

- 2026-09-16 `95f1b1c`/`ac103ed`；09-29 版本切换器 4 连修（`822969a`/`879525e`/`c571bcb`/`40cf661`，含 `isCancelled` 极性反转、`NSApp.terminate` 被 sheet 吞掉）；10-10 `24b55f2`。
- 测试：`SoftwareUpdateInstallerTests`、`VersionSwitch*`。

## G. 快捷搜索（module: quick-search）

### G1. 按键路由被 IME / 功能处理器抢走 — 已确认复发（3 修）

- 2026-10-12 `8722d08` → 次日 `1415f7a`（IME 组装态复发）→ `1e69dcd`。
- 测试：`CarbonHotKeyRoutingTests`、`QuickSearchHiddenFieldEditorTests`。

### G2. 过期查询/过期回调污染结果 — 已确认复发（4 修）

- `ee9a2c1`（hover 跳行）、`980cdab`（排序层级）、`8f39f94`（stale 结果 + 进程身份）、`61f36c9`（空字符串 InfoPlist.strings：三局通的 `en.lproj` 把名字覆盖成空串，`??` 链停在空值留下无名行）。
- 最终原则：150ms 防抖 + generation 丢弃旧结果；empty 视为 missing 回退 bundle folder 名。
- 测试：`QuickSearchCancellationTests`、`QuickSearch*` 全族。

### G3. 多显示器下应用激活把快速搜索面板的 key 抢走 — 已确认隐患（待双屏实机验收）

- 现象：设置窗口放在一块屏，指针在另一块屏时唤起快速搜索，面板出现后闪一下即消失，无法输入。
- 根因：`a071a52` 为输入法在面板打开时临时激活本进程；`NSRunningApplication.activate` 异步完成，AppKit 在激活落地时优先把另一块屏上的普通窗口（设置页）选成 key window，非激活面板失 key，`resignKey` 的延迟关闭把面板收掉。
- 最终原则：本进程未激活时打开面板，必须在 `NSApplication.didBecomeActiveNotification` 到达后重新 `makeKeyAndOrderFront`，并保持 0.6 秒 settle：期间每次 `resignKey` 都重抢 key 且不得关闭，settle 结束仍未拿到 key 才走正常失焦关闭；关闭面板解除观察；激活超时才走兜底。
- 测试：`QuickSearchPanelActivationTests`、`QuickSearchApplicationActivationTests`、`QuickSearch`。人工：双显示器设置页一屏、另一屏呼出并输入，关闭后焦点回到原应用。

## H. 性能 / 资源（module: resource-performance）

### H1. 重复事件无界累积（BLE 扫描内存增长）— 已确认复发（同日两修）

- 2026-08-24 `5db8420`（throttle）+ `8cea76b`（去重复扫描）。另有菜单 909ms 家族（见 A5）与空闲驻留 `a9f55ee`。
- 最终原则：事件节流去重；定时器/监听随对象释放；性能测试锁数量与状态机，不锁墙钟。
- 测试：`ResourceLifecycleTests`、`BLEUnlockPerformanceTests`、`MonitorMenuSnapshotCacheTests` 等。
- 人工：`Scripts/measure-memory.sh` 对比 docs/MEMORY_REVIEW.md 阈值。

## 未证实（unverified，仅记录）

- Sidecar 能力宣告失效家族（`114b505` 等 2026-10-13 同日 5 修）：同日一次诊断拆多修，无跨时间复发，按隐患对待；`SidecarCapabilityAdvertisementTests` 钉住。
- 菜单栏 `topologyChangeWhileAMenuTracks…` 等 CI 抖动：属共享 MainActor 饥饿类（见 AGENTS.md 已知抖动清单），不是独立回归。

---

## 与测试的对应关系

每条规则在 `REGRESSION_INDEX.json` 中都有 `test_filters` / `manual_checks`；索引校验（`Scripts/regression-plan.py --validate`）保证引用的套件真实存在。修改对应模块源码时，`Scripts/regression-plan.py` 会自动要求执行这些测试；无法自动化的场景必须留在人工验收清单里，不得用 mock 通过冒充实机通过。
