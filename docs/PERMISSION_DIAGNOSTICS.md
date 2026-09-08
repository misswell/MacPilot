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
