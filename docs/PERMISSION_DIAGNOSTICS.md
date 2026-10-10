# Permission prompt diagnosis

Use `zsh Scripts/capture-permission-diagnostics.sh 60` before reproducing an
update or launch. It captures live system events, installed signing metadata,
versions, and PIDs into a new temporary directory. It does not reset TCC or
accept prompts. A working live stream is independent of `log show` availability.

`PermissionDiagnostics` additionally records startup signing metadata and
begin/end markers around App Group resolution, database access, IPC key access,
and Automation quit preflight. Each process writes under its own Foundation
Library directory at `Logs/MacPilot/Permissions/`; the Finder extension's path
is inside its sandbox. Files include the PID and a session UUID, are capped at
512 KiB, and expire after seven days when another session writes a log.
Do not read the extension's sandbox from the main app to collect logs: that
could itself trigger a data-access prompt. System events use the category
`PermissionDiagnostics`. No keys, message payloads, or database contents are logged.

## Confirmed on 2026-09-08, installed versions 1.1.281 and 1.1.282

At 22:59:47 local time, a live capture recorded an actual `AUTHREQ_PROMPTING`
for `kTCCServiceSystemPolicyAppData`, subject `com.misswell.macpilot`, PID 15041.
The kernel identified the protected paths as the App Group
`group.com.misswell.macpilot.rightclick` and its `RClickDatabase.sqlite`.
This establishes an App Data prompt, not an Automation prompt. It does not by
itself attribute every earlier dialog to a particular Finder extension PID.

The repair moves SwiftData out of the protected App Group and leaves the
App Group only for the authenticated IPC key. The App Group identifier now
uses the Developer Team ID prefix (`U8U443D7ZL.com.misswell.macpilot.rightclick`),
which macOS can validate for a Developer ID app without a provisioning profile.
Version 1.1.282 still probed the old App Group during its first-launch
migration, which reproduced the prompt. The follow-up repair stops all
protected App Group access during startup. It may copy only the unprotected
Application Support fallback automatically; the old store remains untouched
and can be recovered only through the explicit Settings action. The recovery
action may ask for consent once, while ordinary launches and updates do not
probe that path.

The startup path also no longer probes OctoPilot/OctoQuit configuration files
or preference suites. Those legacy imports must be user-initiated if they are
needed; signed updates must not silently inspect another app's data.

## Finder menus disappearing after restart or replacement

Run `zsh Scripts/verify-findersync.sh` for a read-only check of the installed
extension, signature, election, and elected bundle path. This does not restart
Finder, modify permissions, or prove that a visible context menu was rendered.
Use an ordinary local folder such as Downloads for visual acceptance;
FileProvider-backed locations are a separate FinderSync limitation.

On 2026-10-10, the app's right-click feature was enabled, but PlugInKit reported
`- com.misswell.macpilot.finder-sync` (the user election was **ignore**). The
installed extension's path and signature were valid. Startup recovery logged
`repaired=false` on three app launches because it only repaired `+` elections.
With the user's repair request, electing this one extension for use immediately
started its host, resolved the shared container, read a valid IPC key, and
requested menu configuration from the existing main app. Finder was not restarted.
The user confirmed that the actual context menu had returned in a local folder.
There is no surviving updater log proving who originally set this ignore election;
do not infer that every disabled extension is a failed update.

Two lifecycle hazards need regression coverage: a temporary ignore election
must be recoverable after interruption, and a resident extension that stops its
heartbeat on main-app quit must resume it on the next authenticated running
notification. A signed configuration request also proves that the extension is
alive; waiting for the first periodic heartbeat must not cause needless
re-registration. Recovery must never override an unmarked user-disabled extension.

Temporary registration transactions now use the independent per-user sidecar
`Library/Application Support/MacPilot/FinderSyncRecovery.json`. An atomic intent
is written before `ignore`; a nonblocking cross-process lock prevents startup
and updater transactions from racing. Only a valid, versioned intent for the
same app/extension target authorizes recovery of an ignored election. Invalid,
unknown, or mismatched records are not overwritten or used as authorization.
The intent is cleared only after a fresh query confirms `+` **at the current
installed extension path**. Command exit status alone is insufficient. The
successful update/rollback path restores and verifies election before launching
the app. If restoration fails, it retains the intent and reports failure; only
after the transaction and lock have ended may the intact app be relaunched to
retry journal recovery. A Finder repair failure must not prevent the entire app
from returning, and is never declared a successful extension restoration.
No persisted configuration keys or menu preferences are changed.
