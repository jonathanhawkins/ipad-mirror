---
paths:
  - "SiriApp/GlobalHotKey.swift"
---

# Global Hotkey Rules

- Use the **Carbon `RegisterEventHotKey` API** — NOT `NSEvent.addGlobalMonitorForEvents`
- `addGlobalMonitorForEvents` is unreliable in MenuBarExtra apps and silently fails
- Carbon hotkeys work without Accessibility permissions (but the app has them anyway)
- Default hotkey: ⌃⌥⌘I (Control + Option + Command + I)
- The hotkey callback must provide voice feedback via `SpeechManager.shared.announce()` so it works when the screen is broken/off
- Registration must happen in the SwiftUI App `init()` — `applicationDidFinishLaunching` may not fire reliably for MenuBarExtra apps
