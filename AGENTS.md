# Repository Guidelines

Contributor guide for **MacPilot**, a native macOS menu-bar app (Swift 6, SwiftPM, macOS 14+) with 19 independently switchable feature modules: app inactivity rules, scheduled launch, Awake keep-awake, BLE proximity lock/unlock, iPhone remote control, capture/screenshot tooling, dock groups, local ports, quick search (app launcher + Spotlight file-name search), and more.

## Project Structure & Module Organization

- `Sources/MacPilot/` — main executable target, one subdirectory per feature cluster (`Awake/`, `BLE/`, `DockGroups/`, `RemoteControl/` (remote server), `InputCore/` (remote input injection), `SnapzyCapture/`, `SmoothScrolling/`, `QuickSearch/` (non-activating panel, Carbon hot key, pinyin-ranked app index, `NSMetadataQuery` file search), …) plus `MacPilotApp.swift` (core), `BLEUnlock.swift` (proximity lock/unlock), and `SoftwareUpdate.swift` (release checks, validation, and update orchestration).
- `Packages/MacPilotRemoteProtocol/` — local SwiftPM package with the wire protocol + transport shared by macOS and iOS: framing, crypto, capability bits and the binary realtime-input codec. Both platforms compile it; wire changes must keep old peers decoding.
- `iOS/MacPilotRemote/` — **PilotNest**, the iOS companion app (`com.misswell.macpilot.remote`, iOS 17+, Xcode project generated from `project.yml`; see "iOS companion app" below).
- `website/` — Chinese product site (Vinext/React, deployed to Cloudflare); Node ≥ 22.13, its own `package.json` and lint setup.
- `Sources/MacPilotUpdater/` + `MacPilotUpdaterSupport/` — helper executable that atomically replaces the verified app bundle and relaunches it after the main process exits.
- Other packaged targets: `MacPilotDockGroupsCore` + `MacPilotDockHelper`, `MacPilotLocalPortsCore`, `MacPilotPowerIPC` + `MacPilotPowerHelper`, `MacPilotRightClickKit` + `MacPilotFinderSync`, `MacPilotOcclusionPatch` (dynamic library). See Architecture boundaries below.
- `Tests/` — Swift Testing targets: `MacPilotTests` (main suites, e.g. `LaunchRuleCodingTests.swift`, `BLEUnlockPerformanceTests.swift`, `SoftwareUpdateTests.swift`), plus `MacPilotFinderSyncTests`, `MacPilotLocalPortsCoreTests`, `MacPilotRightClickKitTests`, `MacPilotUpdaterSupportTests`. `Tests/Performance/` holds resource-acceptance benchmarks (`resource-benchmark.sh`, thresholds in its README).
- `Resources/` — `Info.plist`, `MacPilot.entitlements`, `AppIcon.icns`, icon sources.
- `Scripts/` — `build-app.sh`, `build-findersync.sh`, `distribute-app.sh`, `version.sh`, `signing-requirement.sh` / `verify-signing-requirement.sh`, `measure-memory.sh`, `capture-permission-diagnostics.sh`, `verify-awdl.sh`.
- `docs/` — `UI_DESIGN.md` (normative UI tokens), `REMOTE_CONTROL.md` (iPhone→Mac design, wire protocol, security model), `AWAKE_MANUAL_TESTS.md` (manual power-state acceptance), `PERMISSION_DIAGNOSTICS.md`, `UPDATE_DOWNLOADS.md`, `MEMORY_REVIEW.md`.
- `.github/workflows/build.yml` — CI.
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

- Framework: **Swift Testing** (`import Testing`; `@Test`, `#expect`, `#require`). Suites are `struct`s of `@testable import MacPilot` functions.
- Name tests as sentences describing the invariant. Use `UserDefaults(suiteName:)` with a UUID for stateful tests and clean up via `defer`.
- Run `swift test` before pushing.
- Tests must not lock, blank, or sleep the user's screen, or inject real login keystrokes. Use isolated/mocked screen-control operations for automated tests; never run hardware screen-control tests in the user's session. If the full suite invokes real screen control, stop it and verify the safe relevant suites instead, reporting the limitation. Real screen-state acceptance requires the user's explicit authorization and an isolated AgentSpace session when available.
- Power/display-state behavior (Awake, closed-lid sleep) can't be fully automated: follow the scenarios in `docs/AWAKE_MANUAL_TESTS.md` when changing it. Memory/resource acceptance thresholds live in `Tests/Performance/README.md` and `docs/MEMORY_REVIEW.md`.
- Known full-suite flakes (timing; pass with `--filter` in isolation — do not chase them): `CPUMonitorTests.samplerReportsAFullyBusyCoreAtItsRealShare`, `BLEWakeRecoveryTests.overdueSignalTimeoutClearsThePreSleepPresence`, `ScreenCaptureTests.startupShortcutRegistrationRetriesTransientFailure`, `ScreenCaptureTests.quickCopyAutoSaveWritesFileAndRecordsStats`, `SnapzySingleFrameCaptureTests.timeoutEndsAStalledCapture`, `RemoteVideoTransportTests.independentVideoSocketAuthenticatesAndRejectsAQueuedFrameBacklog`, `PictureInPictureTests.stalledCaptureStateAppearsAfterMotionStopsAndClearsOnChange`, `MenuBarDisplayControllerTests.topologyChangeWhileAMenuTracksDuringTheRemovedWindowRestoresTheItem`. All of these are the same shared-main-actor starvation class — they assert on wall-clock elapsed time, and a suite ahead of them can hold the main actor for tens of seconds (observed: 0.060s in isolation vs 3.982s in a full run). New failures outside this list are real.
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

## Signing identity & designated requirement (invariant)

Every build embeds one **designated requirement** (DR) in the app bundle, and macOS uses it to decide whether an update package is "the same app" as the installed one. It must stay byte-identical across signing identities, machines and agents — a mismatch makes in-app updates impossible to install (this stranded every install below v1.1.355). Nested code (updater, FinderSync appex, helpers, dylib) keeps its own identifier and stays independently signed; only the app bundle's requirement is the shared identity.

- **Single definition:** `Scripts/signing-requirement.sh`. It pins the bundle identifier, Apple's code-signing anchor, and the team OU (`U8U443D7ZL`) — nothing else.
- **Never let codesign derive the requirement**, and never add Developer-ID-only OID clauses or `subject.CN` clauses. Each of those is satisfied by exactly one kind of certificate, so an Apple Development build would stop being "the same app" as a release: updates and privacy grants would stop carrying over in both directions.
- **All four signing paths** (Developer ID, Apple Distribution, Apple Development, ad-hoc) must embed the same bytes. Do not branch the requirement by signing identity.
- **Three gates enforce it:** `Scripts/build-app.sh` (after signing), `Scripts/distribute-app.sh` (after re-packaging), and the `dist` job before `gh release create`. `Tests/MacPilotTests/SigningRequirementTests.swift` is the tripwire test that keeps those gates wired.
- **Never weaken the requirement to make a build pass.** Fix the signing path instead; an already-installed app cannot be talked into accepting a package it does not recognise.
- Formal releases still have to be Developer ID signed and notarized via `Scripts/distribute-app.sh`. Local Apple Development builds share the same identity for TCC/updates but are not distributable (Gatekeeper rejects them).

## FinderSync lifecycle recovery (invariant)

- Never temporarily elect the Finder extension `ignore` without first recording a valid, target-bound `FinderSyncRecoveryJournal` intent under its cross-process lock. Use `FinderSyncRegistration` rather than open-coding election changes.
- Clear a recovery intent only after a fresh PlugInKit query confirms `+` at the current app's exact `Contents/PlugIns/FinderSync.appex` path. Command success or an enabled stale copy is not confirmation.
- Recover an ignored election automatically only when a valid matching intent proves MacPilot's own unfinished transaction; preserve unmarked user-disabled extensions and refuse invalid/mismatched intents.
- Successful update/rollback transactions must restore and verify before app launch. Failure retains its journal; relaunching an intact app for recovery happens only after the registration transaction/lock ends, and must not be reported as successful restoration.
- The resident extension must resume heartbeat and request current configuration on every authenticated main-app `running` notification. Repeated notifications must not create duplicate timers, and delayed initialization must not undo `quit`.
- Run the mocked `FinderSyncRegistrationTests`, `FinderSyncRecoveryJournalTests`, and `FinderSyncHeartbeatLifecycleTests` after lifecycle changes. Use `zsh Scripts/verify-findersync.sh` for a read-only installed-state check; it is not visual menu acceptance. Never restart Finder or reset permissions automatically.

## Configuration compatibility (invariant)

Everything persisted under `StoredConfiguration` (`config.json` + sidecar files) must survive upgrades **and downgrades**. In v1.1.482-beta.5, removing one struct field made older releases unable to decode the file, and the fallback-to-defaults path wiped every feature's configuration on downgrade. The rules below are hard invariants:

- **Never remove or rename an encoded Codable key.** Deprecate in place: stop using it in the UI/logic but keep the stored property and always encode it (`AwakeSessionProfileConfiguration.endCalculation` is the reference case).
- **New fields must decode tolerantly** — `decodeIfPresent` + default, never a required key; keep the required-key set identical to what the oldest supported release writes.
- **Section isolation:** `StoredConfiguration.init(from:)` decodes every section through its `section(...)` helper; one unreadable section falls back to that section's defaults and is recorded in `unreadableSections` so `load()` quarantines the raw file before any save. Do not bypass this helper for persisted sections.
- **The tripwire test** `Tests/MacPilotTests/ConfigurationSchemaContractTests.swift` asserts every persisted type still encodes its historical key set (append-only). A failing contract means your change would strand downgrades — keep the key, don't delete the assertion.

## Dock and menu-bar icons (invariant)

Both entry points are shown after a fresh install, and the user may hide either one in Settings — but never both. The rules live in `Sources/MacPilot/AppPresence.swift`; the model only persists intent, `AppPresenceController` applies it.

- **At least one entry point always survives.** `AppPresenceSettings.normalized()` restores the menu-bar icon when a stored pair asks for neither, and `allowingDockIconChange` / `allowingMenuBarIconChange` refuse the change that would remove the last one. The Settings switches are disabled in that state rather than silently rejecting the toggle. A configuration that hides both (hand-edited, or written by a future build) must never strand a running app with no way back in.
- **The Dock icon follows the main window only while the menu bar still offers a way in.** `AppPresencePolicy.showsDockIcon` returns the window state when both are enabled, and always `true` in the Dock-only configuration — there the icon is the only way back, so it must outlive the window. Closing the window switches the app to `.accessory`; reopening (menu bar, Dock click, deep link) switches it back to `.regular`. `LSUIElement` stays `true` in `Info.plist`; the policy is applied at runtime.
- **`willClose` is the only close signal.** `orderOut` (the login-launch path in `hideRegularWindows`) must not hide the Dock icon: a hidden window is not a closed one.
- **The status item must always leave an item behind.** `MenuBarDisplayController.scheduleReinsert` removes the item, waits, and reinstalls; every exit from that removed window — including a cancelled sleep — has to restore it, or `reinserting` stays set with no item and no task and the icon is gone until relaunch (observed after the v1.2.2-beta.59 native-menu change). `scheduleReinsert` restores synchronously before its next pass, and `selfHeal()` (driven by `startWatchdog`) covers the rest.
- **Every warning the status item can show must be named on the Home page.** The triangle is `AwakeSessionManager.hasAttentionIssue`; `HomeView` renders the same `attentionIssues` list, so the icon can never point at a failure the app cannot explain — including after the Awake feature is switched off and its page is unreachable. A closed-lid failure raised while retiring an unused power service keeps `ClosedLidSleepFailure.stage == .retirement` and must never be described as lost sleep protection. `HomeAttentionTests` pins both the icon/list agreement and the zh-en copy.
- Validate with `AppPresenceTests`, `MenuBarDisplayControllerTests` and `ConfigurationSchemaContractTests` after touching this path.

## Dock Groups helper editing (invariant)

The helper panel can add, remove and reorder a group's apps, so the old "main app writes, helper reads" split no longer holds. Both processes edit the same `groups.json`; correctness depends on these rules:

- **Every write goes through `DockGroupStore.update`.** It takes an exclusive `flock` on `<root>/.groups.lock`, re-reads the document, applies the mutation, and writes atomically. Never open-code a read → mutate → `save` in either process: a helper edit made between the read and the save is silently lost. `DockGroupsModel.commit` and `refreshDockTileAnchors` merge into the latest disk document for the same reason.
- **Only the main app regenerates helper bundles.** After a helper edit, `DockGroupChangeNotifier.post(groupID:)` sends a distributed notification; the main app reloads and regenerates that group's helper so the composite Dock icon follows the members. The helper must never rebuild its own bundle.
- **Drag payload safety:** reorder drags carry `dockgroup-app:<uuid>` (`DockHelperView.dragPrefix`). Anything that does not match the prefix is not a reorder. The drop index is the final index after the move.
- **The app picker must not dismiss the panel.** `NSOpenPanel.runModal()` takes key status; `DockHelperPanel.isPresentingModal` suppresses both key-loss and outside-click dismissal until the picker closes, then re-keys the visible panel and resets `DockGroupPanelDismissalPolicy`.
- Adding/removing members resizes the panel through `DockHelperLayout.size(for:)` + `DockHelperPanelPlacement.resizedOrigin`: a bottom Dock keeps the bottom edge and horizontal center, side Docks keep the vertical center and their Dock-adjacent edge.
- Validate `DockGroupsCoreTests` and `DockHelperPanelPlacementTests` after touching this path; the concurrency test writes through separate store instances on 40 queues and must lose no changes.

## Quick Search (invariant)

- File search goes through `NSMetadataQuery` only. Never substitute `FileManager` recursive traversal of the home directory or disk, and never build a self-maintained full-disk index — Spotlight is the index this feature is designed to ride.
- "No results" and "cannot search" are different states. When the index is off, the selected scope is not indexed, no scope is available, or the query refused to start, the panel shows that reason (`QuickSearchIndexIssue`); it must never be presented as "no matching files". Do not add a code path that reports an empty result list without first having a positive verdict that the scope is searchable.
- One in-flight query at a time: every keystroke is 150ms-debounced and tagged with an increasing generation, a new query terminates the previous one and its notification observers, and closing the panel stops the query. Results from a stale generation must be dropped.
- Empty-scope decisions belong to the model: `startFileSearch` reports `.noScopeSelected` instead of dispatching a query with an empty scope array, because Spotlight would silently widen the search on its own.
- The panel opens without the main settings window: never initialise the whole settings UI on summon; the pinyin and initials of an app are normalised when the index is built, not per keystroke; disk enumeration and `Info.plist` reads stay off the main actor; no timer scans the disk while the panel is closed.
- Carbon registration status is reported honestly (`isHotKeyRegistered`, `lastRegistrationStatus`). A failed `RegisterEventHotKey` must show its reason in the settings page and must not mark the shortcut as enabled; rejecting or conflicting with another feature keeps the previously valid binding and writes no config.
- Panel position is user-owned: the grip at the leading edge of the search row drags the panel (`dragFromHeader` → `performDrag`, mouse-up detected by polling `NSEvent.pressedMouseButtons` because WindowServer owns the drag and `mouseUp` never reaches the view), the frame is stored as the **top-left** corner in `quickSearch.panelPosition`, and the same key set as the clipboard keeps validating it. Never re-centre on summon and never let the anchor be the bottom-left — the panel grows with the row count and must grow downward. Validating the coordinate belongs to `rememberPanelPosition` (a NaN written to disk would fail the whole config save), not to the decoder. `resetPanelPosition()` clears the key and calls `applyPlacement()` so the user sees the move immediately.
- Panel size is user-owned too: a 6pt border band (corners included) drags with `QuickSearchPanelLayout.frameResized`, which keeps the opposite edge pinned, clamps to 400×180 and the current screen, and stores `quickSearch.panelSize` together with the (possibly moved) top-left through `rememberPanelFrame` in one write. A saved size replaces the row-count-driven height; `resetPanelSize()` clears only the size. Never re-center or re-fit a user-set size on summon.
- Favorites and usage counts share one identity key (`QuickSearchUsageStore.identity`: Bundle ID, else path). A favorite row renders from its stored snapshot when the live index has not built yet — "index is building" must never look like "favorites are empty" — and resolves through the inventory when it has, so a renamed or moved app follows the live name. Row actions, context-menu actions included, must carry the row they belong to; never act on the selection index alone.
- A hover may change the selection only after the pointer has actually moved since summon. When the panel appears under a stationary pointer, AppKit delivers an initial hover for the row underneath; it must not displace the first row. `openPanel()` arms `QuickSearchHoverGate` with the summon location, `selectRowByHover(at:)` refuses until that location changes, and rows use `onContinuousHover` so movement inside the same row also counts. Every open re-arms the gate.
- Match tier is the primary sort key for results (`QuickSearchRanking.orderedByRelevance`): every name hit (including fuzzy) outranks tag and description hits, and usage frequency only breaks ties inside the same tier. File rows keep Spotlight order among equal counts (`QuickSearchFrequencyOrder`). Record a use only after the open actually succeeded.
- Purpose tags and searchable descriptions are derived, never guessed: only what the vendor already wrote inside the app bundle may produce them — `Info.plist` (`LSApplicationCategoryType`, `CFBundleURLTypes` schemes, `CFBundleDocumentTypes` UTIs, `NSServices` menu titles, `CFBundleGetInfoString`), `InternetAccessPolicy.plist`/`.strings`, an Electron app's `package.json` (inside `app.asar` or plain) and localized `InfoPlist.strings` names/descriptions, computed on the background scanner at index build — no network and no App Store lookup. `utilities`/`productivity` and `developer-tools` categories, `public.folder`-style boilerplate, and a plain-text-only document list are deliberately not purposes: `developer-tools` is a packaging-toolchain default (52 apps on this machine claim it, including 有道云笔记, 字由 and QQ), so code tools are recognised from declared source/script UTIs instead. An app that registers `http`/`https` is a general handler, so its document types must not make it an "image tool". Tag hits rank below every name hit and are only consulted when `quickSearch.matchScope` is `.nameAndPurpose`.
- Description words are matched through `QuickSearchKeywordLexicon`, a built-in offline Chinese↔English concept list (AI/Agent, 下载/download, 清理/cleanup, 截图/screenshot …) expanded at index build; never add a translation API or embed a full `package.json`/UI copy in the index. A bounded fallback may read en/zh `.lproj` UI strings only when the app has neither tags nor descriptions, and only accepts the dominant concept(s) — at least three matching UI strings, ranked by hit count, with a second concept needing half the top concept's evidence. Description matches carry tier `.keyword`, below fuzzy name matches — a name hit always beats a description hit regardless of usage frequency, and description hits are gated by the same `.nameAndPurpose` scope.
- One app can have two names: index the displayed (localized) name **and** the raw `CFBundleName`/`CFBundleDisplayName` and the bundle folder name — Finder shows 迅雷 while the plist says Thunder — and every variant carries its own pinyin and initials. A localized `InfoPlist.strings` can also override the name with an **empty string** (三局通 does, with development region `en`), so resolution must treat empty as missing and fall through to the bundle folder name: a plain `??` chain stops at the empty value and leaves an unnamed row in the panel. An unknown value of a persisted enum must fall back to the default instead of throwing: throwing wipes the whole `quickSearch` section, which is precisely the accident `ConfigurationSchemaContractTests` exists to prevent.
- Row icons live behind `QuickSearchIconLoader` and a disk cache at `~/Library/Caches/MacPilot/QuickSearch/Icons/` (`QuickSearchIconDiskCache`), never a live icon-service call per open. The cache key is standardized path + bundle modification date + point size, so an app update invalidates its entry immediately; entries refresh after 7 days (stale entries still render while a background rebuild runs) and are pruned after 30 days. Reads on a panel open are synchronous so icons and text paint in the same frame; successful loads are written through. A failed background render falls back to the main-thread `NSWorkspace` path only when the system loader is in use, and injected test loaders must never read or write the user cache (tests pass their own temp `diskCache`; the default loader skips `.shared` under the test host).
- Validate the QuickSearch suites plus `ConfigurationSchemaContractTests`, `ConfigStoreTests` and `QuickSearchPersistenceTests` after touching this module. `QuickSearchHotKeyTests` is `.serialized` because Carbon registration is process-global; other suites use `Harness.quietHotkey` (an intentionally invalid binding) so they never grab a real key combination.

## BLE reverse presence (invariant)

- The challenge cadence's lifetime belongs to production: only `startProduction`/`stopProduction` may arm or end it. `issuePresenceChallengesIfNeeded` and `didUnsubscribeFrom` must treat a missing manager, an unpowered radio, an empty subscriber list or an unpublished service as transient — cancelling the task on any of them used to leave a still-subscribed phone unchallenged until the app restarted, because re-arming depended on a subscribe callback that would never arrive again.
- Reverse-link transitions must be durable, not just in-memory: production start/stop, subscribe/unsubscribe, cadence wait/resume, and a verified sample resuming after ≥30 s go to `DiagnosticLog` under `BLEReverse`. Per-sample rejections are throttled to one per 10 s. `log()` alone writes only to a ring buffer an installed build cannot show, so link loss was undiagnosable.
- A first sample on a freshly learned alias can still hit `unlock skipped reason=noFreshSignal` because presence is recomputed before `lastRSSI` is recorded; the per-sample retry at the tail of `updateMonitoredPeripheral` is what unlocks it. Do not remove that retry as redundant. Validate with `ProximityGATTProductionRestartTests`, `BLEReversePresenceTests` and `BLEWakeRecoveryTests`.

## Clipboard history and preview (invariant)

- Pass the configured `storageLimit` into `ClipboardHistory` before it loads/trims persisted records. Applying a limit after initialization can permanently discard history and its content files using the default limit.
- History does not expire solely because of age. Keep count/2 GiB content limits and duplicate merging; disclose those behaviors in both UI languages. Do not remove persisted settings keys.
- Preview visibility changes resize only the panel's right edge without AppKit or SwiftUI animation. Keep the one-second hover delay and the short row-to-preview grace period; do not retain a second delayed collapse layout.
- Validate with the isolated `Clipboard` suites, including Model settings → first history load → flush/reload. Never modify the user's live history or general pasteboard during tests.
- Multi-display selection tests must reach `SnapzyAreaSelectionController` and `FrozenAreaCaptureSession`, not only legacy crop helpers. Inject presentation/cursor effects so test windows stay hidden. A passing direct-handler test does not establish that WindowServer's real pointer-event routing is correct.
- Smart-element resolvers return screen coordinates; overlay selection delegates accept view-local coordinates. Convert exactly once at each boundary, including content-view insets. Cover recognized-element single clicks as well as manual/smart drags on a nonzero-origin display.

## Pinned screenshot hover (invariant)

- A pin may only react to the pointer when it owns the pixel the pointer is on. Menus, combobox dropdowns and tooltips draw above the pin's `floating + 2` level; reacting to a geometric frame hit instead made the pin take key window status and closed another app's popup, so an item overlapping a pin could never be clicked. Use `QuickAccessPinHoverCoverage`; a short or empty window-server sweep answers "exposed", never "covered".
- The Dock's own window spans a whole display (level 20) while the Dock only draws the strip, so it must never count as a covering surface: `isDockSurface` drops `com.apple.dock` windows at or below the Dock level. Counting it made pins on the main display never hover while pins on a display without a Dock worked. Dock menus ride at popup levels, so they still count.
- The coverage verdict costs a `CGWindowListCopyWindowInfo` walk, so it stays edge-triggered plus interval-throttled through `sweepIsWorthRunning` — an exposed, already-key pin must run zero sweeps. Do not move that call into every pointer event, and keep coordinate conversion hoisted (one main-display height, one subtraction): per-window `DisplayMapping` rebuilds are far too expensive on this path.
- A locked pin keeps geometric mouse passthrough: it never takes key status and shows no hover chrome, so a cover must not change whether clicks reach it.
- Pins share one local/global mouse-monitor pair. Publish hover state only on transitions; repeated pointer positions must not invalidate every pin's SwiftUI view. Closing/suspending the last pin removes both monitors. Keep zoom easing time-based across refresh rates and reuse the HUD hide timer through each gesture. `QuickAccessPinPerformanceTests` covers publication counts, shared-monitor lifetime, and zoom behavior without displaying windows.

## Project Summary

The repo-root `SUMMARY.md` is the project's Chinese development summary (features, release flow, pitfalls). Consult it for fuller context beyond this contributor guide.

## Migrated local release facts

- `Scripts/distribute-app.sh` is the reusable local release flow: Developer ID sign, `xcrun notarytool submit --keychain-profile <profile> --wait` when a verified profile exists, otherwise the Apple ID fallback, then `stapler staple`, `stapler validate`, and re-compress the stapled app.
- A profile name such as `MacPilot`, `OctoPilot`, or `octoshrink-notary` is not proof that the profile is usable. Run `xcrun notarytool history --keychain-profile <profile>` in the current session before reuse; do not ask the user to paste passwords into chat.
- The legacy tag workflow needs exactly these six Secrets: `APPLE_CERTIFICATE_P12`, `APPLE_CERTIFICATE_PASSWORD`, `APPLE_DEVELOPER_ID`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, and `APPLE_TEAM_ID`. The App-specific password is an Apple ID notarization credential, not a signing certificate.
- GitHub Actions runners cannot read the local Keychain. If importing a `.p12` still produces “No signing certificate ... with a private key was found”, create and unlock a temporary keychain, import the certificate, set the key partition list, and verify with `security find-identity -v -p codesigning`.

## MacPilot release preference

- After every completed and verified MacPilot change, automatically commit and push `main`, then publish a new Beta prerelease tagged `v<major>.<minor>.<patch>-beta.<n>` through `release-beta.yml`. This includes docs-only and dead-code-only changes; do not wait for another reminder.
- For subsequent Beta releases, keep the current major/minor/patch version unchanged and increment only `beta.<n>` (for example, `v1.1.522-beta.1` → `v1.1.522-beta.2`). Do not increment the patch version for a Beta update; only change the base version when the user explicitly requests it or a formal Stable release requires it.
- Before creating the Beta tag, `git fetch` and confirm `origin/main` has not moved. If it has, rebase, rerun the required gates on the merged tree, and derive a fresh Beta version.
- Verify the Beta GitHub Actions run and its Release assets. Beta tags must produce GitHub prereleases (`prerelease=true`); never move or overwrite an existing tag.
- Do not create a stable version tag (`v<major>.<minor>.<patch>`) or publish a formal Stable Release unless the user explicitly asks for a formal/stable release. When explicitly requested, use a new patch version, never overwrite a tag, and follow the authenticated Developer ID signing and Apple notarization flow above; verify the Actions run and release assets.
- After a successful release, leave the local `/Applications/MacPilot.app` install alone — the user upgrades it manually. Never quit, replace, or relaunch the local app as part of the release flow. Only when the user explicitly asks for a local upgrade, validate the ZIP's signature and notarization ticket with `codesign --verify --deep --strict` and `xcrun stapler validate` before installing.

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

## 按需资源与辅助进程生命周期（2026-10-28）

- 用户要求：功能仅在实际使用时占用对应资源。关闭功能必须停止该功能的任务、定时器、监听、事件 tap、采集、编码和连接，并释放可重建的缓存；隐藏窗口不能被误当成功能关闭。
- 专属辅助进程须按需启动，关闭所属功能后正常退出；不能仅把 CPU 降为接近零却永久驻留。共享辅助进程按实际使用者/租约计数，最后一个使用者结束后退出。注册安装状态与进程运行状态应分离，避免每次使用反复索要管理员授权。
- 显示控制与电源辅助进程须先完成屏幕拓扑/原始电源状态恢复并确认，再退出；恢复未完成时只保留必要恢复工作，并明确失败，不能通过 kill 绕过安全事务。快速关闭再开启、崩溃恢复和延迟回调不得误停新会话。
- launchd 的 RunAtLoad/KeepAlive 必须有实际必要性；无活动租约的辅助服务应支持按需启动及安全空闲退出，防止退出后又被无条件拉起。
- FinderSync、系统自动填充等由 macOS 托管的扩展，必须在关闭功能时停止自身工作并释放资源；不得为移除进程而重启系统宿主、强杀系统进程或重置用户权限。不可保证进程消失时，应说明系统控制边界。
- 生命周期验证必须覆盖：关闭后后台工作计数归零、缓存释放、专属进程正常退出/不重启、快速重开、恢复失败、旧回调隔离。测试应使用 mock，不在用户会话中真实锁屏、黑屏、休眠或改变电源策略。
