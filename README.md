# MacPilot

[简体中文](README.zh-CN.md)

A native macOS menu-bar app that helps you manage distracting apps automatically. Each app can have independent rules to:

- hide after a period of inactivity;
- close its closable windows after inactivity while leaving its process running;
- quit after a period of inactivity;
- quit after it has been hidden for a period of time.

It can also launch selected apps after a per-app delay following login. Each launch rule can bring the app to the foreground, hide it, or wait through a 10-second startup grace period before closing its windows while keeping its background process alive. Launch rules use seconds, show a live countdown, skip apps that are already running, and run automatically only when MacPilot is configured to start at login.

Rules, launch plans, and preferences persist in `~/Library/Application Support/MacPilot/config.json`. This file is independent from the app bundle, so updating or replacing `MacPilot.app` preserves your configuration. On first launch, MacPilot automatically migrates compatible configuration from the previous version without modifying the original file. You can also see and reveal the exact path in Settings.

You can pick a running app or browse for an `.app` bundle, reorder rules, pause enforcement globally, and choose Start at Login from the menu-bar menu.

## BLE Unlock

MacPilot can also lock and unlock your Mac by proximity of a Bluetooth Low Energy device - an iPhone, Apple Watch, or any BLE device that periodically advertises from a **static MAC address**.

Open **BLE Unlock** from the sidebar (or the menu-bar menu) and:

- Scan for nearby devices and pick yours. Devices are shown with name, resolved MAC address, and live RSSI.
- Set **Unlock RSSI** (unlock when the device is close) and **Lock RSSI** (lock when it moves away). Either can be disabled independently.
- Set a **Delay to Lock** (grace period before locking when the device leaves) and a **No-Signal Timeout** (lock when signal is lost).
- Optionally: wake the display on proximity, wake without unlocking, pause "Now Playing" while locked, use the screen saver to lock, turn off the screen on lock, or switch to **Passive Mode** to avoid interfering with other Bluetooth devices.
- Use **Lock Screen Now** to lock immediately; it unlocks once the device leaves and returns.
- Your login password is stored securely in **Keychain** and is only used to type it on the lock screen. Set or update it with **Set Password…**.

Bluetooth and Accessibility access are required. Devices whose BLE MAC address rotates (most non-Apple devices) cannot be tracked reliably.

## Input Source Automation

The **Input Sources** sidebar brings the core Input Source Pro workflow into MacPilot:

- Enumerate and select macOS keyboard input sources with Carbon, then switch automatically by application or browser domain/URL rules.
- Show an on-screen indicator near the cursor or in the center of the screen, and cycle sources from the menu bar.
- Force English punctuation and switch between standard function keys and media keys per application.
- Use `⌥⌘I` as the global cycle shortcut, or record custom combinations for individual input sources. Accessibility access is required in other apps; settings are persisted with the rest of `config.json`.

This feature is an independent implementation using macOS Carbon, Accessibility, Core Graphics, and IOKit APIs; it does not bundle Input Source Pro source code or third-party dependencies.

## Screenshot Capture

The **Screenshot** sidebar adds Snapzy-style capture and quick actions to MacPilot:

- Press the global shortcut (default `F1`) to enter smart-element capture. The selector highlights the element under the pointer after a short debounce, and keeps the highlight stable while moving between elements.
- Area, application window, fullscreen, current window, area + annotate, OCR, scrolling screenshot, and object-cutout entry points are also available from the Screenshot settings page.
- Area and application-window selections remain in a PixPin-style editing state with eight resize handles, a size badge, and a floating toolbar; move or resize the selection before copying, saving, annotating, running OCR, pinning, or cancelling.
- After capture, MacPilot can copy the image to the clipboard, show a quick-access preview card, pin it on screen, run OCR, open the annotation editor, or reveal the file in Finder.
- Screenshot shortcuts are configurable in Settings and can be edited per entry point.

Any feature can be toggled on or off from its Settings page. Disabled features do not register global shortcuts, do not start background monitoring or scheduled work, and disappear from the menu-bar menu. For example, turning off **Enable screenshot capture** removes the screenshot entry from the top menu entirely and stops all screenshot-related idle resources.

## Storage Compression

The **Storage Compression** sidebar scans a folder for stable text-based files and uses macOS filesystem compression to reduce their physical disk usage without changing their logical contents. Choose extensions, a minimum file size, a stability period, and a minimum savings threshold; then scan and compress manually or enable a five-minute periodic scan.

MacPilot verifies every compressed copy with SHA-256 before atomically replacing the original. It preserves visible dates and filesystem metadata through macOS `ditto`, skips packages, hidden folders, symbolic links, hard links, sparse files, and cloud placeholders, and only operates on APFS or HFS+ volumes. Compressed files remain directly readable by normal applications and can be restored from the same screen.

## Picture-in-Picture

The **Picture-in-Picture** sidebar uses ScreenCaptureKit to capture an individual window and show it as a live floating panel across Spaces:

- The default global shortcut is `⌥⌘P` (configurable in the Picture-in-Picture settings); add `Shift` to select a region, or double-click with the modifier keys to capture a quick area around the pointer.
- Panels keep the source aspect ratio, support resizing, ⌘-dragging a region to zoom into it, scroll-wheel zooming, ⌘-scroll panning, `+/-` zoom, and fullscreen Spaces.
- Auto-hide, click-to-focus, double-click-to-focus-and-close, Backspace/Esc close, Space QuickLook, media play/pause, and arrow-key seeking are supported.
- Media controls use the source app's real Now Playing session for play/pause, five-second seeking, progress display, and YouTube captions.
- Configure 1–60 fps, 0–100% contrast enhancement, multi-window mode, hover hints, corner radius, and per-app idle/change/sensitive detection. Detection scripts receive `PIPIRI_EVENT`, `PIPIRI_APP`, `PIPIRI_BUNDLE_ID`, and `PIPIRI_WINDOW_ID`.
- Off-screen rendering fixes can relaunch Chromium/Electron apps with their supported background-rendering flag. Firefox, Floorp, kitty, Ghostty, iTerm2, and explicitly selected custom-compositor apps can instead be patched after confirmation; MacPilot creates a complete backup, supports restoration and administrator authorization, watches patched bundles with FSEvents to reapply after updates, and automatically restores after repeated fast crashes.
- Picture-in-Picture settings are persisted with the rest of the app configuration in `~/Library/Application Support/MacPilot/config.json`.

The first capture requires Screen Recording access in **System Settings → Privacy & Security → Screen Recording**. To intercept the global shortcut while another app is active, also grant MacPilot **Accessibility** access; without it, the in-app fallback can observe the shortcut but cannot suppress the original keystroke. Custom-compositor patching never runs silently: the target app must be quit, the user must confirm the modification, and its original bundle remains restorable from MacPilot's Application Support directory.

## Smooth Scrolling

The **Smooth Scrolling** sidebar makes mouse-wheel scrolling feel more like a
trackpad by rewriting wheel events into interpolated, continuous scroll frames.
It is derived from the scrolling pipeline of
[Mos](https://github.com/Caldis/Mos) under its CC BY-NC 4.0 license.

- Enable smooth vertical/horizontal scrolling independently, or pass one axis
  through untouched while the other is smoothed.
- Reverse vertical/horizontal wheel direction independently.
- Adjust the minimum wheel step, speed gain, glide duration, and dead zone.
- Optionally simulate trackpad scroll/momentum phases for apps that rely on them.
- Settings are persisted with the rest of `config.json`; Accessibility access is
  required because MacPilot must read and rewrite wheel events in other apps.

## Build the app

```sh
./Scripts/build-app.sh
open MacPilot.app
```

The built app is `MacPilot.app` in the project root. The Close Windows action requires Accessibility access in System Settings, and selecting that mode immediately triggers the system permission prompt. Whether a target app removes its Dock icon after its windows close is controlled by that app.

When a Developer ID identity is available, release builds and local builds use the same explicit designated requirement (bundle identifier and Apple trust chain). The requirement deliberately does not include the signing certificate's Team ID, because the local Apple Development and release Developer ID certificates may belong to different teams on a development Mac. A local build automatically uses the installed Apple Development identity; if no stable identity is available, the script warns and falls back to ad-hoc signing. The first build after migrating from an older ad-hoc/default-signed app may need permissions granted once again; subsequent development and release builds can share the same Screen Recording and Accessibility authorization.

If MacPilot remains untrusted after an update even though it is enabled in the Accessibility list, toggling the switch may leave the old signing record in place. The permission alert offers **Reset Permission and Quit**, which runs `tccutil reset Accessibility com.misswell.macpilot` for you and exits MacPilot. Reopen the app and grant access again. Runtime rules check access silently and do not repeatedly request it in the background.

## Distribution

If no stable signing identity is installed, local builds fall back to ad-hoc signing. To produce a distributable, notarized build you need an Apple Developer account and a Developer ID Application certificate.

### Prerequisites

1. A **Developer ID Application** certificate (create it in the Apple Developer portal, then import its `.p12` into your keychain).
2. An **app-specific password** for notarization (appleid.apple.com → Sign-In and Security → App-Specific Passwords).
3. Your **Team ID** (10 characters, from the Developer portal).

### Local distribution

```sh
export MACPILOT_DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
export MACPILOT_APPLE_ID="you@example.com"
export MACPILOT_APPLE_PASSWORD="app-specific-password"
export MACPILOT_TEAM_ID="TEAMID"
./Scripts/distribute-app.sh
```

This builds, signs with Developer ID + Hardened Runtime, submits to Apple for notarization, staples the ticket, and produces `MacPilot.app` + `MacPilot-<version>-macos.zip` that open without Gatekeeper warnings.

### Bridge release for the rename

Before the first release with the new Bundle ID, publish one bridge release using the old app identity. The bridge keeps `OctoPilot.app`, `com.misswell.octopilot`, and the `OctoPilot-<version>-macos.zip` archive name, while its visible app name is `MacPilot`:

```sh
MACPILOT_BRIDGE=1 \
MACPILOT_VERSION=1.1.20 \
MACPILOT_OUTPUT_DIR="$PWD/bridge-artifacts" \
./Scripts/distribute-app.sh
```

Publish that archive without renaming it. Older OctoPilot versions can update to this bridge, and the bridge can then validate and install a later MacPilot release. When that automatic transition starts from an existing `OctoPilot.app`, the updater replaces the bundle in place, so the filesystem path may keep its old filename even though the installed Bundle ID and visible name are `MacPilot`. Use `./Scripts/build-app.sh` for local testing; the script applies the same shared designated requirement used by distribution builds.

### GitHub Releases

Pushing a tag like `v1.1.0` runs the `dist` job, which signs and notarizes automatically. The one-time bridge tag `v1.1.20` publishes the legacy `OctoPilot.app` identity; later tags publish the normal `MacPilot.app` identity. Configure these repository secrets:

- `APPLE_CERTIFICATE_P12` — base64-encoded `.p12` of your Developer ID Application certificate
- `APPLE_CERTIFICATE_PASSWORD` — password for that `.p12`
- `APPLE_DEVELOPER_ID` — `Developer ID Application: Your Name (TEAMID)`
- `APPLE_ID` — your Apple ID
- `APPLE_APP_SPECIFIC_PASSWORD` — app-specific password
- `APPLE_TEAM_ID` — your Team ID

## GitHub Actions

The macOS workflow builds, packages, verifies, and uploads the app on pushes to `main` and pull requests. Each commit after the latest version tag automatically increments the patch version: commits after `v1.0.0` build as `1.0.1`, `1.0.2`, and so on. A new tag becomes the next version baseline.

Branch builds use `MACPILOT_ALLOW_UNSTABLE_SIGNING=1` so ordinary pushes can complete without requiring release certificates. Pushing a version tag such as `v1.1.0` runs the `dist` job, which imports the Developer ID certificate, signs with Hardened Runtime, notarizes with Apple, staples the ticket, verifies the signature, and creates a GitHub Release with a zipped `MacPilot.app` archive.

## Renaming and migration

MacPilot uses bundle identifier `com.misswell.macpilot`. It reads compatible configuration from the former `OctoPilot` and `OctoQuit` support directories, and migrates an existing BLE unlock password from the former Keychain service without exposing it. macOS Accessibility, Bluetooth, Screen Recording, and login-item permissions are tied to the app identity, so existing installations must grant those permissions again after the identity change.

Before publishing the first release with the new bundle identifier and `MacPilot.app` bundle name, publish one bridge release that still has the old identity. Older OctoPilot releases cannot validate a new Bundle ID or archive layout, while the bridge updater can validate both names.
