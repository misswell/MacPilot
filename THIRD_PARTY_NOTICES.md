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

