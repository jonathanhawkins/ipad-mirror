# Debugging Rules

- **NSLog is useless** — all NSLog output from this app is redacted as `<private>` by macOS unified logging
- For debug logging, use one of:
  - File logging to `/tmp/iPadMirror.log` via FileHandle (works, app is not sandboxed)
  - `os_log` with `%{public}s` format specifiers (visible in `log show`)
- When checking logs via `log show`, use the PID: `/usr/bin/log show --predicate 'processIdentifier == <PID>' --last 5m`
- SourceKit diagnostics about "Cannot find 'SidecarBridge' in scope" are false positives — SourceKit can't resolve cross-file references but the build succeeds
- The app is **not sandboxed** (`com.apple.security.app-sandbox = false`) — it can write anywhere
