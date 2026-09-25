# MacPilot

[简体中文](README.zh-CN.md)

MacPilot is a native macOS menu-bar toolkit for automation, capture, window navigation, and system utilities. It has 18 independently switchable feature modules. Turn features on from Home; turning one off stops its shortcuts and background monitoring.

Requires macOS 14 or later. The release includes builds for Apple silicon (`arm64`) and Intel (`x86_64`).

## Features

### Automation and control

#### App inactivity rules

- Set an idle timeout for each app and choose whether MacPilot hides the app, closes its windows while leaving the process running, or quits it.
- Add a second timeout to quit an app after it has stayed hidden.
- Import existing Quitter rules from MacPilot Settings.

#### Scheduled app launch

- Start selected apps after login, with a separate delay for each app.
- Choose how each app appears: in front, hidden, or with its windows closed.
- MacPilot's own **Start at Login** setting is separate from these per-app launch rules.

#### Awake

- Start a temporary or unlimited session manually, or start the default session when MacPilot launches or the Mac wakes.
- Start and stop sessions from rules for selected apps or processes, power-adapter and charging state, battery level, external displays, and display mirroring.
- Choose whether a timed session continues counting during system sleep, and set battery safeguards.
- Configure display sleep, system sleep after the display turns off, screen-saver behavior, and closed-lid operation.
- Closed-lid operation requires approval for MacPilot's background power service in System Settings.

#### BLE proximity lock and unlock

- Track configured Bluetooth Low Energy devices and use separate signal thresholds and delays for automatic Mac locking and unlocking.
- Configure proximity wake, optional media pausing, screen-saver use, and display blanking; use passive mode or lock immediately from the menu bar.
- Review tracked devices and screen-lock history. The Mac login password is stored in Keychain. Devices need a stable Bluetooth address for reliable proximity tracking.

#### iPhone remote control

- Pair an iPhone with a short-lived code, then lock the Mac, turn its display off, unlock or wake-and-unlock it, and adjust screen brightness and output volume.
- Connect over the local network, with a direct Bluetooth link available as another transport. Manage paired devices and connection status in Settings.
- The Mac login password remains on the Mac in Keychain; it is not sent to the iPhone.

#### Input Sources

- Switch macOS input sources automatically by app or browser website.
- Set English punctuation and standard-function-key or media-key behavior per app.
- Cycle input sources with a global shortcut, add custom shortcuts, and show a temporary indicator near the pointer or at screen center.

### Window and input tools

#### Window Switcher

- Press `Option-Tab` to cycle through windows across apps; hold Option to keep cycling, use `Shift-Tab` to go back, release Option to focus the selection, or press Escape to cancel.
- Show window titles and previews, and choose whether hidden or minimized windows appear.

#### Smooth Scrolling

- Turn mouse-wheel input into continuous, trackpad-like scrolling.
- Adjust scrolling direction and speed, and exclude apps where the original wheel behavior is preferred.

### Screenshots and recording

#### Screenshots and quick access

- Capture a detected interface element, app window, active window, selected area, or full screen. Choose whether to include all displays and the pointer.
- Use a delay, repeat the previous area, capture a scrolling page, extract a foreground object, or open a selection directly in the annotation toolbar.
- Annotate with shapes, pencil and arrows, text, numbered counters, blur, and spotlight; run OCR and copy recognized text.
- Copy or save captures, keep recent captures in Quick Access, pin images above other windows, and edit or remove items from the stack.
- Review recent screenshot, video, and GIF entries; reveal image files in Finder or remove entries from capture history. Customize Quick Access actions and shortcuts, swipe behavior, and drag items to other apps.
- Set custom shortcuts for capture modes. Choose HEIC, JPEG, or PNG output, image quality, and an output folder.
- Optionally upload screenshots to a configured GitHub or Gitee repository and get an image URL.
- Schedule periodic screenshots with different intervals during busy and idle hours; set the schedule, output format, and retention period.

#### Screen Recording

- Record a selected area, app window, full screen, or audio only. Pause, resume, stop, or cancel a recording; add a countdown or automatic stop time.
- Configure video format, frame rate, H.264 or HEVC encoding, quality, background, cursor, Retina resolution, HDR, and transparent video where supported.
- Record system audio and a selected microphone, adjust audio quality, and optionally keep microphone audio as a separate track.
- Add a camera or supported iPhone/iPad capture device, highlight mouse clicks, and use the recording magnifier.
- Set a preparation bar and floating controller, hide desktop files or Control Center, include or exclude the menu bar and MacPilot, prevent display sleep, and block selected apps from capture.
- Choose an output folder, review a recording, and export the last recording as a GIF with configurable frame rate and width. Recording shortcuts are editable.

#### Picture-in-Picture

- Turn a window or selected screen region into a live floating panel that stays available across Spaces.
- Move and resize the panel, zoom the view, and use media controls where supported.

### Everyday productivity

#### Clipboard History

- Keep a searchable history of copied text, images, links, and files. Set the history limit, pin useful entries, and keep pinned items at the top.
- Open the panel with a configurable shortcut, preview entries, and choose whether selecting an item copies or pastes it. Modifier-clicks provide copy, paste, and paste-without-formatting actions.
- Choose whether clearing history also clears the system clipboard.

#### Finder Context Menu

- Add MacPilot actions to Finder's right-click menu: copy paths, open items with configured apps, use Terminal, and show or hide files.
- Configure apps and actions by file type, create files from editable templates, and add frequently used folders to a Common Folders submenu.
- Enable the Finder extension and grant access to selected folders in macOS settings when prompted.

#### Dock Groups

- Create named groups of apps and add apps by choosing or dragging them into a group.
- Give each group a generated Dock helper with a selectable icon style; add the helper to the Dock to open the group's app panel from the Dock.
- Display apps as a grid or list, show running state, reorder group contents, and launch an app or bring its running window forward.

### System utilities

#### Memory Monitor

- Inspect physical, used, app, wired, compressed, cached, and swap memory, along with memory pressure and system uptime.
- Search apps, expand their related processes, and refresh the per-app readings automatically or on demand.

#### CPU Monitor

- Inspect total, user, system, nice, and idle CPU use, logical core count, and 1-, 5-, and 15-minute load averages.
- Search app and process readings and refresh automatically or on demand.

#### Local Ports

- Scan listening local services and show their ports, owning processes, and whether they are reachable on the LAN.
- Group identifiable project services separately from other processes, search the list, inspect details, and stop eligible services you launched.
- See a compact service summary from the menu bar and open the full port list for details.

#### Storage Compression

- Select folders and file extensions to monitor. Set a minimum file size, how long a file must remain unchanged, and the minimum disk-space savings required.
- Automatically compress eligible stable files or run a scan and review candidates yourself. Inspect compressed files and restore them when needed.
- Uses macOS file-system compression on supported APFS or HFS+ volumes; files remain accessible to normal apps.

## Menu bar and app settings

The menu bar exposes quick actions for active Awake sessions, immediate BLE locking, input-source cycling, the Window Switcher, Clipboard History, Smart Capture, Picture-in-Picture capture, and recording controls. It also provides memory, CPU, and local-port summaries, a display-off action, update status, and a diagnostics panel with MacPilot's current resource use and active background work. Display blanking keeps the current session running and ends on user input; on supported Macs, MacPilot also dims the keyboard backlight and restores its previous setting when the display wakes.

In Settings, enable or disable feature modules, launch MacPilot at login, choose the interface language, inspect or reveal the configuration file, import Quitter rules, and check for or install updates. Automatic update checks can be turned on or off.

## Permissions and local data

Some features need macOS privacy permissions when first used:

- **Accessibility:** cross-app actions, simulated key input, and global shortcuts.
- **Screen Recording:** screenshots, recordings, and window previews.
- **Bluetooth:** BLE proximity features and the remote-control Bluetooth transport.
- **Local Network:** iPhone remote control over the network.
- **Microphone and camera:** recording those sources.
- **Finder extension and folder access:** Finder context-menu actions and selected folders.
- **Background power service:** Awake operation with a closed MacBook lid.

Main app rules and feature settings are stored in `~/Library/Application Support/MacPilot/config.json`; the Finder extension maintains its own menu configuration. The Mac login password and device-pairing credentials are kept in macOS Keychain. Screenshot hosting is optional and uploads to the repository configured by the user.

## Download

Download the latest notarized release from [GitHub Releases](https://github.com/misswell/MacPilot/releases/latest). Choose **Apple Silicon (`arm64`)** for Apple silicon Macs or **Intel (`x86_64`)** for Intel Macs, unzip it, then move MacPilot to Applications before granting privacy permissions.

## Build from source

The project uses Swift 6 and Swift Package Manager. On macOS 14 or later with Xcode command-line tools installed:

```sh
swift build
```

To assemble a local `MacPilot.app` bundle, run:

```sh
./Scripts/build-app.sh
```
