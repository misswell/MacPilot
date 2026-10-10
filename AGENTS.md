# Repository Guidelines

Contributor guide for **MacPilot**, a native macOS menu-bar app (Swift 6, SwiftPM, macOS 14+) with 18 independently switchable feature modules: app inactivity rules, scheduled launch, Awake keep-awake, BLE proximity lock/unlock, iPhone remote control, capture/screenshot tooling, dock groups, local ports, and more.

## Project Structure & Module Organization

- `Sources/MacPilot/` — main executable target, one subdirectory per feature cluster (`Awake/`, `BLE/`, `DockGroups/`, `RemoteControl/` (remote server), `InputCore/` (remote input injection), `SnapzyCapture/`, `SmoothScrolling/`, …) plus `MacPilotApp.swift` (core), `BLEUnlock.swift` (proximity lock/unlock), and `SoftwareUpdate.swift` (release checks, validation, and update orchestration).
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
- Dock Groups share one model via `MacPilotDockGroupsCore`: the main app writes config, the helper reads it, tests verify integrity. Every group's helper app reuses a single binary, differentiated only by bundle ID, icon, and name — never touch third-party apps outside that shared model.
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
- User-facing strings live in `Resources/RemoteText.swift`; keep `.simplifiedChinese` and `.english` entries in sync (same rule as `AppText`).
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

- `docs/REMOTE_CONTROL.md` is the protocol + feature spec. Read it before touching the remote channel: frame tag `0x03`, binary `RemoteInputBatchCodec` (event kinds 1 move / 2 click / 3 scroll / 4 press / 5-7 pressBegin-pressUpdate-pressEnd), capability bits `realtimeInput` / `inputPressure` / `inputPressureStream`.
- Wire-compat rule: every new event kind must be gated by a capability bit. Old Macs must keep decoding batches — the phone downgrades press events (stream → one-shot graded press → plain click) based on what the Mac advertises in the server hello.
- The iOS press recognizer is the only place pressure intent may live: `Engine/` holds `PressureIntentEngine` (mode config + weighted score), `TouchHistory`, `PressGestureRecognizer`, `PressureSample`, `PressureScore`, `PressureCurve`, `PressState`, `PressureDebugInfo`. Forbidden: single absolute-radius or duration-only thresholds, scoring in views, fixed waits that delay clicks, per-sample update spam (throttle ≥0.03 pressure delta). Each touch is its own adaptive baseline; travel past 12 px cancels a press; the optimistic click keeps ordinary taps instant.
- Mac injection: `RemoteInputCoordinator` routes events; simulated pressure rides `kCGMouseEventPressure` only on the CGEvent path (the virtual HID report has no force field — there the press degrades to its button bits). macOS 26 denies `IOHIDUserDeviceCreate` to ordinary processes, so the CGEvent fallback is the shipping behavior; scrolling always uses `ScrollInjector`.

## Testing Guidelines

- Framework: **Swift Testing** (`import Testing`; `@Test`, `#expect`, `#require`). Suites are `struct`s of `@testable import MacPilot` functions.
- Name tests as sentences describing the invariant. Use `UserDefaults(suiteName:)` with a UUID for stateful tests and clean up via `defer`.
- Run `swift test` before pushing.
- Tests must not lock, blank, or sleep the user's screen, or inject real login keystrokes. Use isolated/mocked screen-control operations for automated tests; never run hardware screen-control tests in the user's session. If the full suite invokes real screen control, stop it and verify the safe relevant suites instead, reporting the limitation. Real screen-state acceptance requires the user's explicit authorization and an isolated AgentSpace session when available.
- Power/display-state behavior (Awake, closed-lid sleep) can't be fully automated: follow the scenarios in `docs/AWAKE_MANUAL_TESTS.md` when changing it. Memory/resource acceptance thresholds live in `Tests/Performance/README.md` and `docs/MEMORY_REVIEW.md`.
- Known full-suite flakes (timing; pass with `--filter` in isolation — do not chase them): `CPUMonitorTests.samplerReportsAFullyBusyCoreAtItsRealShare`, `BLEWakeRecoveryTests.overdueSignalTimeoutClearsThePreSleepPresence`, `ScreenCaptureTests.startupShortcutRegistrationRetriesTransientFailure`, `ScreenCaptureTests.quickCopyAutoSaveWritesFileAndRecordsStats`. New failures outside this list are real.
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
- App Store submission: `asc review submit --app 6811335132 --version <ver> --build <build-id> --confirm` (attach + submit). Release version strings must be **higher than the live App Store version** (1.2.1 is live as verified through ASC on 2026-10-09; 1.2.2 is the next train). Apple rejected a new 1.2.1 upload with 90186/90062 after that train closed; do not reuse a closed train for TestFlight uploads. iPad-capable binaries require iPad Pro 12.9"/13" screenshots: capture on an iPad Pro simulator (`xcrun simctl io <sim> screenshot`, 2064×2752 is accepted) and upload with `asc screenshots upload --device-type IPAD_PRO_3GEN_129`.
- Canonical App Store metadata lives in `iOS/MacPilotRemote/metadata/` (`version/<ver>/<locale>.json`, including `whatsNew`; en-US and zh-Hans both required). Apply with `asc metadata push --app 6811335132 --version <ver> --platform IOS --dir metadata`.

## PilotNest App Store signing gate

- Before every PilotNest upload, read and complete `docs/APP_STORE_RELEASE_CHECKLIST.md`. Build 20 (1.2.0) failed Apple's binary validation with ITMS-90161, Invalid Provisioning Profile / Missing code-signing certificate; this was not an App Review content rejection.
- Validate the exact final exported IPA: distribution signature, matching signer certificate in the embedded profile, profile validity, bundle/team identity, and App Store entitlements. A development-signed archive alone does not prove that the exported IPA is invalid; never diagnose a failed build using another build's archive.
- Keep the existing Xcode automatic signing + `app-store-connect` export flow unless a separately validated manual distribution flow is needed. Never treat an ASC API key or app-specific password as a signing certificate, or pin an old provisioning-profile UUID without revalidating it.
- Upload success is not completion: wait for the exact build to reach VALID, verify the attached build, then submit review. VALID and WAITING_FOR_REVIEW do not mean Apple has approved the app.

## Remote desktop touch behavior

- PilotNest remote desktop uses one continuous relative mouse trackpad across the video and lower content area, both with the keyboard shown and hidden. Never map video touches to absolute screen coordinates. A two-finger pinch on the preview only changes local video zoom; other gestures keep relative mouse semantics. Keep buttons and the system keyboard interactive above the touch surface.
