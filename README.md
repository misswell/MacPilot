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

## Storage Compression

The **Storage Compression** sidebar scans a folder for stable text-based files and uses macOS filesystem compression to reduce their physical disk usage without changing their logical contents. Choose extensions, a minimum file size, a stability period, and a minimum savings threshold; then scan and compress manually or enable a five-minute periodic scan.

MacPilot verifies every compressed copy with SHA-256 before atomically replacing the original. It preserves visible dates and filesystem metadata through macOS `ditto`, skips packages, hidden folders, symbolic links, hard links, sparse files, and cloud placeholders, and only operates on APFS or HFS+ volumes. Compressed files remain directly readable by normal applications and can be restored from the same screen.

## Build the app

```sh
./Scripts/build-app.sh
open MacPilot.app
```

The built app is `MacPilot.app` in the project root. The Close Windows action requires Accessibility access in System Settings, and selecting that mode immediately triggers the system permission prompt. Whether a target app removes its Dock icon after its windows close is controlled by that app.

Local and GitHub Release builds currently use ad-hoc signing, so each update can have a new code identity and macOS may require Accessibility access to be granted again. Preserving that grant reliably across upgrades requires distributing every version with the same Developer ID signing identity.

If MacPilot remains untrusted after an update even though it is enabled in the Accessibility list, toggling the switch may leave the old signing record in place. The permission alert offers **Reset Permission and Quit**, which runs `tccutil reset Accessibility com.misswell.macpilot` for you and exits MacPilot. Reopen the app and grant access again. Runtime rules check access silently and do not repeatedly request it in the background.

## Distribution

Local builds are signed ad-hoc. To produce a distributable, notarized build you need an Apple Developer account.

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

### GitHub Releases

Pushing a tag like `v1.1.0` runs the `dist` job, which signs and notarizes automatically. Configure these repository secrets:

- `APPLE_CERTIFICATE_P12` — base64-encoded `.p12` of your Developer ID Application certificate
- `APPLE_CERTIFICATE_PASSWORD` — password for that `.p12`
- `APPLE_DEVELOPER_ID` — `Developer ID Application: Your Name (TEAMID)`
- `APPLE_ID` — your Apple ID
- `APPLE_APP_SPECIFIC_PASSWORD` — app-specific password
- `APPLE_TEAM_ID` — your Team ID

## GitHub Actions

The macOS workflow builds, packages, verifies, and uploads the app on pushes to `main` and pull requests. Each commit after the latest version tag automatically increments the patch version: commits after `v1.0.0` build as `1.0.1`, `1.0.2`, and so on. A new tag becomes the next version baseline. Pushing a version tag such as `v1.1.0` also creates a GitHub Release with a zipped `MacPilot.app` archive.

## Renaming and migration

MacPilot uses bundle identifier `com.misswell.macpilot`. It reads compatible configuration from the former `OctoPilot` and `OctoQuit` support directories, and migrates an existing BLE unlock password from the former Keychain service without exposing it. macOS Accessibility, Bluetooth, Screen Recording, and login-item permissions are tied to the app identity, so existing installations must grant those permissions again after the identity change.

Before publishing the first release with the new bundle identifier and `MacPilot.app` bundle name, publish one bridge release that still has the old identity. Older OctoPilot releases cannot validate a new Bundle ID or archive layout, while the bridge updater can validate both names.
