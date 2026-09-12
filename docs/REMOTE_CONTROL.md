# MacPilot Remote Control (iPhone → Mac)

MacPilot can be locked, blanked, unlocked and woken from an iPhone on the same
local network. This document describes the design, the wire protocol and the
security model, and how to build the companion iOS app.

## Goals and non-goals

| Goal | How |
| --- | --- |
| No IP or port entry | Bonjour (`_macpilot._tcp`) discovery plus a remembered address for the fast path |
| No re-pairing | A long lived pairing key in the Keychain on both sides; only the very first connection shows a 6 digit code |
| Fast connect (< 500 ms typical) | A persistent TCP connection, a remembered endpoint tried before mDNS resolution completes, and an authenticated handshake that costs two round trips |
| No IP scanning, no UDP broadcast, no HTTP | `NWBrowser` + `NWListener` on `NWParameters.tcp` |
| The Mac login password never leaves the Mac | The protocol has no password field; unlocking happens locally through `MacScreenControlService` |

Version 1 is LAN only. There is no relay server, no account, and no public API.

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

## Performance

- **Fast path.** The iPhone stores the host and port it last reached the Mac on
  and dials it immediately when the app opens. If the transport is not up within
  500 ms the attempt is abandoned and the Bonjour result is used instead, so a
  stale address costs half a second rather than blocking startup.
- **Persistent connection.** Commands reuse one TCP connection; there is no
  connect-per-action cost.
- **Keep alive.** A `ping` every 15 seconds confirms the link and reports the
  round trip time.
- **Reconnect.** After a drop the client retries at 0, 0.5, 1, 2 and then 5
  second intervals. It disconnects deliberately when the app backgrounds and
  reconnects when it returns.
- **Instrumentation.** Discovery, transport connect, handshake, round trip and
  command execution latencies are measured on the iPhone and shown under
  **Settings → Connection performance**. The Mac logs
  `handshake complete event=... latency=...ms`.

## Mac setup

1. Open **Remote Control** in the MacPilot sidebar and enable iPhone remote
   control.
2. Grant Accessibility permission (needed for the lock shortcut and key events)
   if it is not already granted.
3. Make sure the unlock password is saved, otherwise unlock commands return
   `.credentialNotConfigured`.
4. Click **Start pairing** to open the 120 second pairing window.
5. In the iPhone app, open **Devices**, tap the discovered Mac, and type the code
   shown on the Mac.

The Mac listens on `_macpilot._tcp` and prefers port 43847, falling back to a
dynamic port if that one is taken. macOS asks for Local Network permission the
first time; both sides need it.

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

## Tests

- `Packages/MacPilotRemoteProtocol/Tests/MacPilotRemoteProtocolTests/` covers
  framing (including a regression test for sliced `Data` indices), the secure
  codec, the replay guard, pairing code rules, proof agreement and TXT records.
- `Tests/MacPilotTests/RemoteControlTests.swift` covers the screen control
  models, the command router, configuration coding, the pairing window and the
  paired device store.

Keychain backed types are tested through the in-memory `SecretStore`, so the test
process never triggers a Keychain access prompt.
