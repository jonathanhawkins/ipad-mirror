---
paths:
  - "**/*.swift"
---

# Swift Code Style

- Target: macOS 14.0+, Swift 5.9+
- Use `@unchecked Sendable` for singleton manager classes that use internal synchronization
- Use `NSLog` for log messages prefixed with `[iPad Mirror]` (even though they get redacted — keeps consistency)
- Mark sections with `// MARK: -` comments
- Use `final class` for non-inheritable classes
- Async/await for all SidecarCore API calls (wrapped in `withCheckedThrowingContinuation`)
- No SwiftUI previews — this is a MenuBarExtra app with no main window
