# AWDL Menu Bar App

macOS menu bar app that toggles Apple Wireless Direct Link (AWDL) manually and
keeps it off while the user wants it off.

## Build

```bash
xcodebuild -scheme AWDL -configuration Debug build
# or open AWDL.xcodeproj in Xcode and press Cmd+R
```

## Project constraints

- **Language**: Swift, AppKit only — no SwiftUI
- **Minimum target**: macOS 14 Sonoma
- **No third-party dependencies**
- **App Sandbox: OFF** — required for NSAppleScript with admin privileges and
  subprocess calls (ifconfig, sudo). Do not re-enable sandbox.
- **No Dock icon**: LSUIElement = YES in Info.plist

## File layout

```
AWDL/
├── main.swift                # Explicit entry point, assigns AppDelegate
├── AppDelegate.swift         # NSStatusItem, menu bar, app lifecycle, SMAppService
├── AWDLManager.swift         # ifconfig control, state monitor, UserDefaults flag
├── NotificationManager.swift # UNUserNotificationCenter wrapper
├── Info.plist                # LSUIElement, NSPrincipalClass, usage strings
└── AWDL.entitlements         # Hardened runtime entitlements (sandbox OFF)
```

## Key decisions

- **Sandbox off**: NSAppleScript `with administrator privileges` is blocked in sandbox.
  AWDL control requires root via ifconfig, so there is no sandboxed alternative.
- **Manual control only**: there is no app detection. An earlier version watched
  GeForce NOW and toggled AWDL automatically; that was removed on purpose.
- **Keep-off monitor**: macOS brings `awdl0` back up on its own (AirDrop, AirPlay,
  Handoff…). `AWDLManager` polls every 2 seconds and, while
  `userManuallyDisabledAWDL` is true, runs `ifconfig awdl0 down` again. The monitor
  uses `sudo -n` only, so it never shows a password dialog.
- **Passwordless sudo rule**: installed once at `/etc/sudoers.d/awdl`, scoped to
  `ifconfig awdl0 up/down`. Menu actions fall back to an AppleScript password
  prompt if the rule is missing.
- **AppleScript for privilege escalation**: chosen over SMJobBless/XPC helper to avoid
  a separate privileged helper daemon and code-signing complexity.
- **Dynamic menu**: NSMenu is rebuilt on every open so state is always current;
  no stale cached items.

## UserDefaults keys

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `userManuallyDisabledAWDL` | Bool | false | User turned AWDL off; the monitor keeps it off until they enable it |

## Assumptions to verify on OS update

- AWDL interface name: `awdl0` (gracefully skipped if absent)
- `ifconfig awdl0` prints `status: active` when the interface is up
