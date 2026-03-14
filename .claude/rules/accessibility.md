# Accessibility & Broken Screen Mode

The primary user has a broken Mac screen and relies on the iPad as their display. All features must be usable without seeing the Mac screen.

- **Broken Screen Mode is ON by default** — registered via `UserDefaults.register(defaults:)`
- All user-facing state changes must have voice feedback via `SpeechManager`
- Use `SpeechManager.shared.speak()` for mode-gated speech (only when Broken Screen Mode is on)
- Use `SpeechManager.shared.announce()` for always-on speech (e.g., hotkey confirmation, toggle feedback)
- New features that affect connection state should include speech narration
- The `DisplayManager` automatically makes the iPad the primary display on connect and restores on disconnect
