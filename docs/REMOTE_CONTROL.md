# MacPilot Remote Control (iPhone → Mac)

MacPilot can be locked, blanked, unlocked and woken from an iPhone on the same
local network. This document describes the design, the wire protocol and the
security model, and how to build the companion iOS app.

## Goals and non-goals

| Goal | How |
| --- | --- |
| No IP or port entry | Bonjour (`_macpilot._tcp`) discovery plus a remembered address for the fast path |
| No re-pairing | A long lived pairing key in the Keychain on both sides; only the very first connection shows a 6 digit code |
| Fast connect (< 500 ms typical) | Bonjour, the remembered address and Bluetooth are dialled at the same time; whichever authenticates first wins, so no path waits behind another |
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

Every message is preceded by a 4 byte big endian length. The first body byte
selects the encoding:

```
plaintext handshake:  0x01 || UTF-8 JSON (RemoteHandshakeMessage)
sealed command:       0x02 || UInt64 BE sequence || ChaChaPoly combined box
```

The ChaChaPoly nonce is derived from the sequence: 4 zero bytes followed by the
sequence as a big endian `UInt64`. The additional authenticated data is the
`0x02` tag. Frames larger than `RemoteProtocolVersion.maximumFrameSize`
(256 KiB) are rejected.

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
and session key — so a slow path can never hold up a fast one. The first to
authenticate is promoted; the rest are torn down before the swap, and their
failures never reach the UI. A race in which no candidate produces a transport
within 4 seconds is abandoned and redialled, but a candidate that is already
mid-handshake is never cut.

Bluetooth takes part from the first attempt instead of waiting for the network to
fail. That is what makes it useful — establishing the link takes seconds, so
starting it late means arriving late — and the cost is a radio advertisement for
as long as the app is open and disconnected. It stops the moment any link carries
a session.

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
