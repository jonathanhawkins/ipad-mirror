# iPad Mirror

A macOS menu bar app that connects your iPad as a Sidecar display programmatically — no GUI navigation required. Control it from the menu bar, Siri, or a keyboard shortcut.

Built for situations where your MacBook screen is broken or inaccessible and you need to get a display running fast.

## Features

- **One-click setup** — on first launch, a setup wizard configures everything for you
- **Menu bar app** — connect/disconnect your iPad from the menu bar
- **Siri voice control** — "Connect iPad Mirror", "Disconnect iPad Mirror", "Toggle iPad Mirror"
- **Global keyboard shortcut** — toggle your iPad connection with a hotkey (default: `⌃⌥⌘I`)
- **Auto-connect on login** — optionally connects your iPad automatically when you log in
- **Shortcuts integration** — works with the Shortcuts app via `ipadmirror://` URL scheme
- **No dock icon** — runs as a lightweight menu bar utility

## Requirements

- macOS 14.0+
- iPad with Sidecar support
- Both devices signed into the same Apple ID

## Getting Started

1. Build and install:
   ```bash
   ./build-app.sh
   ```
2. Launch the app:
   ```bash
   open "/Applications/iPad Mirror.app"
   ```
3. The setup wizard appears on first launch — click **"Set Up Selected"** to configure:
   - **Siri Shortcuts** — click "Add Shortcut" for each of the 3 import dialogs
   - **Auto-Connect on Login** — installs automatically
   - **Global Keyboard Shortcut** — registers immediately

That's it. You can re-run the setup anytime from the menu bar: click the iPad icon → **Setup...**

Or open `iPadMirror.xcodeproj` in Xcode and build directly.

## URL Scheme

The app registers the `ipadmirror://` URL scheme for automation:

| URL | Action |
|-----|--------|
| `ipadmirror://connect` | Connect to the first available iPad |
| `ipadmirror://disconnect` | Disconnect the current iPad |
| `ipadmirror://toggle` | Toggle the connection |

## Manual Setup (Advanced)

If you prefer to set things up manually instead of using the setup wizard:

### Keyboard Shortcut

The app registers a global hotkey automatically during setup (default: `⌃⌥⌘I`). Alternatively, you can create a Quick Action in Automator:

1. Open **Automator** → New → **Quick Action**
2. Set "Workflow receives" to **no input**
3. Add a **Run Shell Script** action with: `open ipadmirror://toggle`
4. Save as "Toggle iPad Mirror"
5. Assign a shortcut in **System Settings** → **Keyboard** → **Keyboard Shortcuts** → **Services**

### Siri Shortcuts

Create shortcuts in the Shortcuts app that use the "Open URL" action pointing to:
- `ipadmirror://connect`
- `ipadmirror://disconnect`
- `ipadmirror://toggle`

Then say "Hey Siri, connect iPad Mirror" to trigger them.

### Auto-Connect on Login

Create a LaunchAgent at `~/Library/LaunchAgents/com.user.ipad-mirror.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.ipad-mirror</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>ipadmirror://connect</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
```

## How It Works

iPad Mirror uses Apple's private `SidecarCore.framework` to programmatically manage Sidecar connections. The `SidecarDisplayManager` class provides device discovery, connection, and disconnection — the same APIs that System Settings uses under the hood.

## Project Structure

```
├── build-app.sh                  # Build & install script
├── iPadMirror.xcodeproj/         # Xcode project
└── SiriApp/
    ├── App.swift                 # Menu bar app, URL handler, onboarding trigger
    ├── AppIcon.icns              # App icon
    ├── Entitlements.plist        # App entitlements (no sandbox)
    ├── GlobalHotKey.swift        # Carbon RegisterEventHotKey wrapper
    ├── Info.plist                # App configuration
    ├── Intents.swift             # AppIntents for Siri
    ├── LaunchAgentInstaller.swift # LaunchAgent install/uninstall
    ├── OnboardingView.swift      # First-run setup wizard UI
    ├── SetupManager.swift        # Setup orchestration & state
    ├── ShortcutInstaller.swift   # Siri Shortcut generation & import
    └── SidecarBridge.swift       # SidecarCore framework bridge
```

## License

MIT
