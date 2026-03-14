---
paths:
  - "SiriApp/SidecarBridge.swift"
---

# SidecarCore Framework Rules

- SidecarCore is a **private framework** at `/System/Library/PrivateFrameworks/SidecarCore.framework`
- All access is via KVC (`value(forKey:)`) and dynamic selectors — there are no headers
- Use `safeValue(forKey:on:)` to probe unknown properties — raw `value(forKey:)` throws NSUnknownKeyException for missing keys
- Device objects expose: `name`, `identifier`, `model`, and possibly transport-related properties (discovered at runtime via introspection dump)
- Always filter Vision Pro devices from the device list — they cause -1010 connection errors
- Prefer USB connections over Wi-Fi when both are available
- Auto-dismiss all SidecarCore error alert panels — they stack up and block the UI
- The method swizzle interceptor (NSWindow.orderFront/makeKeyAndOrderFront) is the primary alert defense; the 0.25s timer sweep is backup
