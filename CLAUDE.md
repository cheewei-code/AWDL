# AWDL Menu Bar App

macOS menu bar app that toggles Apple Wireless Direct Link (AWDL) manually and
automatically when NVIDIA GeForce NOW is running.

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
├── AppObserver.swift         # NSWorkspace notifications for watched app launch/quit
├── NotificationManager.swift # UNUserNotificationCenter wrapper
├── Info.plist                # LSUIElement, NSPrincipalClass, usage strings
└── AWDL.entitlements         # Hardened runtime entitlements (sandbox OFF)
```

## Key decisions

- **Sandbox off**: NSAppleScript `with administrator privileges` is blocked in sandbox.
  AWDL control requires root via ifconfig, so there is no sandboxed alternative.
- **App detection**: `NSWorkspace` notifications (`didLaunchApplication`, `didTerminateApplication`)
  watch for GeForce NOW (`com.apple.gfnpc.mall`). No private APIs — fully public.
  To watch additional apps, add bundle IDs to `AppObserver.watchedBundleIDs`.
- **AppleScript for privilege escalation**: chosen over SMJobBless/XPC helper to avoid
  a separate privileged helper daemon and code-signing complexity.
- **Dynamic menu**: NSMenu is rebuilt on every open so state is always current;
  no stale cached items.

## UserDefaults keys

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `userManuallyDisabledAWDL` | Bool | false | User explicitly turned AWDL off |
| `autoManageGameMode` | Bool | true | Auto-disable AWDL when GeForce NOW is running |

## Assumptions to verify on OS update

- AWDL interface name: `awdl0` (gracefully skipped if absent)
- GeForce NOW bundle ID: `com.nvidia.gfnpc.mall` (verify if app is updated)
