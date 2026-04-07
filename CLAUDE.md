# AWDL Menu Bar App

macOS menu bar app that toggles Apple Wireless Direct Link (AWDL) manually and
automatically via Game Mode detection.

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
  subprocess calls (ifconfig, defaults read). Do not re-enable sandbox.
- **No Dock icon**: LSUIElement = YES in Info.plist

## File layout

```
AWDL/
├── AppDelegate.swift         # NSStatusItem, menu bar, app lifecycle, SMAppService
├── AWDLManager.swift         # ifconfig control, state reading, UserDefaults flags
├── GameModeObserver.swift    # Darwin notification + 5s polling fallback
├── NotificationManager.swift # UNUserNotificationCenter wrapper
├── Info.plist                # LSUIElement, NSPrincipalClass, usage strings
└── AWDL.entitlements         # Hardened runtime entitlements (sandbox OFF)
```

## Key decisions

- **Sandbox off**: NSAppleScript `with administrator privileges` is blocked in sandbox.
  AWDL control requires root via ifconfig, so there is no sandboxed alternative.
- **Private API**: `com.apple.GameController.gameModeStateChanged` Darwin notification
  is undocumented. If it stops working after an OS update, the polling fallback
  (`defaults read com.apple.gamecontrollerd`) takes over automatically.
- **AppleScript for privilege escalation**: chosen over SMJobBless/XPC helper to avoid
  a separate privileged helper daemon and code-signing complexity.
- **Dynamic menu**: NSMenu is rebuilt on every open so state is always current;
  no stale cached items.

## UserDefaults keys

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `userManuallyDisabledAWDL` | Bool | false | User explicitly turned AWDL off |
| `autoManageGameMode` | Bool | true | Auto-disable AWDL when Game Mode activates |

## Private APIs / assumptions to verify on OS update

- Darwin notification name: `com.apple.GameController.gameModeStateChanged`
- Polling key: `defaults read com.apple.gamecontrollerd` — look for `GameModeEnabled`
- AWDL interface name: `awdl0` (gracefully skipped if absent)
