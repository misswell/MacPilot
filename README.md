# MacPilot

[简体中文](README.zh-CN.md)

MacPilot is a native macOS menu-bar toolkit for everyday automation, window management, screen capture, and system utilities. Enable only the tools you need; disabled features stop their own shortcuts and background monitoring.

## Features

### App automation and control

- **App rules:** Set inactivity rules per app to hide it, close its windows while keeping the app running, or quit it. Apps can also quit after remaining hidden.
- **Scheduled launch:** Start selected apps after login with an individual delay. Choose whether each app opens in front, stays hidden, or closes its windows after startup.
- **Awake:** Keep your Mac awake in a session, or start one automatically based on app, process, power, or display conditions. Battery safeguards can end sessions when needed.
- **Closed-lid operation:** Keeping a MacBook awake with its lid closed requires approval for MacPilot’s background power service.
- **BLE Unlock:** Lock or unlock your Mac based on the proximity of Bluetooth Low Energy devices. Set separate lock and unlock thresholds, delays, and behavior. Devices need a stable Bluetooth address for reliable tracking.
- **iPhone Remote:** Pair the companion iPhone app once to lock, turn off the display, unlock, or wake and unlock your Mac over the same local network. Your Mac login password stays on the Mac.

### Input and window navigation

- **Input Sources:** Switch keyboard input sources automatically by app or browser website. Set punctuation and function-key behavior per app, and use a visual indicator or keyboard shortcut to switch manually.
- **Window Switcher:** Use Option-Tab to cycle through windows across apps, with optional titles, previews, and support for hidden or minimized windows.
- **Smooth Scrolling:** Make mouse-wheel input feel more like continuous trackpad scrolling, with controls for direction, speed, and app-specific exclusions.

### Screen capture and focus

- **Screenshots:** Capture interface elements, windows, areas, or the full screen. Annotate images, recognize text with OCR, capture scrolling pages, and pin captures above other windows.
- **Screen Recording:** Record a screen, window, or selected area with optional system audio, microphone, camera, and iPhone or iPad capture.
- **Picture-in-Picture:** Keep a live view of a window or selected region in a floating panel across Spaces, with zoom and media controls.

### Everyday tools

- **Clipboard History:** Search recent copied text, images, links, and files; pin useful entries and paste them again when needed.
- **Finder Context Menu:** Add configurable Finder actions such as copying paths, opening items with an app, using Terminal, managing file visibility, creating files, and opening common folders.
- **Dock Groups:** Keep related apps together in groups that open from the macOS Dock. Select an app to bring it forward or launch it.

### System tools

- **Memory and CPU Monitors:** See per-app memory or CPU use, with related processes grouped together.
- **Local Ports:** Find listening network services, identify their projects and processes, and stop eligible services you launched.
- **Storage Compression:** Reduce the disk space used by stable text-based files with macOS filesystem compression. Files remain readable by normal apps and can be restored.

## Permissions and settings

MacPilot requires macOS 14 or later. Accessibility is needed for cross-app actions and shortcuts; Screen Recording is needed for capture and window previews.

Bluetooth is needed for BLE Unlock, and microphone access is needed when recording microphone audio. The Awake closed-lid option requires approval for its background power service.

Rules and preferences are stored in your user account and remain available after app updates. The BLE login password is stored in the macOS Keychain.

## Download

Download the latest notarized release from [GitHub Releases](https://github.com/misswell/MacPilot/releases/latest). Choose **Apple Silicon (arm64)** for Apple silicon Macs or **Intel (x86_64)** for Intel Macs.
