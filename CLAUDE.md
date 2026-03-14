# iPad Mirror

macOS MenuBarExtra app that uses Apple's private `SidecarCore.framework` to programmatically manage Sidecar connections to an iPad. Controllable via menu bar, Siri, Shortcuts, and a global hotkey.

## Build & Install

```bash
# Dev build (Debug)
xcodebuild -scheme "iPad Mirror" -configuration Debug build

# Install: force-kill, copy, relaunch
killall -9 "iPad Mirror" 2>/dev/null; sleep 2
cp -Rf "/Users/light/Library/Developer/Xcode/DerivedData/iPadMirror-cxesrvkqgyiyjvdrdvbbeuxyhdfy/Build/Products/Debug/iPad Mirror.app/" "/Applications/iPad Mirror.app/"
open "/Applications/iPad Mirror.app"

# Release build (uses build-app.sh)
./build-app.sh
```

**Important:** Must use `killall -9` (not plain `killall`) and `cp -Rf` with trailing slashes to actually replace the running binary. Plain `killall` and `cp -R` silently fail.

## Project Structure

```
SiriApp/
  App.swift              — SwiftUI MenuBarExtra, AppDelegate, UI
  SidecarBridge.swift    — Core: SidecarCore.framework bridge, device management, watchdog
  GlobalHotKey.swift     — Carbon RegisterEventHotKey for ⌃⌥⌘I toggle
  SpeechManager.swift    — AVSpeechSynthesizer for voice narration
  DisplayManager.swift   — Display takeover (make iPad primary display)
  Intents.swift          — AppIntents for Siri/Shortcuts integration
  SetupManager.swift     — First-run onboarding
  OnboardingView.swift   — Onboarding UI
  LaunchAgentInstaller.swift — Login item setup
  ShortcutInstaller.swift    — Shortcut installation
```

## Architecture

- **SidecarCore.framework** (`/System/Library/PrivateFrameworks/SidecarCore.framework`) — Private framework. Accessed via KVC (`value(forKey:)`) and dynamic selectors (`connectToDevice:completion:`, `disconnectFromDevice:completion:`).
- **Device filtering** — Vision Pro is filtered out from device lists by name/model.
- **USB preference** — Devices sorted to prefer USB/wired over Wi-Fi connections.
- **Alert suppression** — Method swizzling on `NSWindow.orderFront:`/`makeKeyAndOrderFront:` plus a 0.25s timer sweep to auto-dismiss SidecarCore error alerts.
- **Watchdog** — Auto-reconnects on connection drop with exponential backoff (max 5 attempts).
- **Broken Screen Mode** — Enabled by default. Speech narration + iPad display takeover.

## Key Details

- **Bundle ID:** `com.user.ipad-mirror`
- **Deployment target:** macOS 14.0
- **Scheme:** "iPad Mirror"
- **Not sandboxed** — required for private framework access and global hotkeys
- **Global hotkey:** ⌃⌥⌘I (Carbon API, not NSEvent monitor)
- **Siri phrases:** "Connect/Disconnect/Toggle iPad Mirror", "Is iPad Mirror connected"
- **URL scheme:** `ipadmirror://` (connect, disconnect, toggle commands)

## Debugging

- `NSLog` output is **redacted** by macOS unified logging. Use `/tmp/iPadMirror.log` file logging or `os_log` with `%{public}s` format specifiers.
- Runtime introspection dumps SidecarCore device properties on first discovery (one-shot, check logs for property names).
- SidecarCore error codes: -1010 = miscellaneous error (often Vision Pro conflict).

## Common Issues

- **Vision Pro conflicts:** Having Vision Pro connected causes -1010 Sidecar errors. The app filters Vision Pro from devices and suppresses these alerts.
- **Hotkey not working:** Ensure Accessibility permission is granted. After reinstalling, may need to toggle permission off/on. Carbon hotkeys don't need Accessibility but the old NSEvent approach did.
- **Stale binary after install:** Always `killall -9` before copying. Verify with `md5` hash comparison if in doubt.
