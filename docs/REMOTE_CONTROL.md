# MacPilot Remote Control (iPhone → Mac)

MacPilot can be locked, blanked, unlocked and woken from an iPhone on the same
local network. This document describes the design, the wire protocol and the
security model, and how to build the companion iOS app.

## Goals and non-goals

| Goal | How |
| --- | --- |
| Automatic local discovery, optional direct address | Bonjour (`_macpilot._tcp`) plus remembered addresses; Devices → Add Mac by IP / hostname for routed networks |
| No re-pairing | A long lived pairing key in the Keychain on both sides; only the very first connection shows a 6 digit code |
| Fast connect (< 500 ms typical) | Bonjour, the remembered address and Bluetooth are dialled at the same time; the first authenticated link is usable immediately and higher-priority links can take over |
| No IP scanning, no UDP broadcast, no HTTP | `NWBrowser` + `NWListener` on `NWParameters.tcp` |
| The Mac login password never leaves the Mac | The protocol has no password field; unlocking happens locally through `MacScreenControlService` |

Version 1 needs no relay server, no account and no public API: the phone reaches
the Mac over the local network, peer-to-peer Wi-Fi (AWDL) or Bluetooth.

## Layers

```
Packages/MacPilotRemoteProtocol/     shared, used verbatim by both sides
    RemoteProtocolVersion.swift      version, service type, port, frame limits
    RemoteCommand.swift              command + capability enums
    RemoteModels.swift               request/response/handshake structs
    RemoteFrameCodec.swift           length prefixed framing, plain/secure codecs
    RemoteCrypto.swift               HKDF, ChaChaPoly, proofs, replay guard
    RemotePairing.swift              P-256 ECDH exchange, pairing code rules
    RemoteDiscovery.swift            Bonjour TXT record encode/decode

Sources/MacPilot/ScreenControl/      screen control primitives (shared with BLE Unlock)
Sources/MacPilot/RemoteControl/      the Mac server
iOS/MacPilotRemote/                  the iPhone app
```

The protocol types live in one SwiftPM package that both the Mac app and the
iOS app depend on, so the two ends cannot drift apart.

## Screen control refactor

`Sources/MacPilot/ScreenControl/` holds everything that actually touches the
screen, extracted from `BLEUnlock.swift`:

- `MacScreenControlService` — `lockScreen`, `sleepDisplay`, `wakeDisplay`,
  `unlock`, `wakeAndUnlock`, `currentState`. Every call takes a
  `ScreenControlSource` (`.localManual`, `.bleAutomatic`, `.remoteExplicit`) and
  returns a `ScreenControlResult`.
  On an unlocked Mac, display-off blanks the panels without forcing an
  immediate lock. It does not hold its own display-sleep assertion: normal
  idle display sleep and the system's lock policy still apply. Awake can still
  prevent idle sleep explicitly. Backlight writes are read back; an unconfirmed
  monitor power-off falls back to a black cover rather than claiming the panel
  is physically off. Partial blanking without coverage of every display fails
  and restores the panels already changed.
- `ScreenCredentialStore` — the login password, in the Keychain, behind a
  `SecretStore` protocol so tests use an in-memory implementation instead of
  prompting for Keychain access.
- `ScreenUnlockExecutor` — the ⌃⌘Q lock shortcut, display power, and the key
  event injection used to unlock.
- `ScreenLockState` / `ScreenLockStateResolver` — lock state derived from
  `CGSession`.

The BLE feature keeps its own policy (RSSI thresholds, presence timers, the
`[2, 5, 9, 14, 20]` second unlock retry schedule, lock history). Remote control
uses the same primitives with a faster `[0.35, 0.8, 1.5, 2.5, 4]` second
schedule.

`MacScreenControlService.willLock` / `didUnlock` keep BLE's `manualLock` and
"suppress automatic unlock" state correct when the remote path is used: a remote
lock suppresses BLE auto-unlock, while a remote explicit unlock still works.

The legacy names `BLEScreenLockState`, `BLEScreenLockStateResolver` and
`bleLockScreenViaShortcut()` remain as typealiases/wrappers so existing tests and
call sites are untouched.

## Wire format

App Store phone versions 1.0/1.1 decode handshake capabilities as a closed
enum containing only `lock`, `displayOff`, `wake`, and `unlock`. Adding an
unknown case breaks the whole handshake even while protocol version remains 1.
For a client hello without `features`, the Mac sends only those four cases.
New clients declare supported capability strings in `features`; the Mac filters
its typed hello through `RemoteCapability.negotiated`. The first feature-aware
1.2 clients declared only `remoteDesktop`, which also proves they understand the
three input cases. Bonjour TXT capabilities remain extensible strings: old
discovery code ignores unknown values. Regression tests freeze the published
phone enum and exercise hello, authentication, and encrypted state retrieval.

The server hello includes an ephemeral pairing public key even when the Mac
remembers the client. A phone that lost its local key can then send the existing
`pairRequest` message. A remembered key is replaced only after the user opens
the Mac pairing window and confirms its six digit code; ordinary authentication
continues to use the saved key without starting a pairing exchange.

Every message is preceded by a 4 byte big endian length. The first body byte
selects the encoding:

```
plaintext handshake:  0x01 || UTF-8 JSON (RemoteHandshakeMessage)
sealed command:       0x02 || UInt64 BE sequence || ChaChaPoly combined box
realtime input:       0x03 || UInt64 BE sequence || ChaChaPoly combined box
```

The ChaChaPoly nonce is derived from the sequence: 4 zero bytes followed by the
sequence as a big endian `UInt64`. The additional authenticated data is the
`0x02` tag. Frames larger than `RemoteProtocolVersion.maximumFrameSize`
(256 KiB) are rejected.

## Realtime input channel (the trackpad)

Cursor motion runs at up to 120 Hz, so it never travels as JSON commands. It
rides frame tag `0x03`: the sealed plaintext is a binary `RemoteInputBatch`
(codec in `RemoteInputPacket.swift`), not a `RemoteRequest`:

```
header:  u8  version (1) | u8 reserved | u16 BE event count | u64 BE timestamp ms
events:  move   u8 kind=1 | i16 dx | i16 dy | u8 buttons    (0.1 px fixed point)
         click  u8 kind=2 | u8 button | u8 action
         scroll u8 kind=3 | i16 dx | i16 dy                (0.1 px fixed point)
```

Rules that make the channel safe:

- **Capability gated.** The Mac advertises `realtimeInput` in its Bonjour TXT
  record and in `serverHello` `capabilities`. The iPhone only opens the channel
  when the session's Mac advertised it, so an old Mac never sees a `0x03` frame.
- **Explicitly armed.** `beginRealtimeInput` / `endRealtimeInput` are ordinary
  authenticated commands that arm the per-connection session; `begin` doubles as
  the Accessibility gate (synthesizing mouse events requires trust) and fails
  with `.accessibilityPermissionRequired` otherwise. Batches from an unarmed
  connection are dropped.
- **No response.** Input frames are fire and forget. A stale or undecodable one
  is dropped, not treated as a protocol failure — pointer motion is exactly the
  traffic that is safe to lose. Clicks are never dropped by the sender.
- **Moves coalesce.** The iPhone merges consecutive same-button moves into the
  newest one before flushing, so a slow link shows fresh position, not a laggy
  replay of old deltas.
- **Relative deltas only.** The wire carries finger deltas, never screen
  coordinates — Retina scaling, resolution changes and multi-display Macs stay
  the window server's problem.
- **Same crypto, same sequence space.** `0x03` frames use the session key and
  the same strictly-increasing per-connection sequence counter as `0x02`
  frames, and the replay guard validates both identically.

Injection lives on the Mac in `Sources/MacPilot/InputCore/`:
`RemoteInputCoordinator` (arming + dispatch) → `VirtualHIDDevice` /
`MouseInjector` (relative deltas, drags as left-button drag events) and
`ScrollInjector` (continuous pixel scrolling via the `scrollWheelEvent2`
constructor). The iPhone side lives under
`iOS/MacPilotRemote/MacPilotRemote/Features/RemoteTrackpad/` (touch surface →
`GestureEngine` → velocity/acceleration → binary batch).

### Phone keyboard for Mac text fields

Every trackpad tap stays a normal click, so it focuses the control beneath the
pointer — the same deal as clicking a field with a real mouse. Right after the
click, a Mac that advertised `remoteTextInputAvailable` receives
`beginTextInput` over the authenticated `0x02` command channel (the phone
waits a beat first so the click's focus has landed). The Mac hit-tests the
current pointer position with Accessibility, walks up to an enabled editable
text field, text area, or editable combo box, focuses it, and retains that
element for this connection. Only an accepted request opens the native iPhone
keyboard; a rejected request is a tap that landed off text, and the click has
already gone out, so nothing is replayed. An older Mac never receives this new
command and every tap just stays a click.

Committed iPhone text is sent as `textInput` operations (`insert`,
`deleteBackward`, `returnKey`) on the encrypted command channel. IME marked
text stays on the phone until the user commits it. Insertions are divided into
at most 256 UTF-16 units per operation, so long paste operations can pass the
protocol limit. The Mac rechecks that the pinned element is still focused
before every operation, then posts Unicode keyboard events or Backspace/Return
key events. If focus changes, input stops and the phone dismisses its keyboard.
Dismissal and leaving the trackpad send `endTextInput`; disconnect also clears
the Mac's per-connection target. This feature needs the Mac's Accessibility
grant. Custom controls that do not expose a standard editable Accessibility
role or do not accept Unicode keyboard events may not support remote typing.
Focus is resolved through the foreground application's Accessibility object,
because Electron apps can fail the system-wide focused-element query. If a
WebView hit-test returns a surrounding container instead of its editable child,
the already-focused editable field can be used only when it belongs to the
hit-tested process and its screen bounds contain the pointer. Clicking outside
that field cannot reopen the keyboard through this fallback. Focused text
descendants are normalized to their editable ancestor before each operation.
The trackpad's keyboard button is visible when keyboard control is enabled
in the phone's settings (disabled while disconnected).
It opens or dismisses the keyboard. Opening sends the existing focused-mode
`beginTextInput` payload `0x01` over any authenticated, armed input connection,
including Bluetooth; no video session is required. This explicit typing intent
can bind a custom editor without a standard editable AX role, while automatic
tap probes still require one. Each operation must still match the pinned
foreground focus. Older Macs may reject the explicit request or use their
existing pointer-based detection, without any new command or frame format.
While the phone keyboard is open, a trackpad click rechecks the pointer's Mac
Accessibility target after sending the click. Clicking ordinary content closes
the phone keyboard; clicking another editable field keeps it open and binds
typing to the new field.

### Injection paths: virtual HID device vs CGEvent

The coordinator prefers the device-level path: `VirtualHIDDevice` creates a
user-space HID pointing device (`IOHIDUserDeviceCreate`) and posts 7-byte HID
reports, so motion and clicks reach the window server as genuine device input
— macOS's own pointer acceleration applies, and no Accessibility grant is
needed. When armed over that path, the Mac reports
`realtimeInputSystemAcceleration = yes` and the phone sends raw finger deltas;
over the CGEvent fallback the phone keeps its own acceleration curve.

Reality check (verified on macOS 26): recent macOS denies
`IOHIDUserDeviceCreate` to ordinary processes — the gate is the private
`com.apple.private.hid.system.user-access-service` entitlement, which is not
available to Developer ID apps. On those systems creation fails once, the
coordinator logs `virtual HID device failed`/path=`cgEvent` and every session
rides the CGEvent path (which still requires the Accessibility grant, and the
begin response reports `realtimeInputSystemAcceleration = no`). On older
releases where creation succeeds, the device path arms without the grant —
scrolling stays on `ScrollInjector` either way, because a stepped wheel
report cannot match continuous-event glide quality.

A full Magic Trackpad emulation (multitouch digitizer frames feeding the
system gesture engine) remains out of reach: Apple's multitouch report format
is undocumented, and a half-formed multitouch device would degrade rather
than improve the experience.

### Simulated pressure

Optional, off by default (`PressureMode`: off/light/standard/strong). The
phone runs a per-finger press recognizer over the touch samples: contact
growth (relative to the touch's own baseline), hold duration, stillness and
travel fold into a 0…1 score (`areaGrowth·0.45 + duration·0.25 +
stability·0.2 − movement·0.1`). Travel past 12 px cancels the press outright
— a moving finger is a cursor, never a press.

The click stays optimistic: a quick tap releases before any press decision
and remains the plain click pair it always was, so ordinary tapping never
waits. Only a touch whose score crosses the mode's bar while still on the
glass actuates early — the button goes down exactly like a physical trackpad
click, the pressure grades as the contact deepens, and the release lands when
the finger lifts. A resting finger keeps a flat radius and never presses.

On the wire the press is a continuous process, gated by capabilities so every
version pairing degrades cleanly:

- `.inputPressureStream` (kind 5 `pressBegin: button|pressure`, kind 6
  `pressUpdate: pressure`, kind 7 `pressEnd: button`) — the button actuates
  while the finger is down and the grade streams along;
- `.inputPressure` (kind 4 `press: button|action|pressure`) — one-shot graded
  press for Macs that predate the stream;
- neither — plain clicks, and the feature is invisible.

The Mac applies the grade via `kCGMouseEventPressure` on the injected down
event and zero-delta drag updates; only the CGEvent path carries the grade
(the virtual HID report has no force field, where the press degrades to its
button bits). While the mode is `off` no recognizer exists anywhere and
behavior is byte-for-byte the trackpad of previous releases. iPads have no
Taptic engine, so press feedback plays a synthesized trackpad click instead
of buzzing.

## Media keys and phone control preferences

The Mac advertises `mediaControl` only to clients that declare that feature.
`mediaPrevious`, `mediaPlayPause`, and `mediaNext` use the authenticated command
channel and dispatch a system media-key down/up pair. They require Accessibility
permission and control the Mac's active media app, like a keyboard's media keys.
A successful response acknowledges event dispatch; it does not claim that a
player has started or stopped. The play/pause button therefore always shows the
combined icon without a visible caption; its full VoiceOver label remains. Do
not infer playback state from button presses. A future reliable state source
may show the state-specific icon and text, but unknown state must remain icon-only.
Phones connected to older Macs disable the keys
and show an update hint without sending unfamiliar command values.

PilotNest Settings → Control features provides individual switches for remote
screen, trackpad, keyboard, all four screen actions, all three media keys,
brightness, volume, and mute. They default to visible and persist on the phone
across launches and Mac switches. The native settings list supports long-press
drag reordering across categories, with permanent reorder handles. Order is
stored separately from visibility; hidden controls retain their positions and
new controls are appended in their default order. Unknown visibility/order keys
survive downgrades. Keyboard off also suppresses automatic editable-field probes;
its position does not create a separate home entry. Volume and mute can be shown
and ordered independently. The home screen keeps the Mac switcher first, then
renders visible controls in the saved order, grouping only adjacent controls of
the same kind into a card. Screen
key content is centered in equal-height, Dynamic Type-scaled keys; single-line
captions do not reserve an invisible second line. Input, screen, media, and mute
keys reuse the same surfaces and press feedback, and all groups share one
adaptive card background, 16-point radius, and subtle border. Media
keys share one Touch Bar with adaptive grouped surfaces and the same accent as
the surrounding controls. Subtle key shading and press feedback retain its
tactile appearance in light and dark mode and respect Reduce Motion.
Brightness/volume use compact inline sliders;
unknown levels show an unavailable indicator rather than a guessed zero. The
560-point content limit keeps iPad layouts compact. Larger text uses extra rows
and scrolling; default-size controls fit even an iPhone SE portrait viewport.
Empty groups are omitted, and a Settings shortcut remains when all home controls
are hidden.

## Dock groups (launch a work set from the phone)

Three authenticated commands let the phone open a Dock group's apps on the
Mac without touching it:

```
getDockGroups        no payload → RemoteDockGroupsSnapshot payload
launchDockGroup      RemoteDockGroupLaunchRequest{groupID} → snapshot payload
launchDockGroupApp   RemoteDockGroupLaunchRequest{groupID, appID} → snapshot payload
```

- **Capability gated.** The Mac advertises `dockGroups` in the Bonjour TXT
  record and in `serverHello` only when the feature is wired in, and the
  router answers `unsupportedCommand` when the feature is switched off —
  The phone homepage no longer presents Dock groups or fetches their snapshot
  on connection. The protocol and Mac handlers remain for compatible peers.
- **One launch path.** The router calls `DockGroupsRemoteHost`, which wraps
  `DockGroupsModel` and launches through the same `AppLaunchService` the Dock
  helper uses (running members are activated, never duplicated). The phone
  can therefore do nothing the Mac's own UI could not.
- **Snapshot answers.** Launch replies carry the refreshed group list, so one
  round trip updates the rows; members that could not be resolved or launched
  ride along as `missingApps` names instead of failing the whole command.

## Handshake

### Already paired

```
iPhone                                              Mac
  |-- clientHello {clientID, clientName, ----------->|
  |                clientNonce, version}             |
  |<-- serverHello {deviceID, deviceName, -----------|
  |                 serverNonce, paired: true}       |
  |-- authRequest {clientNonce, proof} ------------->|   proof = HMAC(pairingKey, "client" || n_c || n_s)
  |<-- authResult {proof} ---------------------------|   proof = HMAC(pairingKey, "server" || n_c || n_s)
  |============== sealed command channel ============|
```

Two round trips, and the iPhone verifies the Mac's proof before sending anything
sensitive.

### First time

```
iPhone                                              Mac
  |-- clientHello --------------------------------->|
  |<-- serverHello {paired: false, publicKey} -------|   ephemeral P-256
  |-- pairRequest {publicKey} ---------------------->|   ephemeral P-256
  |                                                   |   Mac derives the shared
  |                                                   |   secret and shows a
  |                                                   |   6 digit code
  |<-- pairResult {} --------------------------------|
  |        (user types the code shown on the Mac)     |
  |-- pairConfirm {pairCode} ----------------------->|
  |                                                   |   Mac stores the pairing key
  |<-- pairResult {proof} ---------------------------|
  |============== sealed command channel ============|
```

The pairing key and the displayed code are both derived from the ECDH shared
secret with HKDF and different `info` strings; a transcript hash is mixed into
the salt so the two sides agree on the exact exchange. The code is a
confirmation value only — knowing it does not reveal the long lived key.

`pairRequest` is refused with `.pairingRequired` unless the Mac has the pairing
window open. The window is opened manually from **Remote Control → Start
pairing** and lasts 120 seconds.

## Security properties

- **The Mac login password is never transmitted.** There is no field for it in
  any message, and the iPhone never asks the user for it. Unlocking runs on the
  Mac: `RemoteCommandRouter` → `MacScreenControlService.unlock` →
  `ScreenCredentialStore` → `CGEvent`.
- **Mutual authentication.** Each side proves possession of the pairing key with
  an HKDF derived proof over both nonces. Comparisons are constant time.
- **Forward secrecy is not claimed.** Session keys come from the long lived
  pairing key plus fresh nonces, so a compromised pairing key decrypts recorded
  sessions. Pairing keys are per iPhone and can be revoked from either side.
- **Replay protection.** Sequences must strictly increase and the request
  timestamp must be within 300 seconds of the Mac's clock; anything else is
  dropped and logged.
- **Key storage.** Pairing keys use
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and never sync to iCloud.
- **Logging.** Logs record the command name, the result and latency. Passwords,
  pairing keys, session keys and message bodies are never logged.

## Connection race

Every way the phone can reach the Mac is dialled at the same time, and the first
link to finish the authenticated handshake becomes the session:

| Path | Address | Why it is in the race |
| --- | --- | --- |
| Bonjour | The `_macpilot._tcp` result advertised right now | Correct immediately, but costs an mDNS resolve |
| Remembered | The host and port that worked last time | Instant when it is still valid, a dead end when the Mac moved |
| Bluetooth | An L2CAP channel the Mac opens to the phone | The only path that needs no shared network at all |

Each candidate is a complete connection — its own transport, framing, handshake
and session key — so a slow path can never hold up a fast one. Settings stores a
user-sortable physical-link priority, defaulting to LAN → AWDL → Bluetooth.
Bonjour results retain their interfaces: LAN candidates exclude peer-to-peer,
and AWDL candidates bind to the discovered AWDL interface. Remembered addresses
are additional candidates for their physical path. The first authenticated link
is promoted immediately. Higher-priority candidates keep running; once authenticated,
they replace the current session. Equal/lower-priority candidates are closed and
cannot preempt it. Failed upgrades never interrupt the usable session. Higher-priority
paths retry while foregrounded, including interfaces discovered after connecting.
Changing the order applies immediately and is persisted on the phone. Switching
also re-arms trackpad input and restarts remote video on the new session.
Candidates expire independently: LAN dials retry after 4 seconds, while AWDL
dials get 30 seconds for peer discovery and radio setup. Retrying LAN does not
cancel an AWDL dial. A handshake gets 15 seconds starting when its transport
becomes ready, rather than from the beginning of radio setup. The same policy
applies to upgrades without closing the active link. When no fresh AWDL browse
result exists, the saved Bonjour service name is also resolved with peer-to-peer
enabled; a stale link-local address is no longer the only recovery path. This
unbound service may resolve over LAN, so promotion uses the actual link rather
than labeling every peer-enabled connection as AWDL.

Bluetooth takes part from the first attempt instead of waiting for the network to
fail. That is what makes it useful — establishing the link takes seconds, so
starting it late means arriving late — and the cost is a radio advertisement for
as long as the app is open and disconnected. It stops the moment any link carries
a session, unless Bluetooth still ranks above that session. An active Bluetooth
stream keeps its peripheral alive until a higher-priority connection replaces it.

**A first pairing is deliberately not raced.** The Mac displays exactly one
confirmation code, and two concurrent pair requests would each derive their own,
so the user could end up reading the code for the link that is about to be
discarded. Until a long term key exists the phone dials a single path; once the
key is in the Keychain the proof is computed per connection and racing is safe.
A Bluetooth channel that arrives while a first pairing is already in flight on
the network is declined and closed.

**Settings → Connection link** shows the paths being dialled right now, the link
that won, and the full connection log — including the paths that lost, which is
the only way to tell "it picked the slower link" from "it had no choice".

## Performance

- **Fast path.** The iPhone still stores the host and port it last reached the Mac
  on, but a stale one no longer blocks startup: it is one candidate among several,
  so a fresh Bonjour result connects as soon as it resolves rather than waiting for
  the stale attempt to time out.
- **Persistent connection.** Commands reuse one link; there is no
  connect-per-action cost.
- **Keep alive.** A `ping` every 15 seconds confirms the link and reports the
  round trip time.
- **Reconnect.** After a drop the client restarts the race at 0.25, 0.5, 1, 1.5,
  2, 3 and then 5 second intervals. It disconnects deliberately when the app
  backgrounds and reconnects when it returns.
- **Instrumentation.** Discovery, transport connect, handshake, round trip and
  command execution latencies are measured on the iPhone and shown under
  **Settings → Connection performance**. The Mac logs
  `handshake complete event=... latency=...ms`.

### Trackpad latency measurements

The trackpad sends coalesced UIKit touch samples immediately after each touch
callback; the 120 Hz task keeps inertial scrolling running between callbacks.
Both TCP endpoints disable Nagle, and the existing connection race includes
peer-to-peer Wi-Fi when Bonjour can resolve it. The input packets remain binary
and use the authenticated realtime frame; command traffic stays on its existing
channel. BLE L2CAP stream diagnostics aggregate byte counts every two seconds
instead of dispatching one main-thread log update per read or write. No new
pairing or transport path is required.

The iPhone's `Trackpad` log reports `touchToSendAvgMs` and
`touchToSendMaxMs` over two-second windows. The Mac's `RemoteInput` log reports
`receiveToInjectAvgMs`, `receiveToInjectMaxMs`, and `injectAvgMs` over the same
sampling interval. The existing phone connection performance view reports RTT
and the selected interface. These measurements are *segments*, not a claimed
touch-to-visible-cursor total: phone and Mac monotonic clocks have different
origins, and neither event posting nor a successful HID report proves the
display has painted the new cursor. Measure the actual visible response with
an external high-speed camera when comparing against a millisecond target.

For regression checks, move continuously for 30 minutes, drag across windows,
alternate rapid clicks with motion, switch Wi-Fi paths, and background/restore
the phone. Watch the sampled maximum as well as the average, because a short
main-thread stall can be more noticeable than the steady-state cost. The input
path deliberately avoids exponential cursor smoothing: a heavy smoothing
factor would reduce jitter at the cost of visible lag. macOS supplies pointer
acceleration on the virtual HID path; the phone's velocity curve is used only
for the CGEvent fallback. Click feedback runs after the outgoing batch is sent.

## Mac setup

The same steps are shown inside the iPhone app under **Settings → Before you
start**, so a user who installs only the phone app learns that the Mac app is a
prerequisite. That section is purely instructional: the phone cannot install or
launch anything on the Mac, and MacPilot exposes no `macpilot://remote-control`
deep link to jump to, so it links to the download page instead.

1. Open **Remote Control** in the MacPilot sidebar and enable iPhone remote
   control.
2. Grant Accessibility permission (needed for the lock shortcut and key events)
   if it is not already granted.
3. Set the unlock password on the Remote Control page if it is not already
   saved. Remote Control and BLE Unlock share the same Mac Keychain credential,
   so either page shows it as configured after saving it on the other. BLE
   Unlock does not need to be enabled. Without a saved password, unlock commands
   return `.credentialNotConfigured`.
4. Click **Start pairing** to open the 120 second pairing window.
5. In the iPhone app, open **Devices**, tap the discovered Mac, and type the code
   shown on the Mac.

The Mac listens on `_macpilot._tcp` and prefers port 43847, falling back to a
dynamic port if that one is taken. macOS asks for Local Network permission the
first time; both sides need it.

After pairing more than one Mac, the iPhone's **Control** screen has a Mac
switcher above the remote actions. It shows each paired Mac's connection state
and remembers the selected Mac for the next launch. If that Mac goes offline,
the phone keeps trying it rather than silently controlling another nearby Mac.

## Building the iOS app

Simulator build:

```sh
cd iOS/MacPilotRemote
xcodegen generate
xcodebuild -scheme MacPilotRemote -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' -configuration Debug build
```

Device build (signed, installable on a real iPhone):

```sh
xcodebuild -scheme MacPilotRemote -sdk iphoneos \
  -destination 'generic/platform=iOS' -configuration Debug build
```

`project.yml` references the shared package with a relative path, so
`Packages/MacPilotRemoteProtocol` must stay in the repository. It also pins
`CODE_SIGN_STYLE: Automatic` and `DEVELOPMENT_TEAM: U8U443D7ZL`, which matches
the Apple Development and Apple Distribution identities installed in the login
keychain, so device builds sign without extra flags. Change the team there if you
build under a different Apple developer account.

### App icon

The icon lives in `MacPilotRemote/Resources/Assets.xcassets/AppIcon.appiconset/`
as `AppIcon-1024.png`, the one size iOS needs. `project.yml` picks the catalog up
automatically because it sits inside the target's `sources` folder, so adding it
does not need a project.yml change.

The master artwork is `Artwork/AppIconSource.png`. It is a padded squircle, while
iOS wants a full-bleed opaque square that it masks itself, so
`Scripts/generate-app-icon.py` copies just the cyan/violet mark out of the master
and repaints the rest with the squircle's own fill colour. Re-run it after
replacing the master:

```sh
cd iOS/MacPilotRemote
python3 Scripts/generate-app-icon.py   # requires Pillow
```

## Tests

- `Packages/MacPilotRemoteProtocol/Tests/MacPilotRemoteProtocolTests/` covers
  framing (including a regression test for sliced `Data` indices), the secure
  codec, the replay guard, pairing code rules, proof agreement and TXT records.
- `Tests/MacPilotTests/RemoteControlTests.swift` covers the screen control
  models, the command router, configuration coding, the pairing window and the
  paired device store.

Keychain backed types are tested through the in-memory `SecretStore`, so the test
process never triggers a Keychain access prompt.

## Remote desktop mode

PilotNest’s Remote control entry combines an independent encrypted H.264 screen
channel with the existing trackpad and keyboard. LAN/AWDL carry video; Bluetooth
keeps input only. See [the implementation and validation report](REMOTE_DESKTOP.md)
for the video wire format, lifecycle, compatibility gates and measurement limits.

## Direct addresses and Tailscale

In PilotNest, open Devices → Add Mac by IP / hostname and enter the Mac's
Tailscale IP or MagicDNS hostname and TCP port (normally 43847). Both devices
must have Tailscale enabled and the tailnet policy and Mac firewall must allow
access. Bonjour discovery does not traverse the tailnet. The Mac must be awake
and MacPilot Remote Control enabled; Tailscale does not wake a sleeping host.

Direct connections use the existing authenticated handshake and pairing code.
The server identity is learned from that handshake, and the address is saved
only after authentication succeeds. The manually entered hostname and port are
stored separately from the last resolved address, so LAN connections do not
overwrite the routed endpoint. Subsequent connections race this endpoint with
existing paths and check the saved Mac identity. Re-enter an address to change
it; forgetting the Mac removes its saved addresses and pairing key.

Remote desktop video opens an additional dynamically assigned TCP port on the
same Mac; policies allowing only TCP 43847 permit control but can block video.
Allow the video connection as well when using remote desktop. Real-device
acceptance: pair via Tailscale, move the phone to cellular, reconnect, test
trackpad and video, then connect over LAN and confirm the manual address still
works after returning to cellular. Test both direct and relayed tailnet paths.

## Authenticated BLE UUID aliases

BLE Unlock can explicitly associate each selected logical device with one
already-paired Remote Control client. Names, model strings and network reachability
are not identity evidence. Each association pins the pairing-key fingerprint;
removing the pairing or replacing its key revokes the learned UUID aliases.
The original selected UUID remains for configuration/downgrade compatibility.

The Mac learns a UUID only after the existing nonce-bound mutual authentication
succeeds on a BLE L2CAP connection. Its source is the local central's
`CBPeripheral.identifier`, attached to that exact channel before authentication,
never a UUID supplied by the phone. Authentication alone does not mark the BLE
device present or unlock: the normal fresh RSSI thresholds, timeouts and manual
lock suppression still apply.

The negotiated `bleIdentityLearning` capability is sent only to a feature-aware
phone whose authenticated pairing is explicitly associated with BLE Unlock.
An updated PilotNest can briefly keep its BLE advertisement/authentication probe
alive after the preferred LAN/AWDL session wins, without promoting the probe or
interrupting the active network session. Old peers retain their existing behavior.
An old PilotNest still learns aliases whenever its normal BLE remote connection
authenticates successfully; the new capability is not required on that path.
An updated PilotNest talking to an older Mac simply skips the optional probe.
Neither learning nor successful probing is a prerequisite for remote commands,
network connections or the existing BLE proximity policy.
Probes stop on foreground-window expiry, authentication completion or backgrounding.
No new commands or cryptographic handshake are introduced.

At most eight learned aliases are retained per logical device, evicting the
least-recently authenticated alias. Duplicate observations update metadata at
most once per minute. UUIDs cannot belong to multiple logical devices. Within a
logical device, original UUID and aliases are OR alternatives; primary/secondary
devices retain their existing ANY/ALL relationship. The settings UI shows the
learned list and allows clearing it without deleting the original device.

This repairs authenticated UUID association, not iOS background availability.
PilotNest still closes its peripheral service when backgrounded; an alias learned
in the foreground is not a guarantee of advertisement or connection availability
while the iPhone is locked. Automated acceptance must use isolated pure/mocked
logic, never lock, blank or sleep the user's real screen.
