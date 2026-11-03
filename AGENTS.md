# Repository Guidelines

Contributor guide for **MacPilot**, a native macOS menu-bar app (Swift 6, SwiftPM, macOS 14+) with 19 independently switchable feature modules: app inactivity rules, scheduled launch, Awake keep-awake, BLE proximity lock/unlock, iPhone remote control, capture/screenshot tooling, dock groups, local ports, quick search (app launcher + Spotlight file-name search), and more.

## 防回归强制流程（Regression Guard）— 改源码前必读

本仓库的每一条历史事故都记录在 `docs/engineering/`。**修改任何源码之前**，必须完成 `docs/engineering/AGENT_CHANGE_PROTOCOL.md` 的检查流程，概要：

1. 确认本次修改涉及的文件与模块；用 `python3 Scripts/regression-plan.py --mode local` 对照 `docs/engineering/REGRESSION_INDEX.json` 得到命中的历史规则 id。
2. 阅读对应 `docs/engineering/regressions/<module>.md` 的不变量全文，并查该文件的历史提交与 Revert 记录。
3. 阅读命中规则的回归测试，判断覆盖是否与本次触发条件同族。
4. 回答协议里的 7 个问题（根因、历史、旧修复为何不彻底、受影响功能、必跑测试、是否新增测试、是否实机验收），写进 PR 描述。
5. **不允许只因为用户报告一个现象就直接加 if**——历史上修错模块（`d080766`）与在错误坐标系里调锚点（`ced94af`）都是跳过此流程的代价。

修改后：`bash Scripts/run-regressions.sh`（强制完整安全套件用 `--force-full`）；CI 的 `Regression Gate` 用同一索引选择测试。索引引用不存在的套件、计划错误、测试失败都会使 CI 失败；失败测试只有逐条列在索引 `known_flaky_tests` 且单独重跑通过时才打印 `WAIVED` 放行，其余一律红。历史问题目录册见 `docs/engineering/REGRESSION_CATALOG.md`；模拟测试不能覆盖的真机/系统版本验收清单见 `docs/engineering/acceptance/`。

模块级不变量全文（从本文件迁出，仍然有效）：

- 主窗口/AppKit 生命周期 → `docs/engineering/regressions/window-lifecycle.md`
- 菜单栏、NSMenu、动作分发、入口存活 → `docs/engineering/regressions/menu-bar-lifecycle.md`
- BLE 身份/地址轮换/在场检测/反向 presence → `docs/engineering/regressions/ble-presence.md`
- 黑屏亮屏、显示器拓扑、DDC、恢复事务 → `docs/engineering/regressions/display-recovery.md`
- FinderSync、Power/Dock Helper、按需进程生命周期 → `docs/engineering/regressions/helper-lifecycle.md`
- 快捷搜索（NSMetadataQuery、generation、面板归属） → `docs/engineering/regressions/quick-search.md`
- 配置升级/降级兼容（append-only 键集） → `docs/engineering/regressions/configuration-migration.md`
- 软件更新、签名 DR、公证、发布 → `docs/engineering/regressions/updater-release.md`
- CPU/内存/定时器资源、剪贴板、钉图 hover → `docs/engineering/regressions/resource-performance.md`

## Project Structure & Module Organization

- `Sources/MacPilot/` — main executable target, one subdirectory per feature cluster (`Awake/`, `BLE/`, `DockGroups/`, `RemoteControl/` (remote server), `InputCore/` (remote input injection), `SnapzyCapture/`, `SmoothScrolling/`, `QuickSearch/` (non-activating panel, Carbon hot key, pinyin-ranked app index, `NSMetadataQuery` file search), …) plus `MacPilotApp.swift` (core), `BLEUnlock.swift` (proximity lock/unlock), and `SoftwareUpdate.swift` (release checks, validation, and update orchestration).
- `Packages/MacPilotRemoteProtocol/` — local SwiftPM package with the wire protocol + transport shared by macOS and iOS: framing, crypto, capability bits and the binary realtime-input codec. Both platforms compile it; wire changes must keep old peers decoding.
- `iOS/MacPilotRemote/` — **PilotNest**, the iOS companion app (`com.misswell.macpilot.remote`, iOS 17+, Xcode project generated from `project.yml`; see "iOS companion app" below).
- `website/` — Chinese product site (Vinext/React, deployed to Cloudflare); Node ≥ 22.13, its own `package.json` and lint setup.
- `Sources/MacPilotUpdater/` + `MacPilotUpdaterSupport/` — helper executable that atomically replaces the verified app bundle and relaunches it after the main process exits.
- Other packaged targets: `MacPilotDockGroupsCore` + `MacPilotDockHelper`, `MacPilotLocalPortsCore`, `MacPilotPowerIPC` + `MacPilotPowerHelper`, `MacPilotRightClickKit` + `MacPilotFinderSync`, `MacPilotOcclusionPatch` (dynamic library). See Architecture boundaries below.
- `Tests/` — Swift Testing targets: `MacPilotTests` (main suites, e.g. `LaunchRuleCodingTests.swift`, `BLEUnlockPerformanceTests.swift`, `SoftwareUpdateTests.swift`), plus `MacPilotFinderSyncTests`, `MacPilotLocalPortsCoreTests`, `MacPilotRightClickKitTests`, `MacPilotUpdaterSupportTests`. `Tests/Performance/` holds resource-acceptance benchmarks (`resource-benchmark.sh`, thresholds in its README).
- `Resources/` — `Info.plist`, `MacPilot.entitlements`, `AppIcon.icns`, icon sources.
- `Scripts/` — `build-app.sh`, `build-findersync.sh`, `distribute-app.sh`, `version.sh`, `signing-requirement.sh` / `verify-signing-requirement.sh`, `measure-memory.sh`, `capture-permission-diagnostics.sh`, `verify-awdl.sh`, plus the regression-guard pair `regression-plan.py` (diff → module → test selection; `--validate` checks the index) and `run-regressions.sh` (executes a plan, verifies tests actually ran).
- `docs/` — `UI_DESIGN.md` (normative UI tokens), `REMOTE_CONTROL.md` (iPhone→Mac design, wire protocol, security model), `AWAKE_MANUAL_TESTS.md` (manual power-state acceptance), `PERMISSION_DIAGNOSTICS.md`, `UPDATE_DOWNLOADS.md`, `MEMORY_REVIEW.md`, and `engineering/` (the regression-guard knowledge base: index, catalog, protocol, per-module invariants, acceptance checklists).
- `.github/workflows/build.yml` — CI; `regression-gate.yml` — the regression gate sharing `docs/engineering/REGRESSION_INDEX.json`.
- Runtime config lives outside the bundle at `~/Library/Application Support/MacPilot/config.json`; bundle ID `com.misswell.macpilot`. The remote channel listens on TCP 43847.

## Architecture boundaries

- `MacPilotLocalPortsCore` stays plain Foundation/Darwin on purpose — no SwiftUI or app-model dependency, so a future CLI can reuse the same identity boundary.
- `MacPilotPowerIPC` contains only types and pure logic, never privileged operations; `MacPilotPowerHelper` is the root LaunchDaemon that provides the `pmset disablesleep` capability.
- Dock Groups share one model via `MacPilotDockGroupsCore`: the main app and each group's helper both read and edit it through `DockGroupStore.update` under a cross-process `flock`; the main app alone regenerates helper bundles. Every group's helper app reuses a single binary, differentiated only by bundle ID, icon, and name — never touch third-party apps outside that shared model.
- `MacPilotFinderSync` uses the `_NSExtensionMain` entry point (built via `Scripts/build-findersync.sh`); SwiftUI is linked explicitly so SwiftUICore reaches the linker through SwiftUI's re-export instead of an autolink entry.

## Build, Test, and Development Commands

- `swift build` — compile (debug).
- `swift test` — run all tests; filter with `swift test --filter SuiteName.method`.
- `./Scripts/version.sh` — print current version (latest `v*` tag + commits since).
- `./Scripts/build-app.sh` — release build, package `MacPilot.app`, inject version into `Info.plist`, codesign (Developer ID if `MACPILOT_DEVELOPER_ID` is set, otherwise ad-hoc; the old `OCTOPILOT_DEVELOPER_ID` alias remains accepted).
- `./Scripts/distribute-app.sh` — sign with Hardened Runtime, notarize, staple, output `MacPilot-<version>-macos.zip` (needs Apple Developer credentials).
- `website/` (run inside that directory): `npm ci`, `npm run dev`, `npm run build`, `npm run lint` (oxlint).

## iOS companion app (PilotNest)

- `iOS/MacPilotRemote/` is an **xcodegen** project: run `xcodegen generate` in that directory after adding or removing files, then build with `xcodebuild -project MacPilotRemote.xcodeproj -scheme MacPilotRemote`. Device installs go through `xcrun devicectl device install app`.
- User-facing strings live in `Resources/RemoteText.swift`; keep `.simplifiedChinese` and `.english` entries in sync (same rule as `AppText`). Ask for an explicit `language:` when a test must prove both tables (`RemoteText.value(_:language:)`), because reading through the system locale only, a missing Chinese entry silently answers in English.
- **Home-screen controls the user never asked for are forbidden.** `RemoteControlFeature.isEnabledByDefault` is false for `.navigation` and for `.sidecar`: paging keys move the Mac's page and Sidecar takes over a second display, so both stay hidden until switched on in Settings › Control features. A new feature in those groups must be opt-in too. `RemoteControlPreferencesTests` and `ControlSectionOrderUITests.testSidecarRowAppearsOnlyOnceTheUserEnablesIt` pin it.
- The trackpad page deliberately **never follows system rotation**. Orientation is owned by `App/InterfaceOrientationController` (portrait lock on iPhone, free rotation on iPad, frozen while the trackpad page is open, landscape only while the remote keyboard is up in a sideways hold). Never add gyro-driven rotation.
- Version bumps live in `project.yml` (`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`); every TestFlight upload needs a new build number.

## Coding Style & Naming Conventions

- Swift, 4-space indentation. No committed formatter or linter; match surrounding style.
- Types `UpperCamelCase`, members `lowerCamelCase`. Test methods are behavioral phrases (`closeWindowsModeUsesBehaviorBasedName`).
- Route user-facing strings through `AppText.value(_:language:)`, keeping `.simplifiedChinese` and `.english` entries in sync.

## UI Design Standards

- All feature pages MUST follow the unified UI language (native sidebar + 30pt header + adaptive-glass `SettingsCard`). macOS 26 uses Liquid Glass and macOS 15–25 uses the documented material fallback. Read `docs/UI_DESIGN.md` before adding or modifying any UI, and run its new-feature checklist before submitting.
- Reuse `SettingsCard` (`Sources/MacPilot/SettingsUI.swift`) in the main module and `RightClickSettingsCard` (`Sources/MacPilotRightClickKit/Settings/RightClickSettingsCard.swift`) in the Kit — never write an ad-hoc card style.
- The design tokens (margins 36/34/30, card spacing 24, adaptive corner radius/material, etc.) are normative in `docs/UI_DESIGN.md`; do not deviate.

## Remote trackpad & pressure simulation

- Mac-side discovery availability must follow the actual DNS-SD registration callback, never `NWListener.ready`. A ready socket can coexist with `PolicyDenied` and no broadcast. Registration failures must recover automatically without resetting system permissions, restarting the app, or removing pairings; keep the listener and existing authenticated connections alive. Do not infer that the user denied permission from an individual policy error. Run `RemoteBonjourPublisherTests`, including repeated failure/recovery and stale callbacks, after changing this lifecycle.

- `docs/REMOTE_CONTROL.md` is the protocol + feature spec. Read it before touching the remote channel: frame tag `0x03`, binary `RemoteInputBatchCodec` (event kinds 1 move / 2 click / 3 scroll / 4 press / 5-7 pressBegin-pressUpdate-pressEnd), capability bits `realtimeInput` / `inputPressure` / `inputPressureStream`.
- Wire-compat rule: every new event kind must be gated by a capability bit. Old Macs must keep decoding batches — the phone downgrades press events (stream → one-shot graded press → plain click) based on what the Mac advertises in the server hello.
- **Capability hooks must be protocol requirements, not extension defaults.** `RemoteConnectionHost` declares `dockGroupsHosting` and `sidecarHosting` (with `nil` defaults in the extension). A member the protocol does *not* declare is resolved statically inside its own extension, so an extension-only default made `advertisedCapabilities` see `nil` on every host — including `RemoteControlServer`, which supplied both — and withheld those capabilities from every hello. The feature then looks broken on the phone with no error on either side. Tripwire: `SidecarCapabilityAdvertisementTests` reads `advertisedCapabilities` off a real `RemoteControlServer` through `any RemoteConnectionHost`.
- The `sidecar` bit means **"this build answers the three Sidecar commands"**, never "this machine supports Sidecar": a Mac with the host wired always advertises, and a Mac that cannot drive a display says so per request with `sidecarUnavailable`. `unsupportedCommand` stays reserved for a Mac with no Sidecar host. Gating the bit on `SidecarCore`'s live verdict made the phone stop asking instead of reporting the Mac's answer.
- The iOS press recognizer is the only place pressure intent may live: `Engine/` holds `PressureIntentEngine` (mode config + weighted score), `TouchHistory`, `PressGestureRecognizer`, `PressureSample`, `PressureScore`, `PressureCurve`, `PressState`, `PressureDebugInfo`. Forbidden: single absolute-radius or duration-only thresholds, scoring in views, fixed waits that delay clicks, per-sample update spam (throttle ≥0.03 pressure delta). Each touch is its own adaptive baseline; travel past 12 px cancels a press; the optimistic click keeps ordinary taps instant.
- Mac injection: `RemoteInputCoordinator` routes events; simulated pressure rides `kCGMouseEventPressure` only on the CGEvent path (the virtual HID report has no force field — there the press degrades to its button bits). macOS 26 denies `IOHIDUserDeviceCreate` to ordinary processes, so the CGEvent fallback is the shipping behavior; scrolling always uses `ScrollInjector`.

## Testing Guidelines

- Before every release, run the applicable historical regression checks in `docs/RELEASE_REGRESSION_TESTS.md` and `docs/engineering/REGRESSION_CATALOG.md`, and the full safe suite (`bash Scripts/run-regressions.sh --force-full` locally; the gate does it automatically on main merges). Report real-hardware and old-version upgrade gaps separately — mock passes are not real acceptance (see `docs/engineering/acceptance/`).

- Framework: **Swift Testing** (`import Testing`; `@Test`, `#expect`, `#require`). Suites are `struct`s of `@testable import MacPilot` functions.
- Name tests as sentences describing the invariant. Use `UserDefaults(suiteName:)` with a UUID for stateful tests and clean up via `defer`.
- Run `swift test` before pushing.
- Tests must not lock, blank, or sleep the user's screen, or inject real login keystrokes. Use isolated/mocked screen-control operations for automated tests; never run hardware screen-control tests in the user's session. If the full suite invokes real screen control, stop it and verify the safe relevant suites instead, reporting the limitation. Real screen-state acceptance requires the user's explicit authorization and an isolated AgentSpace session when available.
- Power/display-state behavior (Awake, closed-lid sleep) can't be fully automated: follow the scenarios in `docs/AWAKE_MANUAL_TESTS.md` when changing it. Memory/resource acceptance thresholds live in `Tests/Performance/README.md` and `docs/MEMORY_REVIEW.md`.
- Known full-suite flakes (timing; pass with `--filter` in isolation — do not chase them): `CPUMonitorTests.samplerReportsAFullyBusyCoreAtItsRealShare`, `BLEWakeRecoveryTests.overdueSignalTimeoutClearsThePreSleepPresence`, `ScreenCaptureTests.startupShortcutRegistrationRetriesTransientFailure`, `ScreenCaptureTests.quickCopyAutoSaveWritesFileAndRecordsStats`, `SnapzySingleFrameCaptureTests.timeoutEndsAStalledCapture`, `RemoteVideoTransportTests.independentVideoSocketAuthenticatesAndRejectsAQueuedFrameBacklog`, `PictureInPictureTests.stalledCaptureStateAppearsAfterMotionStopsAndClearsOnChange`, `MenuBarDisplayControllerTests.topologyChangeWhileAMenuTracksDuringTheRemovedWindowRestoresTheItem`, `QuickSearchIconLoaderTests.aFailedIconIsRetriedOnceThePanelReopens`. All of these are the same shared-main-actor starvation class — they assert on wall-clock elapsed time, and a suite ahead of them can hold the main actor for tens of seconds (observed: 0.060s in isolation vs 3.982s in a full run; `QuickSearchIconLoaderTests` measured 101.8s in-suite vs 0.186s isolated). New failures outside this list are real.
- **Live window-server state is a test precondition, not a permission problem.** Selection-overlay tests read the real on-screen window list (`ScreenshotPopupWindowProbe.hasOpenPopup`): any other process at popup layer (loginwindow panels, another app's menu) legitimately holds the overlay back, and no Screen Recording grant changes that. Such a test must either state that precondition and return early when it is violated, or inject the probe (`startSnapzySelection(popupIsOnScreen:)`) and stay environment-independent — `ScreenCaptureTests.smartElementFastPathPresentsOverlayWhileFrozenFramePreparationHangs` is the injected-probe version that always evaluates the fast path.
- Before tagging a release, also run a fresh release build with `-Xswiftc -warnings-as-errors`. GitHub's macOS runner may promote Swift concurrency diagnostics that are only warnings in a cached local build.

## Commit & Pull Request Guidelines

- Use **Conventional Commits**: `feat:`, `fix:`, `refactor:`, `docs:` (e.g. `feat: add BLE proximity lock`). Imperative subject, ≤72 chars.
- PRs target `main`. Describe what and why, link issues, and call out Accessibility/Bluetooth behavior changes.
- CI builds, packages, and verifies the signature on every push/PR — do not merge if `build` fails.
- Version tags `v<major>.<minor>.<patch>` trigger the `dist` job and a GitHub Release.
- Push the release commit to `main` before creating the version tag. Never move or overwrite an already-pushed version tag; publish a new patch version for release fixes.
- A pushed tag is not proof of a published release. Verify the Actions `dist` job and `gh release view <tag>` both succeed, and confirm the ZIP asset is present.

## Content Publishing

- When publishing articles about this project to external platforms (Zhihu, Cnblogs, Juejin, CSDN, SegmentFault, sspai, etc.), write in a natural first-person developer voice — avoid template-y, marketing-style phrasing.
- Do NOT check any 「内容由AI生成」 / AI-generated declaration checkbox on those platforms.
- Reusable article drafts live in `~/Documents/MacPilot-Articles/` (`macpilot-intro.md` full version, `macpilot-human.md` first-person version, platform variants).

## Security & Signing

- `MacPilot.entitlements` enables only `com.apple.security.cs.disable-library-validation` — do not add entitlements without justification.
- The BLE unlock login password lives in **Keychain**; never log it or persist it to `config.json`.
- Accessibility and Bluetooth are required at runtime; Close Windows mode prompts for Accessibility. Ad-hoc local builds may re-prompt Accessibility each rebuild — distribute with a stable Developer ID to preserve grants.
- The tag workflow requires exactly six Actions secrets: `APPLE_CERTIFICATE_P12`, `APPLE_CERTIFICATE_PASSWORD`, `APPLE_DEVELOPER_ID`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, and `APPLE_TEAM_ID`.
- `APPLE_ID` is the Apple Developer login email; `APPLE_APP_SPECIFIC_PASSWORD` is generated at account.apple.com. Never paste an app-specific password into chat or a command argument; revoke it immediately if exposed.
- A local `MACPILOT_NOTARY_PROFILE` is optional and must be verified before use. Do not assume a profile named `MacPilot` exists merely because a previous release succeeded.

## Signing identity & designated requirement (invariant) — 摘要

DR 决定更新包是否「同一个 app」，必须跨签名身份/机器/Agent 字节一致（v1.1.355 以下曾因此全部搁浅）。完整规则与证据见 `docs/engineering/regressions/updater-release.md`，要点：

- DR 只在 `Scripts/signing-requirement.sh` 定义一次（bundle id + Apple 锚 + team OU）；绝不让 codesign 自推，绝不加 Developer-ID-only OID 或 `subject.CN` 子句；四条签名路径嵌同一字节。
- 三道门（build-app.sh、distribute-app.sh、dist job）+ `SigningRequirementTests` 钉住；绝不为过门弱化 requirement。
- 正式发布走 Developer ID + notarize（`Scripts/distribute-app.sh`）；本地 Apple Development 构建不可分发。

## FinderSync lifecycle recovery (invariant) — 摘要

选举变更必经 `FinderSyncRegistration` 并先记 `FinderSyncRecoveryJournal`；确认必须来自新鲜 PlugInKit 查询的 `+` 且路径精确匹配；用户手动禁用不得自动恢复；事务先恢复验证再启动 app。完整规则见 `docs/engineering/regressions/helper-lifecycle.md`。改动后跑 `FinderSyncRegistrationTests`、`FinderSyncRecoveryJournalTests`、`FinderSyncHeartbeatLifecycleTests`；`zsh Scripts/verify-findersync.sh` 只是只读安装态检查，绝不自动重启 Finder 或重置权限。

## Configuration compatibility (invariant) — 摘要

`StoredConfiguration` 之下的一切必须升级**和降级**都存活（v1.1.482-beta.5 曾因删字段在降级时清空全部配置）。要点：键只增不删不改名；新字段 `decodeIfPresent` + 默认值；每节经 `section(...)` 隔离解码；**持久化枚举未知值落默认而不是 throw**；`ConfigurationSchemaContractTests` 是 append-only 键集的 tripwire——契约失败时不许删断言。完整规则见 `docs/engineering/regressions/configuration-migration.md`。

## Dock and menu-bar icons (invariant) — 摘要

两个入口（Dock 图标、菜单栏图标）新装后都显示、可隐藏其一、**绝不双藏**；`willClose` 是唯一关闭信号（`orderOut` 不算）；status item 的每个 reattach 出口（含取消睡眠）都必须恢复 item，`selfHeal()` 兜底；状态图标能显示的每条警告必须在首页点名（`HomeAttentionTests` 钉住）。完整规则见 `docs/engineering/regressions/menu-bar-lifecycle.md`。

性能与菜单分发同样是硬约束（完整版见同上文档）：

- **status item 只允许图标**，禁止文本/数字 badge（实测 909ms/1704ms 整树重建）；弹窗读打开瞬间的 `MenuBarMenuSession` 快照。
- **status item 必须挂真实 `NSMenu`，绝不自己定位弹窗**——`popUp(positioning:at:in:)` 的锚点相对 button 而非菜单栏，任何手算点都偏高（macOS 27 实测 minY 高 24pt、maxY 仍高 6pt）。`MenuBarOwnedMenuTests` 钉住。
- **`menuDidClose` 不得同步释放 session**：macOS 27 在 `menuDidClose` 之后同一 run-loop turn 才派发所选动作，`NSMenuItem` 弱引用 target，同步释放即所有菜单动作静默失效；延后一个 main-queue turn 释放。
- **打开主窗口必须逃离菜单跟踪循环**：内容立即加载、下一 turn 抬窗、激活被拒仍 `orderFrontRegardless`、无可用窗口走 `openWindow(id: "main")`，禁止无人 drain 的 `pendingRequest` 标志（见 `docs/engineering/regressions/window-lifecycle.md`）。
- Validate with `AppPresenceTests`, `MenuBarDisplayControllerTests`, `MenuBarMenuSessionTests`, `MenuBarOwnedMenuTests`, `MainWindowOpenerTests` and `ConfigurationSchemaContractTests` after touching this path.

## Dock Groups helper editing (invariant) — 摘要

helper 与主 app 都写 `groups.json`：**每次写必经 `DockGroupStore.update` 的独占 `flock`**（读→改→save 会静默丢 helper 的并发编辑）；只有主 app 再生 helper bundle；拖拽 payload 必须带 `dockgroup-app:` 前缀；`NSOpenPanel` 期间不得让面板关闭。完整规则见 `docs/engineering/regressions/helper-lifecycle.md`；改动后跑 `DockGroupsCoreTests`（40 队列并发写不得丢改动）与 `DockHelperPanelPlacementTests`。

## Quick Search (invariant) — 摘要

完整规则全文见 `docs/engineering/regressions/quick-search.md`（约 20 条，含面板位置/尺寸归用户、收藏身份键、hover gate、排序层级、用途标签推导、双名索引、图标缓存）。不可妥协的骨架：

- 文件搜索**只走 `NSMetadataQuery`**，绝不递归遍历磁盘、绝不自建索引；「无结果」与「不能搜索」是不同状态，空结果必须先有「scope 可搜索」的正面判定。
- 一次一个在飞查询：150ms 防抖 + 递增 generation，旧代结果必须丢弃；IME 组装期间快捷键仍要分发。
- 面板位置与尺寸归用户所有（左上角坐标、`quickSearch.panelPosition/panelSize`），绝不召唤时重新居中；收藏与用量共享 identity 键；行动作必须携带自己的行。
- 用途标签是**推导的**（仅 bundle 内 vendor 证据），绝不猜、绝不联网；持久化枚举未知值落默认而非 throw。
- 改动后跑 QuickSearch 全套 + `ConfigurationSchemaContractTests`、`ConfigStoreTests`、`QuickSearchPersistenceTests`；`QuickSearchHotKeyTests` `.serialized`（Carbon 注册进程级），其他套件用 `Harness.quietHotkey` 不抢真实组合键。

## BLE reverse presence (invariant) — 摘要

挑战 cadence 的生命周期只属于 `startProduction`/`stopProduction`；无 manager/未上电/空订阅/未发布服务是**瞬态**，据此 cancel 任务会让已订阅手机永久失联（重新武装依赖不会再来的回调）。反向链路转换必须写 `DiagnosticLog` 的 `BLEReverse` 通道；新 alias 首样本的 `noFreshSignal` retry 必须保留。完整规则见 `docs/engineering/regressions/ble-presence.md`；验证跑 `ProximityGATTProductionRestartTests`、`BLEReversePresenceTests`、`BLEWakeRecoveryTests`。

## Clipboard history and preview (invariant) — 摘要

`storageLimit` 必须在 `ClipboardHistory` 加载/裁剪**之前**传入（初始化后再应用会按默认上限永久丢历史）；历史不因年龄过期，计数/2 GiB 上限与重复合并保持不变并双语披露；预览显隐只动右缘无动画。多屏选择测试必须到达 `SnapzyAreaSelectionController`/`FrozenAreaCaptureSession`，屏幕/view 坐标每个边界只换算一次。**绝不修改用户实时历史或通用 pasteboard。** 完整规则见 `docs/engineering/regressions/resource-performance.md`。

## Pinned screenshot hover (invariant) — 摘要

pin 只有拥有指针所在像素才可响应（`QuickAccessPinHoverCoverage`；短/空扫描答案是 exposed）；Dock 整屏窗口绝不算覆盖面；覆盖判定边沿触发 + 节流（exposed 且已 key 的 pin 零扫描）；锁定 pin 保持几何穿透；pin 共享一对鼠标 monitor、hover 只在转换时发布。完整规则见 `docs/engineering/regressions/resource-performance.md`；`QuickAccessPinPerformanceTests` 钉住发布次数与 monitor 生命周期。

## Project Summary

The repo-root `SUMMARY.md` is the project's Chinese development summary (features, release flow, pitfalls). Consult it for fuller context beyond this contributor guide.

## Migrated local release facts

- `Scripts/distribute-app.sh` is the reusable local release flow: Developer ID sign, `xcrun notarytool submit --keychain-profile <profile> --wait` when a verified profile exists, otherwise the Apple ID fallback, then `stapler staple`, `stapler validate`, and re-compress the stapled app.
- A profile name such as `MacPilot`, `OctoPilot`, or `octoshrink-notary` is not proof that the profile is usable. Run `xcrun notarytool history --keychain-profile <profile>` in the current session before reuse; do not ask the user to paste passwords into chat.
- The legacy tag workflow needs exactly these six Secrets: `APPLE_CERTIFICATE_P12`, `APPLE_CERTIFICATE_PASSWORD`, `APPLE_DEVELOPER_ID`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, and `APPLE_TEAM_ID`. The App-specific password is an Apple ID notarization credential, not a signing certificate.
- GitHub Actions runners cannot read the local Keychain. If importing a `.p12` still produces “No signing certificate ... with a private key was found”, create and unlock a temporary keychain, import the certificate, set the key partition list, and verify with `security find-identity -v -p codesigning`.

## MacPilot release preference（2026-11-01 起改为 PR 门禁流程）

- **常规改动一律走 PR**：开发分支 → 本地验证（`bash Scripts/run-regressions.sh` + 相关套件）→ 推送开发分支 → PR（用 `.github/PULL_REQUEST_TEMPLATE.md` 填写影响分析）→ CI（`build` + `Regression Gate`）→ 合并 `main`。**禁止未经用户授权绕过 PR 和 CI 直接推送 `main`。**
- Beta 发布需要**用户明确授权**：不得因为一次文档修改、测试通过或例行改动就自动打 Beta tag。收到明确发布指令后，从最新 `main` 打 `v<major>.<minor>.<patch>-beta.<n>`（同一 base 只递增 `beta.<n>`），发布前先 `git fetch` 确认 `origin/main` 未移动，移动则先 rebase 重跑门禁。
- 合并 `main` 与正式发布前执行完整安全测试（regression-gate 的 push/schedule 路径自动强制全量；本地等价命令 `bash Scripts/run-regressions.sh --force-full`）。
- Beta tags 产生 GitHub prereleases（`prerelease=true`）；绝不移动或覆盖已存在的 tag；修复发布问题用新 beta 号或新 patch。
- Stable tag（`v<major>.<minor>.<patch>`）只在用户明确要求正式发布时创建，走 Developer ID 签名 + 公证流程并核验 Actions 与 Release 资产。
- 发布成功后不动本地 `/Applications/MacPilot.app`——用户手动升级。只有用户明确要求本地升级时，先 `codesign --verify --deep --strict` 与 `xcrun stapler validate` 校验 ZIP 再安装。
- 例外：纯文档/营销目录（`docs/`、`marketing/`、`website/`、`.github/*.md`）改动在门禁上等价于无代码改动，但**发布授权规则不变**——同样需要用户点头才能发 Beta。

## App Store & TestFlight (asc CLI)

- App Store Connect is automated through the `asc` CLI (homebrew). Working key profile: `agentspace-notary`; the `octoshrink` profile (keyId `25L89LAZD5`) currently returns 401 and needs regeneration. PilotNest's App id is `6811335132`.
- TestFlight: `asc publish testflight --app 6811335132 --ipa <ipa> --group <internal-group-id>` — the internal group receives every build automatically. External distribution needs `asc builds add-groups --submit --confirm`, and Apple allows only **one build per train in beta review** at a time (later submissions fail until the earlier one completes).
- App Store submission: `asc review submit --app 6811335132 --version <ver> --build <build-id> --confirm` (attach + submit). Release version strings must be **higher than the live App Store version** (1.2.2 is live as verified through ASC on 2026-10-13; 1.2.3 is the current editable train). Once a version reaches `READY_FOR_SALE` its train is closed and Apple rejects further uploads of that version with **90186/90062** — this has now happened twice (1.2.1 build 29, 1.2.2 build 36). Before preparing a TestFlight IPA, run `asc versions list --app 6811335132` and confirm the marketing version is still editable; if it is not, create the next train with `asc versions create --version <next> --copy-metadata-from <live> --exclude-fields whatsNew` and bump `MARKETING_VERSION` too, not just the build number. Those two error codes are a version-train problem, never a signing or profile problem — do not redo signature work in response to them. iPad-capable binaries require iPad Pro 12.9"/13" screenshots: capture on an iPad Pro simulator (`xcrun simctl io <sim> screenshot`, 2064×2752 is accepted) and upload with `asc screenshots upload --device-type IPAD_PRO_3GEN_129`.
- Canonical App Store metadata lives in `iOS/MacPilotRemote/metadata/` (`version/<ver>/<locale>.json`, including `whatsNew`; en-US and zh-Hans both required). Apply with `asc metadata push --app 6811335132 --version <ver> --platform IOS --dir metadata`.

## PilotNest App Store signing gate

- Before every PilotNest upload, read and complete `docs/APP_STORE_RELEASE_CHECKLIST.md`. Build 20 (1.2.0) failed Apple's binary validation with ITMS-90161, Invalid Provisioning Profile / Missing code-signing certificate; this was not an App Review content rejection.
- Validate the exact final exported IPA: distribution signature, matching signer certificate in the embedded profile, profile validity, bundle/team identity, and App Store entitlements. A development-signed archive alone does not prove that the exported IPA is invalid; never diagnose a failed build using another build's archive.
- Keep the existing Xcode automatic signing + `app-store-connect` export flow unless a separately validated manual distribution flow is needed. Never treat an ASC API key or app-specific password as a signing certificate, or pin an old provisioning-profile UUID without revalidating it.
- An automatic-signing export embeds an **Xcode-managed** profile (`iOS Team Store Provisioning Profile: <bundle-id>`, `IsXcodeManaged=true`), which `asc profiles list` does not return — its absence there is not a defect and is not grounds to fall back to a manual profile. Prove it instead from the IPA: `ProfileDistributionType=STORE` in the Apple-signed CMS attributes, plus `openssl cms -verify -inform DER -in embedded.mobileprovision -CAfile <Apple roots>` chaining to the Apple Root CA in the macOS system keychain. `security cms -D` only **decodes** — it returns 0 for a tampered profile too, so it is never integrity evidence. Always run a tamper control alongside any verification claim.
- Upload success is not completion: wait for the exact build to reach VALID, verify the attached build, then submit review. VALID and WAITING_FOR_REVIEW do not mean Apple has approved the app.

## Remote desktop touch behavior

- PilotNest remote desktop uses one continuous relative mouse trackpad across the video and lower content area, both with the keyboard shown and hidden. Never map video touches to absolute screen coordinates. A two-finger pinch on the preview only changes local video zoom; other gestures keep relative mouse semantics. Keep buttons and the system keyboard interactive above the touch surface.

## 按需资源与辅助进程生命周期（2026-10-28）— 摘要

功能仅在实际使用时占用资源：**关闭功能必须停止任务、定时器、监听、事件 tap、采集、编码、连接并释放可重建缓存**；隐藏窗口不等于关闭功能。专属 helper 按需启动、随功能关闭正常退出；共享 helper 按租约计数；注册安装状态与进程运行状态分离；显示/电源 helper 先完成恢复并确认再退出，不得 kill 绕过；快速开关、崩溃恢复、延迟回调不得误停新会话；launchd RunAtLoad/KeepAlive 必须有实际必要性。完整要求与验证覆盖清单见 `docs/engineering/regressions/helper-lifecycle.md`（help-002-on-demand-processes）。
