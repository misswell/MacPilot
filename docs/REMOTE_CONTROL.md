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
Sources/MacPilot/Sidecar/            SidecarCore bridge + remote Sidecar service
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
screen, trackpad, keyboard, all four screen actions plus the Sidecar entry, all
three media keys, brightness, volume, mute, and Page Up/Page Down/Home/End. They default to visible and persist on the phone
across launches and Mac switches. The native settings list supports long-press
drag reordering within each section, with permanent reorder handles. The new
Paging & navigation section is appended after the four original sections.
The toolbar's Section order button opens a separate page for whole-section
reordering. Navigation is intentionally outside the permanently editing list:
an in-list NavigationLink is not tappable while that list is in active edit mode.
`ControlSectionOrderUITests` covers the actual Settings → Control features →
Section order tap, plus dragging a navigation key and its section and retaining
both orders after relaunch. Run this class only on an isolated, unpaired simulator;
it never taps remote commands or modifies the Mac's screen state.
Section order, feature
order and visibility are stored independently; hidden controls retain their
positions and new controls are appended in their section's default order. Unknown
visibility/order keys survive downgrades; the previous flat feature order is
migrated to whole sections. Keyboard off also suppresses automatic editable-field
probes; its position does not create a separate home entry. Volume and mute can
be shown independently, but mute is anchored to the volume slider's right edge
and cannot be dragged to a standalone row. The home screen keeps the Mac switcher
first, then renders entire sections and their controls in the saved order. Screen
key content is centered in equal-height, Dynamic Type-scaled keys; single-line
captions do not reserve an invisible second line. Input, screen, media, and navigation
keys reuse the same surfaces and press feedback, and all groups share one
adaptive card background, 16-point radius, and subtle border. Media
keys share one Touch Bar with adaptive grouped surfaces and the same accent as
the surrounding controls. Subtle key shading and press feedback retain its
tactile appearance in light and dark mode and respect Reduce Motion.
Brightness/volume use compact inline sliders. Mute is a plain, icon-only action
at the right of the volume row, with no caption or button chrome; its 44-point
hit target and localized VoiceOver label remain, including at accessibility text sizes;
unknown levels show an unavailable indicator rather than a guessed zero. The
560-point content limit keeps iPad layouts compact. Larger text uses extra rows
and scrolling; additional sections remain reachable by scrolling on small phones.
Empty groups are omitted, and a Settings shortcut remains when all home controls
are hidden.

`navigationKeys` is negotiated only with clients declaring that exact feature.
The authenticated `navigationKey` command carries one byte: 1 Page Up, 2 Page Down,
3 Home, or 4 End. Missing, unknown, and oversized payloads are rejected. The Mac
requires Accessibility permission and dispatches an unmodified key-down/up pair
to the foreground app; apps decide their own navigation behavior. These home
controls do not require opening or arming a remote-desktop session. Old Macs
disable the four keys and show an update hint without receiving unfamiliar
commands. Tests inject an event sink and never post real keyboard events.

When the selected Mac is absent, PilotNest can automatically select another
already-paired Mac only after that Mac remains the sole discovered paired identity
for ten continuous seconds. Multiple visible Macs, candidate disappearance,
pairing/authentication (including a racing connection), or an authenticated live
session to the selected Mac reset the observation window. A Keychain pairing key
is required; automatic selection never starts first-time pairing. Manual device,
address or default selection cancels the pending switch and disables automatic
selection for that foreground-use cycle. Returning from background starts a
fresh ten-second observation; cancelled or old-generation tasks cannot switch
devices later. This selection policy does not send any screen-control commands.

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

## Sidecar (start a native display session from the phone)

Three authenticated commands let the phone ask the **Mac** to bring up or end a
native Sidecar session with one of the Mac's own iPads:

```
getSidecarDevices    no payload → RemoteSidecarSnapshot payload
connectSidecar       RemoteSidecarTargetRequest{deviceID} → snapshot payload
disconnectSidecar    RemoteSidecarTargetRequest{deviceID} → snapshot payload
```

- **Capability gated twice, and it means *buildable*, not *supported*.** `sidecar`
  is advertised in the Bonjour TXT record and in `serverHello` whenever this Mac
  has the Sidecar host wired, and only to a client that declares the feature
  itself. The bit answers "can these three commands be understood and answered
  here?", because that is the only question a phone can act on before asking: a
  Mac whose decoder does not know the raw value drops the connection. Whether the
  machine can drive a display right now is answered per request, and a Mac that
  has the commands but cannot obey them returns `sidecarUnavailable` rather than
  `unsupportedCommand` — `unsupportedCommand` stays reserved for a Mac with no
  Sidecar host at all. Shipped App Store phones decode capabilities as a closed
  enum, so they never see the bit and never send these commands.
- **Hosting hooks are protocol requirements, not extension defaults.** A member a
  protocol does not declare is resolved *statically* inside its own extension, so
  `advertisedCapabilities` reading `sidecarHosting` / `dockGroupsHosting` used to
  see the extension's `nil` on every host — including `RemoteControlServer`, which
  did provide both. That is why a phone never asked about Sidecar on a Mac that had
  the whole feature wired: the bit was withheld by dispatch, not by the machine.
  `Tests/MacPilotTests/SidecarRemoteTests.swift` pins the rule by reading
  `advertisedCapabilities` off a server through `any RemoteConnectionHost`.
- **The home key follows the user, not the Mac.** A control switched on in
  Settings stays on the home page even when the connected Mac never advertised
  Sidecar, and even while the link is down. The earlier rule hid the row, and it
  read as the phone ignoring the user's own settings. The honesty moved inside
  the sheet: `macWithoutSidecar` names the reason instead of showing an endless
  "looking for iPads", and offers no retry for an answer the Mac never gave.
  Capability still decides what leaves the phone — `refreshSidecarDevices` and
  `sendSidecarTarget` both return before the wire without the advertisement, and
  the poll timer is never armed for such a Mac — and since the bit now means
  "these commands are answered", a Mac that has the feature is never silenced by
  it. **Nothing on the phone is switched on for the user, though:** mirroring a
  whole iPad is opt-in, like the four navigation keys —
  `RemoteControlFeature.isEnabledByDefault` is false for `.sidecar`, so a fresh
  install shows no Sidecar row until the user opens Settings › Control features ›
  Screen. The opt-in is mirrored into the historical `remoteControl.hiddenFeatures`
  key in both directions, so a downgrade to a release that only reads that key
  keeps honouring the same choice.
- **The Mac owns the session.** `SidecarService` drives the private framework
  through the same code path the system's own UI uses; the phone is a remote
  controller only. MacPilot captures no screen, encodes no video and opens no
  AirPlay session of its own — the pixels are entirely Apple's Sidecar.
- **Accepted, then verified.** Bringing up a session outlasts the phone's RPC
  timeout, so a connect replies *accepted* immediately and its outcome travels
  as `RemoteSidecarSnapshot.operation.phase` (`connecting` / `disconnecting` /
  `failed`). The phone polls only while the sheet is open: once a second during
  an operation, every three seconds when idle, and never once it is closed or
  the link drops.
- **No timer on the Mac.** The service keeps no watchdog of its own: a deadline
  travels on the operation record and is settled when the state is next read — by
  a poll, by the next target request, or by the framework call returning. The
  phone already asks once a second while the sheet is open, so a second loop here
  would only be a second thing to get wrong.
- **Connected means the system says so.** Neither a completion block without an
  error nor the fact that we asked is proof: every verdict is re-read from the
  framework's `connectedDevices` before the phone is told anything, including
  before a timeout is reported, so a session that did come up is never
  announced as a failure.
- **One operation at a time.** A second target request while one is live is
  refused with `sidecarOperationInProgress`, and the phone blocks its rows for
  the same reason. Switching iPads ends the current session inside the same
  operation (the phone asks for confirmation first); if that teardown fails,
  the running session is left alone and no connect is attempted.
- **Failures explain the last attempt, not a permanent state.** The framework's
  error is mapped to a stable code — `sidecarUnavailable`,
  `sidecarDeviceNotFound`, `sidecarAlreadyConnected`,
  `sidecarDeviceUnreachable` (Wi-Fi off, asleep or locked),
  `sidecarConnectFailed`, `sidecarDisconnectFailed` — and never leaks a system
  message to the wire. Once the system state contradicts a failed attempt (the
  user connected from the Mac, or the session ended on its own) the stale
  verdict is cleared instead of being reported on every poll.
- **No private symbol is assumed.** `SidecarCore` ships no module map and
  promises no stability, so `SidecarCoreRuntime` resolves the handle, both
  classes and every selector at runtime; anything missing degrades to
  `.unsupported`. `dlopen` happens on the first question about Sidecar rather
  than at launch — a Mac with remote control switched off never pays for it —
  and the manager singleton is created only when a device list is actually asked
  for, because creating it starts the framework talking to Rapport: advertising
  the capability in a Bonjour record must not cost that. Selectors were verified
  on macOS 27.0.1 (26A434); **this is not a
  compatibility claim for other macOS releases**, and the private framework is
  the reason this feature cannot ship in a Mac App Store build.
- **The completion block escapes.** `connectToDevice:completion:` answers on the
  framework's own queue, so the `@convention(c)` signature the IMP is cast to has
  to declare its block parameter `@escaping`. Without that Swift hands over a
  stack block and the runtime traps with *"closure argument passed as @noescape to
  Objective-C has escaped"* the first time a session is genuinely requested. No
  stub can reproduce it — every test here drives the protocol, not the framework —
  so a change to `SidecarCoreRuntime` is not verified until it has moved a real
  iPad.
- **The support verdict is never cached.** `+isSupported` answers for *right now*,
  and the first question can arrive before SidecarCore's own state has settled, so
  the verdict is re-asked on every read and only the `dlopen` and class lookup are
  retried-until-resolved rather than latched on the first failure.
  **This rule was written against a wrong diagnosis and must not be read as one.**
  A phone that showed no Sidecar entry on a supporting Mac was not meeting a
  transient "no" from the framework: the capability never reached the hello at all
  because of the dispatch bug above. `SidecarCore` documents no reason for a "no",
  so the bridge now logs the load result (with `dlerror()`), each verdict
  *transition*, and the support-shaped selectors `SidecarDisplayManager` actually
  exposes — without those lines a refused Mac is undiagnosable after the fact.
- **The TXT record is a startup snapshot, so it cannot prove what a phone was
  told.** `RemoteControlServer.makeListener` computes `advertisedCapabilities`
  once and bakes it into `NWListener.Service`, which is never republished. A
  missing `sidecar` in `dns-sd -L <name> _macpilot._tcp local.` therefore only
  reports the verdict taken when the listener started — read the `serverHello`,
  which is rebuilt per connection, for what any phone actually received. The
  client-hello log line carries the negotiated `caps=` list for exactly this
  reason; the phone parses TXT capabilities into `DiscoveredMac` but gates its UI
  on the hello, so the stale snapshot has no user-visible effect.

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

Bonjour permission errors also arrive while the browser is `waiting`, without
any discovery results. PilotNest reports DNS-SD `PolicyDenied` (`-65570`) in
that state and updates the permission indicator independently of the Mac list;
`NoAuth` (`-65555`) is not that error. A waiting browser stays alive for recovery.
Manual **Retry** recreates the Bonjour/AWDL browse as well as the connection race,
discarding stale discovered endpoints without deleting the selected Mac or its
pairing key. An allowed Local Network toggle is not proof of a working AWDL
broadcast: macOS can still reject Bonjour registration with `PolicyDenied`.

On the Mac, socket readiness and service publication are separate states.
`RemoteBonjourPublisher` registers the listener's actual port through DNS-SD
with both `IncludeP2P` and `IncludeAWDL`. Only a successful registration Add
callback marks discovery available. This avoids an `NWListener.ready` masking
an internal advertiser's `PolicyDenied`. Registration failures surface on Home
and Remote Control; policy rejection offers the Local Network settings entry and
a user-triggered **Reopen MacPilot** action when the console account matches the
account running MacPilot. Enabling Remote Control opens its
setup page and explains the first-use system permission prompt. A previously
allowed app can also receive a policy error while macOS updates network privacy
rules, so the UI describes the rejected operation rather than assuming the user
disabled permission. That includes the post-update case: a -65570 verdict can
outlive an in-place app replacement until the process is replaced, which is why
the hint says so explicitly rather than calling the toggle wrong.
Failed publication is retried every three seconds until registration succeeds or
the feature stops. The retry replaces only the advertisement, preserving the
listener, authenticated connections, Bluetooth, and paired keys. Success clears
pending network guidance. Recovery never resets permissions, restarts the app
automatically, or re-pairs; the reopen action is only ever taken by the user.

Local Network privacy is keyed to the **console account**, not to the account
running MacPilot. After a fast user switch the two can differ, and a
`DenyMulticast` decision saved for the account in front of the screen decides a
registration attempt made from another account's session. Reopening MacPilot or
toggling Local Network in the session's own settings cannot change that verdict,
so the notice names the console account and withholds both actions in that
state; the user has to allow MacPilot in the console account's settings or log
that account out. Every transition to `permissionDenied` also logs
`consoleUser`, `processUser`, and `consoleMismatch` in the diagnostic log, so
this case is distinguishable from a stale post-update grant. The notice and the
system alert always show the same two labeled sections, **possible problem** and
**how to fix**, tailored to the current state (same-account denial, another
console account, or a transient publication failure), so the interface always
explains both what went wrong and what to do next.

The Bluetooth PSM characteristic is dynamic: it returns the currently published
channel number, and returns no value after that publication is stopped. The Mac
backs off repeated channel-open failures (2/4/8/16/30 seconds) until a channel
opens, rather than continuously disconnecting and rescanning. Error logs include
the error domain and code; this does not remove L2CAP encryption or bypass the
authenticated remote-control handshake. These recovery safeguards are not proof
that an operating-system channel-open error has been resolved on real hardware.

Because `openL2CAPChannel` can fail with `CBErrorDomain/0` even while the PSM
read succeeds, identity learning also has a GATT path. The phone writes an
8-byte random token into its authenticated network session
(`claimBLEIdentity`), publishes the same token on a read-only identity
characteristic on the existing BLE service, and the Mac reads that
characteristic during its next discovery attempt. A constant-time match learns
the local `CBPeripheral.identifier`; the claim is single-use and expires with
the probe window (30 seconds, capped at 120). The new `bleIdentityClaim`
capability is negotiated only with a phone that declares the feature and whose
pairing is explicitly bound to BLE Unlock, so an older phone never receives the
command and an older Mac never advertises it. Reading the token is an ordinary
unencrypted GATT read, exactly like the PSM read; the token is meaningless
without the authenticated session that armed it and is never logged.

iOS rotates the advertised BLE address, and every rotation appears to the Mac as
a new `CBPeripheral.identifier`. The foreground claim cannot cover a phone sitting
in a pocket with PilotNest closed, which is exactly when proximity unlock is
needed. A second GATT characteristic closes that gap: the Mac writes
`version ‖ 16-byte nonce ‖ its raw device UUID`, the phone answers with
HMAC-SHA256 of `"MacPilotRemote-v1-ble-presence" ‖ device UUID ‖ nonce` under the
long-term pairing key, and the Mac verifies the proof with the bound client's key
before learning the address it just observed. The nonce is fresh per attempt and
the UUID binds the proof to one Mac, so a captured response authenticates
nothing. The phone answers with `bluetooth-peripheral` background mode, without a
network session or any user interaction. This proves identity, never proximity:
the learned address still has to produce ordinary RSSI samples above the unlock
threshold. Older phones lack the characteristic; the Mac logs
`reason=phoneDoesNotChallenge` and keeps the foreground claim path, so the
addition is wire-compatible in both directions.

## Performance

- **Keychain access.** PilotNest loads its pairing-key snapshot on a dedicated
  serial queue before starting authenticated network/BLE discovery. Bluetooth
  delegates, retry policies and presence-status refreshes read memory only;
  `SecItemCopyMatching` must never run on the main actor. New pairings wait for
  the background write to succeed, and forgetting a Mac invalidates its cached
  key immediately and removes metadata only after deletion completes. A failed
  read is unavailable credentials, not an empty Keychain. Two build-49 watchdog
  reports on 2026-10-29 showed the main thread waiting synchronously on securityd
  from a CoreBluetooth callback; one exceeded its 10-second scene-update budget.
- **Automatic Mac selection.** When the selected Mac is unavailable and exactly
  one other paired Mac remains discoverable, confirm it for 3 seconds before
  switching. A live authenticated session, an active pairing/authentication,
  a manual choice or a stale foreground-generation deadline prevents switching.
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
- `Tests/MacPilotTests/SidecarRemoteTests.swift` drives `SidecarService` against
  a stub bridge — accepted-before-confirmed connects, the nil-error-is-not-a-
  verdict rule, a session confirming exactly at the deadline, timeouts that
  re-read the system first, target switching, stable error codes, and the
  healing of a stale failure — plus the router's three Sidecar commands. No test
  loads `SidecarCore`, so none of them can start a real session.
- `iOS/MacPilotRemote/Tests/SidecarPanelPolicyTests.swift` covers the sheet's
  pure rules: "cannot search" is never shown as "found nothing", an operation
  outranks the system list, a failed attempt leaves the row usable while a live
  one locks it, only a target switch asks for confirmation, and a closed sheet
  or dead link polls nothing.

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
succeeds on a BLE L2CAP connection, or after matching the token described above
over GATT. In both cases the source is the local central's
`CBPeripheral.identifier`, attached to the exact discovered peripheral, never a
UUID supplied by the phone. Authentication alone does not mark the BLE device
present or unlock: the normal fresh RSSI thresholds, timeouts and manual lock
suppression still apply.

The negotiated `bleIdentityLearning` capability is sent only to a feature-aware
phone whose authenticated pairing is explicitly associated with BLE Unlock;
`bleIdentityClaim` requires that same pairing and an explicit client
declaration. An updated PilotNest can briefly keep its BLE
advertisement/authentication probe alive after the preferred LAN/AWDL session
wins, without promoting the probe or interrupting the active network session.
Old peers retain their existing behavior.
An old PilotNest still learns aliases whenever its normal BLE remote connection
authenticates successfully; the new capabilities are not required on that path.
An updated PilotNest talking to an older Mac simply skips the optional probe.
Neither learning nor successful probing is a prerequisite for remote commands,
network connections or the existing BLE proximity policy.
Probes stop on foreground-window expiry, authentication completion or backgrounding.
The L2CAP path introduces no commands; `claimBLEIdentity` is the one optional,
capability-gated command on the GATT path.

When the Mac advertises `bleIdentityLearning` (that is, it holds an explicit BLE
Unlock binding for this phone), PilotNest persists that proximity intent and
keeps the peripheral advertising after the app is backgrounded and after a
network transport wins the race. The advertisement is what the Mac's BLE Unlock
central rediscovers after a link drop; there is no advertisement callback to
recover from otherwise. An L2CAP control channel is still accepted only in the
foreground. iOS moves service UUIDs to the overflow area for background
advertisements, so the BLE Unlock scan (unfiltered) can still see the phone while
the remote-control BLE central (service-filtered) cannot; that central remains a
foreground fallback. If the system suspends the app or the user force-quits it,
no CoreBluetooth advertisement survives.

The Mac also reads `claimBLEIdentity` on an already-open GATT link and re-reads
the characteristic a few times while the claim is pending, because the phone
arms the token slightly after acknowledging the command. A matched claim never
cancels a link that already carries an L2CAP control session.

At most eight learned aliases are retained per logical device, evicting the
least-recently authenticated alias. Duplicate observations update metadata at
most once per minute. UUIDs cannot belong to multiple logical devices. Within a
logical device, original UUID and aliases are OR alternatives; primary/secondary
devices retain their existing ANY/ALL relationship. The settings UI shows the
learned list and allows clearing it without deleting the original device.

This repairs authenticated UUID association and keeps a bound phone discoverable
while the app is backgrounded. It cannot survive app termination or an iOS
suspension that tears the peripheral down. Automated acceptance must use isolated
pure/mocked logic, never lock, blank or sleep the user's real screen.

## Authenticated reverse presence (production)

This is the production path built on the reversed-role service; the manual
connectivity test described in the next section remains a separate diagnostic
role of the same Mac manager and the same fixed UUIDs. Starting or stopping the
diagnostic test never starts or stops production, and production never accepts a
diagnostic echo as presence evidence.

The Mac advertises only the service UUID. A paired phone connects, reads Mac
info and subscribes to the presence characteristic. For each subscriber the Mac
issues a fresh 16-byte nonce by notification (small enough for the default ATT
MTU), keeps exactly one pending challenge per central with a 15-second TTL, and
repeats the same nonce when the notification buffer is full. A new nonce is
issued about every 2.5 seconds while a subscriber exists.

The phone answers a notification only after `readRSSI()` returns a real reading.
It signs the sample with the Mac's long-term pairing key:

| Field | Bytes | Notes |
| --- | --- | --- |
| version | 1 | currently `1`; unknown versions are rejected |
| nonce | 16 | must equal the Mac's pending challenge |
| mac ID | 16 | must equal the Mac's stable device ID |
| RSSI | 1 | signed `Int8`, valid range `-127...0` |
| sampled at | 8 | big-endian milliseconds since the epoch |
| HMAC-SHA256 | 32 | domain label `MacPilotRemote-v1-reverse-presence` over every field above |

The legacy `RemoteBLEPresenceChallenge.response(pairingKey:)` encoding is
unchanged. The reverse sample uses a separate domain label, so an identity proof
can never be replayed as a proximity sample. The Mac expires its challenge using
local continuous monotonic elapsed time including system sleep (15 seconds); the signed phone timestamp is diagnostic
only, so device wall-clock skew cannot reject an otherwise valid sample. Only a verified sample consumes
the pending nonce, so a duplicate write has nothing left to match.

On the Mac, the model revalidates everything the GATT layer cannot own: the
feature and reverse toggle are enabled, the session is on the console, the
system is not asleep, the RSSI is in range, the
`clientID + keyFingerprint` still maps to a configured `primaryUUID`, and a
pairing key is still available. The reported `clientID`, fingerprint, primary
UUID, RSSI and sample time are the only data that cross into the unlock model.

Reverse evidence lives in its own runtime per logical device
(`BLEReversePresenceRuntime`), never in `identityRegistry.aliases`: the alias
registry names phone peripherals the Mac's central saw, which is a different
address space from the phone central the Mac's peripheral sees. Legacy and
reverse presence are merged only at the logical-device layer
(legacy alias presence OR authenticated reverse presence), and the configured
`.any` / `.all` relation is still applied across logical devices. The two RSSI
streams are never averaged. A connected GATT link without a fresh authenticated
sample is not proximity; the existing signal timeout, departure threshold,
`proximityTimeout`, `manualLock`, sleep, display and `wakeWithoutUnlocking`
rules are unchanged. Every accepted sample enters the existing
`updatePresence` / unlock-attempt gate; no GATT or unlock-model callback calls a
screen-control primitive directly.

The two links are independent for recovery as well as for presence: a fresh
reverse sample never cancels legacy reconnection, scan retries or the
`signalTimeout` recovery, and reverse timers are never extended by legacy
advertisements. Each link must recover itself; either direction may still satisfy
the unlock gate.

Mac production starts only when BLE Unlock is enabled, the session is on the
console, a stable device ID exists, at least one configured identity binding
exists, and `remotePairingKeyProvider` is available. The reverse switch turns on
automatically the first time a phone is bound, because pairing is the user's
opt-in; an explicit switch-off is stored in `reverseGATTPresenceExplicitlyDisabled`
and is never overridden by a later binding. Turning the feature off, unbinding,
leaving the console session or quitting stops advertising, clears pending
challenges and retries, and drops reverse runtime. If an iPhone stays connected
while production is off, its subscription is remembered but granted nothing;
re-enabling production challenges it again without waiting for a resubscribe iOS
would not send.

PilotNest keeps a separate `CBCentralManager` for production with restoration
identifier `com.misswell.macpilot.reverse-presence.central`. Its intent keys are
`reversePresence.wantsToRun`, `reversePresence.disabledByUser`,
`reversePresence.autoEnableMigrated` and `reversePresence.knownMacIDs`; the last
stores Mac UUIDs only, never keys. Pairing success (key already in the Keychain)
enables it unless the user opted out; existing paired users migrate once; app
launch restores the manager only when the intent and a Keychain key exist.
Unknown Macs, Macs whose key was deleted, and invalid Mac info are disconnected
without feeding any presence. Scanning never stops for a rejected Mac, and the
phone keeps at most four Mac connections.

A disconnect submits a new pending CoreBluetooth connection synchronously in
its delegate callback. The retry delay is passed using
`CBConnectPeripheralOptionStartDelayKey`; no application `Task.sleep` has to run
before the system sees the request. Recoverable GATT rejections first finish
our own cancellation, then submit exactly one delayed request. Backoff is per
peripheral and resets only after a sample write was accepted by the Mac. Pending
radio connections have no app timer: the 12-second setup timeout starts after
`didConnect`, so it cannot cancel a system request while the phone is away.
See [the background recovery incident](BLE_REVERSE_BACKGROUND_RECOVERY.md) for
runtime evidence and verification limits.

Entering the background empties every pending challenge and marks each
connection as waiting for a fresh one; only a challenge delivered afterwards can
produce a new sample. A successful write only means the Mac accepted the sample.
iOS does not guarantee relaunch after the user force quits the app; reopening it
restores from the saved intent. The explicit iOS toggle in Settings stops the
scan, connections and retries without touching the diagnostic test.

## Independent reversed-role GATT connectivity test

The existing remote-control BLE transport remains Mac Central / iPhone
Peripheral, including its GATT identity exchange and L2CAP channel. The optional
connectivity test runs alongside it in the opposite direction. The test itself
has no command dispatcher, authentication, proximity verdict, RSSI policy or
lock/unlock wiring; those belong to the production reverse-presence path above,
which the test neither controls nor verifies. The existing names
`ProximityBLEPeripheral`, `ProximityBLECentral` and `ProximityGATTService` are
retained rather than introducing a duplicate protocol.

| Characteristic | UUID suffix | Properties | Payload |
| --- | --- | --- | --- |
| Service | `6D616350-696C-6F74-0002-000000000001` | — | — |
| Mac info | `…0002-000000000002` | read | 17 bytes: version `1` + device UUID (zeros = not configured) |
| Echo | `…0002-000000000003` | notify | The originating phone's 16-byte payload |
| Response | `…0002-000000000004` | write with response | A fresh random 16-byte nonce |
| Presence | `…0002-000000000005` | read, write, notify | Legacy 33-byte identity challenge or production 16-byte nonce / 74-byte signed sample |

The UUID after `central subscribed uuid=` in the Mac log identifies the subscribing
central; it is **not** a characteristic UUID. Existing characteristic UUIDs and
payload lengths are unchanged, so the original foreground harness remains usable.

The phone reads Mac info, subscribes to Echo and writes its nonce to Response.
Only an exact, unexpired match consumes the single pending request and increments
the verified count. Duplicates, mismatches and late responses are logged and
ignored. Each connection attempt and each probe has a 15-second deadline. A repeat
button and foreground resume can send another probe without reconnecting.

The Mac validates the entire ATT write batch before changing state and responds
once for that batch. A write requires the writer's notification subscription.
Responses are targeted to that central. A full notification buffer preserves the
queued response for `peripheralManagerIsReady`; the bounded queue accepts at most
one response per central, expires it after 15 seconds and discards it on
unsubscribe, radio reset or stop. Queuing a notification is not proof of a verified
round trip: only the phone can report that. Mac subscription counts likewise do
not claim visibility into physical connections that CoreBluetooth does not expose.

### Lifecycle and background limits

Both managers are app-owned, start only by explicit opt-in and remain independent
of the old BLE managers. Leaving the test page no longer stops a running test;
use its stop button. Mac stop removes only this manager's service/advertisement.
The phone reacts to service invalidation as well as disconnection. The Mac retries
publication/advertisement errors; the phone retries connection, discovery,
subscription and write failures. Delays progress through 1, 2, 4, 8, 16, then a
maximum of 30 seconds. Power-off/reset cancels pending work and waits for
`poweredOn`; stop cancels all retries and queued work.

PilotNest preserves `bluetooth-peripheral` and adds `bluetooth-central` to
`UIBackgroundModes`. Its independent manager uses the fixed restoration ID
`com.misswell.macpilot.reverse-gatt.central`. The explicit run intent is stored in
the separate UserDefaults key `reverseGATTTest.wantsToRun`; existing configuration
and pairing records are unchanged. App launch recreates this manager only when
that intent exists; stop clears it. Restoration reattaches delegates, revalidates
the service/characteristics and notification subscription and performs a fresh
probe. A restored peer/cache alone never marks the test verified.

Scanning always specifies the test service UUID. iOS schedules background scans,
connections and callbacks; scan latency can increase, and local retry/deadline
tasks can be suspended. Returning to the foreground checks any expired request.
There is no background timer/keepalive guarantee and no promise of relaunch after
a user force quit. See Apple's [background processing guide](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html)
and [TN3115 restoration rules](https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules).

### On-device acceptance

Use a real Mac and real iPhone. Simulators cannot prove BLE advertising, background
scheduling or radio coexistence. A configured remote-control identity is optional;
without one Mac info carries zeros. Export both logs, record device/OS versions and
measure actual event-to-event latency (including background delays).

1. Start MacPilot › BLE Unlock › GATT connectivity test › Start advertising.
   Expect `advertising started`, advertising status and zero subscribers.
2. Start PilotNest › Settings › Connection link › GATT connectivity test.
   Expect `central connected`, `service discovered`, `central subscribed`,
   `sending 16 bytes`, `received 16 bytes`, `round-trip verified`.
   The Mac logs `received 16 bytes` and `echoed 16 bytes`; only PilotNest's verified
   count proves matching. Send another probe and confirm it adds exactly one.
3. Lock the iPhone, then stop/restart only the test advertisement on the Mac.
   Repeat while PilotNest is in the background. Check automatic discovery,
   reconnection and a fresh verified echo, recording actual delays. Verify an
   existing subscription separately; no reconnect during this interval alone
   establishes that it stayed active. Do not infer a pass just from a cached
   “verified” label. Return to the foreground and send a new probe too.
4. Toggle Bluetooth on either device and verify failure diagnostics followed by
   automatic recovery after power-on. Stop/restart the test repeatedly and verify
   that cancelled requests and prior sessions cannot add successes.
5. Run the original RSSI monitoring and remote-control/L2CAP link concurrently.
   Stop only the test and confirm the old link remains operational. Any actual
   Mac lock/unlock acceptance must use an explicitly authorized isolated session;
   automated tests must never lock or type into the user's login screen.
6. Test a notification buffer stall, unsubscribe with a queued response, duplicate
   and late notifications and connect/service/subscribe/write timeouts with the
   automated state tests; confirm hardware buffer behavior separately when possible.
7. Stop both test managers. Confirm no test scan, advertisement or retry remains.
   Force quit is a separate negative/OS-policy observation, never a guaranteed
   recovery acceptance criterion.

Automated tests exercise nonce correlation, exactly-once counting, expiry, queue
ownership/capacity/cleanup, capped retry, opt-in defaults and both localization
tables. They cannot prove CoreBluetooth callback ordering, background relaunch,
physical disconnection or simultaneous operation of the two radios' roles.
Record actual validation and outstanding hardware checks in
`docs/REVERSE_GATT_ACCEPTANCE.md`.
