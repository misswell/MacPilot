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

MacPilot can also lock and unlock your Mac by proximity of up to two Bluetooth Low Energy devices - an iPhone, Apple Watch, or any BLE device that periodically advertises from a **static MAC address**.

Open **BLE Unlock** from the sidebar (or the menu-bar menu) and:

- Scan for nearby devices and pick yours. Devices are shown with name, resolved MAC address, and live RSSI.
- Add an optional second device and choose whether **either device** or **both devices** must be nearby to keep the Mac unlocked.
- Set **Unlock RSSI** (unlock when the device is close) and **Lock RSSI** (lock when it moves away). Either can be disabled independently.
- Set a **Delay to Lock** (grace period before locking when the device leaves) and a **No-Signal Timeout** (lock when signal is lost).
- Optionally: wake the display on proximity, wake without unlocking, pause "Now Playing" while locked, use the screen saver to lock, turn off the screen on lock, or switch to **Passive Mode** to avoid interfering with other Bluetooth devices.
- Use **Lock Screen Now** to lock immediately; it unlocks once the device leaves and returns.
- Review recent lock and unlock events in the built-in screen-lock history.
- Your login password is stored securely in **Keychain** and is only used to type it on the lock screen. Set or update it with **Set Password…**.

Bluetooth and Accessibility access are required. Devices whose BLE MAC address rotates (most non-Apple devices) cannot be tracked reliably.

## Input Source Automation

The **Input Sources** sidebar brings the core Input Source Pro workflow into MacPilot:

- Enumerate and select macOS keyboard input sources with Carbon, then switch automatically by application or browser domain/URL rules.
- Show an on-screen indicator near the cursor or in the center of the screen, and cycle sources from the menu bar.
- Force English punctuation and switch between standard function keys and media keys per application.
- Use `⌥⌘I` as the global cycle shortcut, or record custom combinations for individual input sources. Accessibility access is required in other apps; settings are persisted with the rest of `config.json`.

This feature is an independent implementation using macOS Carbon, Accessibility, Core Graphics, and IOKit APIs; it does not bundle Input Source Pro source code or third-party dependencies.

## Clipboard History

Clipboard History keeps recent copied content available from a searchable panel:

- Press `⌘⇧V` to open it, then use search, arrow keys, Return, or number/letter shortcuts to paste or copy an item.
- Pin important items, remove individual entries, clear unpinned history, and configure the history limit.
- Text, images, URLs, and other supported pasteboard content are deduplicated and persisted across launches.

## Window Switcher

The **Window Switcher** provides fast keyboard navigation across application windows:

- Press `⌥Tab` to open it, hold Option to keep cycling, use Shift for reverse order, and release Option to focus the selected window; Escape cancels.
- Show application icons, window titles, and optional previews; include minimized or hidden windows when needed.
- Merge multiple windows from selected applications into one switcher card without changing the applications' actual windows.

## Screenshot Capture

The **Screenshot** sidebar adds Snapzy-style capture and quick actions to MacPilot:

- Press the global shortcut (default `F1`) to enter smart-element capture. The selector highlights the element under the pointer after a short debounce, and keeps the highlight stable while moving between elements.
- Area, application window, fullscreen, current window, area + annotate, OCR, scrolling screenshot, and object-cutout entry points are also available from the Screenshot settings page.
- Area and application-window selections remain in a PixPin-style editing state with eight resize handles, a size badge, and a floating toolbar; move or resize the selection before copying, saving, annotating, running OCR, pinning, or cancelling.
- Annotate directly on the current capture with shapes, arrows, lines, pencil/highlighter strokes, blur, spotlight, counters, text, watermarks, and crop; adjust line width and opacity with the toolbar or mouse wheel.
- After capture, MacPilot can copy the image to the clipboard, show a quick-access preview card, pin it on screen, run OCR, open the annotation editor, upload it manually to GitHub or Gitee, or reveal the file in Finder.
- Explicit image uploads show progress and success/error feedback, then copy the public image URL to the clipboard.
- Screenshot shortcuts are configurable in Settings and can be edited per entry point.

Any feature can be toggled on or off from its Settings page. Disabled features do not register global shortcuts, do not start background monitoring or scheduled work, and disappear from the menu-bar menu. For example, turning off **Enable screenshot capture** removes the screenshot entry from the top menu entirely and stops all screenshot-related idle resources.

## Finder Context Menu

MacPilot includes a Finder Sync extension that adds configurable actions to Finder's context menu:

- **Copy Path** copies the paths of selected files and folders.
- Open selected items with configured applications.
- Open a terminal, delete items directly, hide or unhide items, and send items with AirDrop.
- Create configured file types from Finder's blank-area menu and open configured common directories.
- Enable, disable, and reorder actions, applications, new-file types, and common directories independently.

## Performance and Resource Usage

MacPilot is built with native Swift/SwiftUI and macOS system APIs, without a bundled cross-platform runtime. Its long-lived data paths are designed to keep memory bounded:

- Clipboard images and content larger than 64 KB are stored as files under Application Support. The history model keeps only type, filename, and size metadata, and reads the content on demand.
- Screenshot copies use a file-backed, lazy pasteboard provider. PNG data is generated only when another app requests it, then released after the request.
- Window-switcher previews are downscaled to at most 256×160 pixels, prefetch at most 30 windows, and are pruned when the window inventory changes. Disabling thumbnails cancels capture work and clears the thumbnail cache.
- Quick Access shows at most five cards at once; dismissing an item releases its associated panel and annotation session resources.
- Disabled features do not keep global event taps, monitors, timers, or scheduled work running. Diagnostic file I/O runs on a utility queue and log data is retained for one hour.

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

- Enable smooth vertical/horizontal scrolling independently, or pass one axis
  through untouched while the other is smoothed.
- Reverse vertical/horizontal wheel direction independently.
- Adjust the minimum wheel step, speed gain, glide duration, and dead zone.
- Optionally accelerate more the faster the wheel is rotated, with a
  configurable acceleration limit.
- Optionally simulate trackpad scroll/momentum phases for apps that rely on them.
- Exclude selected applications from smoothing; their original mouse-wheel
  events pass through without interpolation, with an independent direction
  reversal switch for each app. Apps can be selected while running or browsed
  from disk.
- Settings are persisted with the rest of `config.json`; Accessibility access is
  required because MacPilot must read and rewrite wheel events in other apps.

## Permissions and Configuration

MacPilot stores rules and preferences in `~/Library/Application Support/MacPilot/config.json`. Updating the app preserves this file, and compatible settings are migrated automatically.

- **Accessibility** is needed for global keyboard shortcuts, window switching, input-source automation, smooth scrolling, BLE screen control, and actions that operate in other apps.
- **Screen Recording** is needed for screenshots, window previews, and Picture-in-Picture capture. If it is unavailable, window previews fall back to application icons.
- **Bluetooth** is needed for BLE Unlock. The login password is stored in the macOS Keychain and is never written to the configuration file.
- Features can be disabled independently; disabled features stop their event monitors, timers, scheduled work, and other runtime resources.

If MacPilot remains untrusted after an update even though it is enabled in the Accessibility list, toggle the permission off and on again. The permission alert also provides **Reset Permission and Quit** to refresh the Accessibility authorization before reopening the app.

## Download

Download the latest notarized release from [GitHub Releases](https://github.com/misswell/MacPilot/releases/latest). Choose the **Apple Silicon (arm64)** package for Apple silicon Macs or the **Intel (x86_64)** package for Intel Macs.
