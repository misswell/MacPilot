# Third-party notices

## Snapzy

MacPilot's screenshot implementation directly migrates the capture source from
[Snapzy](https://github.com/duongductrong/Snapzy) (commit `417c8e0`,
`v1.31.0-beta.18`). The migrated files live under
`Sources/MacPilot/SnapzyCapture/` and retain the upstream type and pipeline
structure; MacPilot-specific changes are limited to localization, permission,
and storage seams.
Snapzy is distributed under the BSD 3-Clause License, copyright (c) 2026,
Trong Duong Duc. The applicable license text follows.

This notice does not change MacPilot's license. It identifies the upstream
source used for the single-frame ScreenCaptureKit session, frozen display
snapshots, multi-display crop/composition, and area-selection overlay.

```text
BSD 3-Clause License

Copyright (c) 2026, Trong Duong Duc

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## Mos (Smooth Scrolling)

MacPilot's *Smooth Scrolling* feature is a non-commercial adaptation of the
scrolling pipeline from [Mos](https://github.com/Caldis/Mos) (commit
`5f93f4704fc86734198ccf907b1a607fc38706df`, master). The migrated ideas and
derived code live under `Sources/MacPilot/SmoothScrolling/`:

- wheel-event parsing and direction/smoothing decisions (`SmoothScrollCore.swift`),
- minimum-step normalization, speed gain and duration curve,
- frame filter and scroll phase state machine,
- CGEvent tap + CVDisplayLink interpolation + `CGEventPostToPid` delivery.

Mos is copyright (c) 2017-2026 Caldis, licensed under
[CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/). Changes made
by MacPilot are limited to the global settings surface, AppKit/SwiftUI
integration, configuration storage, and dropping Mos' buttons/Logi/update
modules. Use of this Mos-derived portion must stay non-commercial.

## RClick Finder context menu (GPLv3)

MacPilot incorporates and adapts source code from
[wflixu/RClick](https://github.com/wflixu/RClick), upstream commit
`cd9a7efc5b886ec9e2fcb62f53b440665455dadf`. The integrated source is located
under `Sources/MacPilotRightClickKit/` and `FinderSync/`; the FinderSync
extension is built from the corresponding-source script at
`Scripts/build-findersync.sh`.

RClick is copyright its original authors and is licensed under the GNU General
Public License, version 3. The upstream license text is available at
<https://github.com/wflixu/RClick/blob/cd9a7efc5b886ec9e2fcb62f53b440665455dadf/LICENSE>.
Changes in this integration include the MacPilot bundle identifiers, App Group,
IPC names, FinderSync packaging, and the MacPilot settings surface.

## Maccy clipboard manager (MIT)

MacPilot's clipboard history feature adapts source code from
[p0deje/Maccy](https://github.com/p0deje/Maccy). The adapted files live under
`Sources/MacPilot/Clipboard/` and retain the upstream architecture for
pasteboard monitoring (`Clipboard.swift`), history dedup/limits
(`Observables/History.swift`, `Storage.swift`), item models
(`Models/HistoryItem.swift`, `Models/HistoryItemContent.swift`), the floating
panel (`FloatingPanel.swift`, `Views/`), and pasteboard type handling
(`Extensions/NSPasteboard.PasteboardType+Types.swift`).

Maccy is copyright its original authors and is licensed under the MIT License.
The upstream license text is available at
<https://github.com/p0deje/Maccy/blob/master/LICENSE>.

Adaptations for MacPilot: Codable JSON storage in
`~/Library/Application Support/MacPilot/ClipboardHistory.json` instead of
SwiftData, no external SPM dependencies (Sauce, Defaults, KeyboardShortcuts,
Settings, Fuse were dropped), a Carbon global hotkey reusing MacPilot's
`SmartCaptureShortcutBinding`, ⌘V paste via CGEvent, and the MacPilot sidebar
settings surface with Chinese/English localization.

## QuickRecorder screen recording engine (AGPL-3.0)

MacPilot's screen recording engine is adapted from
[lihaoyun6/QuickRecorder](https://github.com/lihaoyun6/QuickRecorder), upstream
commit `e820517` (2025-06-11). The adapted source lives under
`Sources/MacPilot/QuickRecorder/QuickRecorderRecordingEngine.swift` and powers
`ScreenRecordingModel` through the engine's prepare/start/pause/resume/stop
lifecycle. The following parts are derived from QuickRecorder and reworked for
MacPilot's settings model, localization, and Swift 6 concurrency rules:

- stream filter construction: desktop-independent window capture for the
  application-window mode and hiding MacPilot's own windows in every mode
  (`RecordEngine.prepRecord`, `SCContext.getSelfWindows`),
- video writer setup: H.264/HEVC codec choice, the resolution-aware target
  bitrate formula, and BT.709 color properties (`RecordEngine.initVideo`),
- microphone capture: AVAudioEngine input tap with optional voice-processing
  echo cancellation, the PCM-to-CMSampleBuffer conversion, and input device
  sample-rate discovery (`RecordEngine.startMicRecording`,
  `SCContext.getSampleRate`),
- audio writer settings including the reduced bitrate for low-rate devices
  (`SCContext.updateAudioSettings`),
- idle-display-sleep prevention while recording (`Supports/SleepPreventer.swift`).

Pause handling keeps MacPilot's accumulated-pause presentation timestamp
retiming instead of QuickRecorder's time-offset variant. MacPilot-specific
additions are the settings persistence (`capturesMicrophone`,
`microphoneEchoCancellation`, `encoder`), the microphone permission flow, and
the recording UI card.

QuickRecorder is copyright (C) 2024 lihaoyun6 and licensed under the GNU
Affero General Public License, version 3. The upstream license text is
available at
<https://github.com/lihaoyun6/QuickRecorder/blob/main/LICENSE>. Because this
code is combined into the MacPilot work, MacPilot's distributed builds that
include the QuickRecorder-derived engine are made available under AGPL-3.0
with respect to that combined work; the upstream source of the adapted engine
is this repository.
