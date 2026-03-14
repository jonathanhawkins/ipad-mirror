import Foundation
import ObjectiveC
import CoreGraphics
import AppKit
import os.log

private let ipmLog = OSLog(subsystem: "com.user.ipad-mirror", category: "SidecarBridge")

// MARK: - ObjC Runtime Introspection Helpers

/// Dumps all properties and their values for an NSObject to the console log.
/// Used to discover available SidecarCore device properties at runtime.
private func dumpObjectProperties(_ obj: NSObject, label: String) {
    var count: UInt32 = 0
    guard let properties = class_copyPropertyList(type(of: obj), &count) else {
        os_log("[iPad Mirror] %{public}s: no properties found", log: ipmLog, type: .default, label)
        return
    }
    defer { free(properties) }

    os_log("[iPad Mirror] %{public}s [%{public}s] — %d properties:", log: ipmLog, type: .default, label, String(describing: type(of: obj)), count)
    for i in 0..<Int(count) {
        let name = String(cString: property_getName(properties[i]))
        let value = "\(obj.value(forKey: name) as Any)"
        os_log("[iPad Mirror]   .%{public}s = %{public}s", log: ipmLog, type: .default, name, value)
    }
}

/// Dumps all instance methods of an NSObject's class to the console log.
private func dumpObjectMethods(_ obj: NSObject, label: String) {
    var count: UInt32 = 0
    guard let methods = class_copyMethodList(type(of: obj), &count) else { return }
    defer { free(methods) }

    let methodNames = (0..<Int(count)).map { String(cString: sel_getName(method_getName(methods[$0]))) }
    os_log("[iPad Mirror] %{public}s methods (%d): %{public}s", log: ipmLog, type: .default, label, count, methodNames.joined(separator: ", "))
}

/// Represents the current state of the automatic reconnection watchdog.
enum ReconnectionState: Equatable {
    /// No reconnection is needed or active.
    case idle
    /// Actively attempting to reconnect. Includes the current attempt number.
    case retrying(attempt: Int)
    /// All retry attempts have been exhausted.
    case failed
}

/// Loads the private SidecarCore framework and provides access to Sidecar display management.
final class SidecarBridge: @unchecked Sendable {
    static let shared = SidecarBridge()

    private let manager: NSObject
    private var watchdogTask: Task<Void, Never>?

    /// The identifier of the device we last connected to, for auto-reconnect.
    private var lastConnectedDeviceID: String?

    /// Preserved copy of the last connected device ID, kept even after watchdog gives up.
    /// Used by retryReconnection() to allow the user to manually restart reconnection.
    private var lastKnownDeviceID: String?

    // MARK: - Reconnection State

    /// Maximum number of consecutive watchdog reconnection attempts before giving up.
    private let maxReconnectAttempts = 5

    /// Tracks consecutive reconnection failures for backoff logic.
    private var consecutiveFailures = 0

    /// Whether a reconnection attempt is currently in flight (prevents overlapping calls).
    private var isReconnecting = false

    /// Set during macOS sleep/wake to prevent the watchdog from firing while the system is settling.
    private var isSuspendedForSleep = false

    /// Timestamp of last alert dismissal, used to throttle log output.
    private var lastAlertDismissTime: Date = .distantPast

    /// Periodic timer that sweeps for and dismisses SidecarCore alert panels.
    /// This is the primary defense — notification-based observers are a fast-path supplement.
    private var alertSweepTimer: Timer?

    /// Observable reconnection state for the UI to display.
    @MainActor var reconnectionState: ReconnectionState = .idle {
        didSet {
            reconnectionStateCallback?(reconnectionState)
        }
    }

    /// Callback invoked on the main actor when reconnection state changes.
    /// Set this from the UI layer to react to state transitions.
    @MainActor var reconnectionStateCallback: ((ReconnectionState) -> Void)?

    /// Whether the method-swizzle interceptor has been installed.
    private static var alertInterceptorInstalled = false

    init() {
        guard let bundle = Bundle(path: "/System/Library/PrivateFrameworks/SidecarCore.framework") else {
            fatalError("SidecarCore.framework not found")
        }
        bundle.load()

        guard let managerClass = NSClassFromString("SidecarDisplayManager") as? NSObject.Type else {
            fatalError("SidecarDisplayManager class not found")
        }
        manager = managerClass.init()
        installAlertInterceptor()
        setupSleepWakeObservers()
        startAlertSweepTimer()
    }

    /// Swizzle NSWindow ordering methods to intercept SidecarCore alert panels
    /// the instant they try to appear, before they are ever rendered on screen.
    private func installAlertInterceptor() {
        guard !Self.alertInterceptorInstalled else { return }
        Self.alertInterceptorInstalled = true

        let pairs: [(Selector, Selector)] = [
            (#selector(NSWindow.orderFront(_:)), #selector(NSWindow.ipm_orderFront(_:))),
            (#selector(NSWindow.makeKeyAndOrderFront(_:)), #selector(NSWindow.ipm_makeKeyAndOrderFront(_:))),
        ]

        for (original, swizzled) in pairs {
            guard let origMethod = class_getInstanceMethod(NSWindow.self, original),
                  let swizMethod = class_getInstanceMethod(NSWindow.self, swizzled) else { continue }
            method_exchangeImplementations(origMethod, swizMethod)
        }
        NSLog("[iPad Mirror] Alert interceptor installed")
    }

    /// Whether we have already dumped device/manager properties (one-shot diagnostics).
    private var hasDumpedIntrospection = false

    /// All Sidecar-capable devices reported by the framework (unfiltered).
    var allDevices: [NSObject] {
        let devs = (manager.value(forKey: "devices") as? [NSObject]) ?? []

        // One-shot introspection dump — logs every property on the manager and
        // each device so we can discover USB/transport fields at runtime.
        if !hasDumpedIntrospection && !devs.isEmpty {
            hasDumpedIntrospection = true
            dumpObjectProperties(manager, label: "SidecarDisplayManager")
            dumpObjectMethods(manager, label: "SidecarDisplayManager")
            for (i, dev) in devs.enumerated() {
                dumpObjectProperties(dev, label: "Device[\(i)] \(deviceName(dev))")
            }
        }

        return devs
    }

    /// Devices filtered to only include iPads, excluding Apple Vision Pro and other non-iPad devices.
    /// Sorted to prefer USB-connected devices over Wi-Fi (see `deviceSortKey`).
    var devices: [NSObject] {
        allDevices.filter { isIPad($0) }.sorted { deviceSortKey($0) < deviceSortKey($1) }
    }

    /// Returns a sort key where lower = preferred. USB/wired devices sort first.
    /// We probe several common SidecarCore property names that may indicate transport.
    private func deviceSortKey(_ device: NSObject) -> Int {
        // Check known property names that SidecarCore may expose for transport type
        if isUSBConnected(device) {
            return 0  // USB — preferred
        }
        return 1  // Wi-Fi — fallback
    }

    /// Safely read a KVC key, returning nil instead of throwing NSUnknownKeyException.
    private func safeValue(forKey key: String, on obj: NSObject) -> Any? {
        guard obj.responds(to: NSSelectorFromString(key)) else { return nil }
        return obj.value(forKey: key)
    }

    /// Heuristic: returns true if the device appears to be connected via USB/wired.
    /// Probes multiple property names since SidecarCore is a private framework.
    func isUSBConnected(_ device: NSObject) -> Bool {
        // "isWired" / "wired" — boolean flag
        if let wired = safeValue(forKey: "isWired", on: device) as? Bool, wired { return true }
        if let wired = safeValue(forKey: "wired", on: device) as? Bool, wired { return true }

        // "transportType" — integer (0 = USB, 1 = Wi-Fi typically) or string
        if let transport = safeValue(forKey: "transportType", on: device) as? Int, transport == 0 { return true }
        if let transport = safeValue(forKey: "transportType", on: device) as? String,
           transport.localizedCaseInsensitiveContains("usb") || transport.localizedCaseInsensitiveContains("wired") {
            return true
        }

        // "connectionType" — similar
        if let connType = safeValue(forKey: "connectionType", on: device) as? Int, connType == 0 { return true }
        if let connType = safeValue(forKey: "connectionType", on: device) as? String,
           connType.localizedCaseInsensitiveContains("usb") || connType.localizedCaseInsensitiveContains("wired") {
            return true
        }

        return false
    }

    var connectedDevices: [NSObject] {
        let all = (manager.value(forKey: "connectedDevices") as? [NSObject]) ?? []
        return all.filter { isIPad($0) }
    }

    var isConnected: Bool {
        !connectedDevices.isEmpty
    }

    func deviceName(_ device: NSObject) -> String {
        (device.value(forKey: "name") as? String) ?? "Unknown"
    }

    func deviceIdentifier(_ device: NSObject) -> String {
        if let val = device.value(forKey: "identifier") {
            return "\(val)"
        }
        return ""
    }

    /// Device identifiers we have already logged as filtered out, to avoid log spam.
    private var loggedFilteredDeviceIDs: Set<String> = []

    /// Returns `true` if the device appears to be an iPad (not an Apple Vision Pro or other non-iPad device).
    /// Checks the device name for known non-iPad identifiers and, when available, the model property.
    private func isIPad(_ device: NSObject) -> Bool {
        let name = deviceName(device)

        // Exclude Apple Vision Pro devices
        let excludedNamePatterns = ["Vision Pro", "Apple Vision"]
        for pattern in excludedNamePatterns {
            if name.localizedCaseInsensitiveContains(pattern) {
                let id = deviceIdentifier(device)
                if !loggedFilteredDeviceIDs.contains(id) {
                    loggedFilteredDeviceIDs.insert(id)
                    NSLog("[iPad Mirror] Filtering out non-iPad device: \(name)")
                }
                return false
            }
        }

        // If the framework exposes a model string, use it as an additional check.
        // Known model prefixes: "iPad" for iPads, "RealityDevice" for Vision Pro.
        if let model = device.value(forKey: "model") as? String {
            if model.localizedCaseInsensitiveContains("reality") || model.localizedCaseInsensitiveContains("vision") {
                let id = deviceIdentifier(device)
                if !loggedFilteredDeviceIDs.contains(id) {
                    loggedFilteredDeviceIDs.insert(id)
                    NSLog("[iPad Mirror] Filtering out non-iPad device by model: \(name) (\(model))")
                }
                return false
            }
        }

        return true
    }

    var connectedDeviceName: String? {
        connectedDevices.first.map { deviceName($0) }
    }

    var firstAvailableDevice: NSObject? {
        devices.first
    }

    func connect(to device: NSObject? = nil) async throws -> String {
        // If no device is visible yet, retry a few times — the iPad may take
        // a moment to reappear after a disconnect or wake.
        var target = device ?? firstAvailableDevice
        if target == nil {
            for attempt in 1...3 {
                NSLog("[iPad Mirror] No device found, waiting... (attempt \(attempt)/3)")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                target = firstAvailableDevice
                if target != nil { break }
            }
        }
        guard var target = target else {
            NSLog("[iPad Mirror] Connect failed: no iPad found after retries")
            SpeechManager.shared.speak("No iPad found.")
            throw SidecarError.noDeviceAvailable
        }

        // Prefer USB over Wi-Fi: if the selected device is Wi-Fi and a USB
        // variant exists for the same iPad, switch to the USB one.
        if device == nil {
            let usbDevice = devices.first { isUSBConnected($0) }
            if let usb = usbDevice {
                let usbName = deviceName(usb)
                if !isUSBConnected(target) {
                    NSLog("[iPad Mirror] Preferring USB connection to \(usbName) over Wi-Fi")
                    target = usb
                } else {
                    NSLog("[iPad Mirror] Already using USB connection to \(usbName)")
                }
            } else {
                NSLog("[iPad Mirror] No USB device found, using Wi-Fi")
            }
        }

        let name = deviceName(target)
        let targetID = deviceIdentifier(target)

        // If already "connected", disconnect first — the connection may be
        // stale (e.g. iPad went to sleep). Force a fresh connection.
        let connectedIDs = Set(connectedDevices.map { deviceIdentifier($0) })
        if connectedIDs.contains(targetID) {
            NSLog("[iPad Mirror] Device appears connected, forcing reconnect...")
            if let staleDevice = connectedDevices.first(where: { deviceIdentifier($0) == targetID }) {
                _ = try? await forceDisconnect(staleDevice)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        let result: String = try await withCheckedThrowingContinuation { continuation in
            let sel = NSSelectorFromString("connectToDevice:completion:")
            guard manager.responds(to: sel) else {
                continuation.resume(throwing: SidecarError.apiUnavailable)
                return
            }

            let block: @convention(block) (NSError?) -> Void = { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: "Connected to \(name)")
                }
            }

            manager.perform(sel, with: target, with: block)
        }

        lastConnectedDeviceID = targetID
        lastKnownDeviceID = targetID
        consecutiveFailures = 0
        isReconnecting = false
        Task { @MainActor in self.reconnectionState = .idle }
        startWatchdog()
        SidecarBridge.resetModifierKeys()
        SpeechManager.shared.speak("Connected to \(name)")
        DisplayManager.shared.takeoverIfEnabled()
        return result
    }

    func disconnect(from device: NSObject? = nil) async throws -> String {
        stopWatchdog()
        lastConnectedDeviceID = nil

        let target = device ?? connectedDevices.first
        guard let target = target else {
            throw SidecarError.notConnected
        }

        let name = deviceName(target)

        let result: String = try await withCheckedThrowingContinuation { continuation in
            let sel = NSSelectorFromString("disconnectFromDevice:completion:")
            guard manager.responds(to: sel) else {
                continuation.resume(throwing: SidecarError.apiUnavailable)
                return
            }

            let block: @convention(block) (NSError?) -> Void = { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: "Disconnected from \(name)")
                }
            }

            manager.perform(sel, with: target, with: block)
        }

        SpeechManager.shared.speak("Disconnected.")
        DisplayManager.shared.restoreIfNeeded()
        return result
    }

    /// Send key-up events for all modifier keys to prevent stuck modifiers
    /// after Sidecar connect/disconnect transitions.
    static func resetModifierKeys() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let src = CGEventSource(stateID: .hidSystemState)
            for keyCode: CGKeyCode in [56, 60, 55, 54, 59, 62, 58, 61] {
                // 56=LShift, 60=RShift, 55=LCmd, 54=RCmd,
                // 59=LCtrl, 62=RCtrl, 58=LOpt, 61=ROpt
                if let event = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) {
                    event.post(tap: .cghidEventTap)
                }
            }
            NSLog("[iPad Mirror] Modifier keys reset")
        }
    }

    /// Disconnect without clearing watchdog state — used internally for reconnect flows.
    private func forceDisconnect(_ device: NSObject) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let sel = NSSelectorFromString("disconnectFromDevice:completion:")
            guard manager.responds(to: sel) else {
                continuation.resume(throwing: SidecarError.apiUnavailable)
                return
            }
            let block: @convention(block) (NSError?) -> Void = { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
            manager.perform(sel, with: device, with: block)
        }
    }

    func toggle() async throws -> String {
        NSLog("[iPad Mirror] Toggle: isConnected=\(isConnected), devices=\(devices.count)")
        if isConnected {
            return try await disconnect()
        } else {
            return try await connect()
        }
    }

    // MARK: - Sleep/Wake Handling

    private func setupSleepWakeObservers() {
        let ws = NSWorkspace.shared.notificationCenter

        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            NSLog("[iPad Mirror] System going to sleep, cancelling watchdog")
            SpeechManager.shared.speak("Going to sleep.")
            self.isSuspendedForSleep = true
            // Kill the watchdog entirely so no queued Task.sleep calls can fire on wake.
            self.watchdogTask?.cancel()
            self.watchdogTask = nil
        }

        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            NSLog("[iPad Mirror] System woke up, starting 8s cooldown")
            self.isSuspendedForSleep = true  // Ensure set even if willSleep was missed
            self.dismissSidecarAlerts()
            Task {
                // Sweep for framework-shown alerts periodically during cooldown
                for _ in 0..<8 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    await MainActor.run { self.dismissSidecarAlerts() }
                }
                self.isSuspendedForSleep = false
                NSLog("[iPad Mirror] Post-wake cooldown complete")
                // Restart watchdog if we had an active connection before sleep
                if self.lastConnectedDeviceID != nil {
                    NSLog("[iPad Mirror] Restarting watchdog after wake")
                    SpeechManager.shared.speak("Reconnecting to iPad.")
                    self.startWatchdog()
                }
            }
        }

        // Catch SidecarCore error alerts whenever a panel becomes key (fast path).
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard notification.object is NSPanel else { return }
            self?.dismissSidecarAlerts()
        }

        // Also catch panels that appear without becoming key (e.g. stacked behind another).
        // didUpdateNotification fires on any window property change including visibility.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard notification.object is NSPanel else { return }
            self?.dismissSidecarAlerts()
        }
    }

    /// Strings that identify SidecarCore error alert panels.
    private static let sidecarAlertPatterns = [
        "Unable to Connect",
        "Cannot Connect",
        "Connection Failed",
        "timed out",
        "Wi-Fi",
        "Wi\u{2011}Fi",   // non-breaking hyphen variant Apple uses
        "WiFi",
        "Same Network",
        "same network",
        "mirroring",
        "AirPlay",
        "miscellaneous error",
        "-1010",
    ]

    /// Error substrings that indicate a non-transient conflict (another session is active).
    /// The watchdog should stop retrying when it hits one of these.
    private static let nonTransientErrorPatterns = [
        "mirroring",
        "AirPlay",
        "disconnect other",
    ]

    /// Start a repeating timer that sweeps for SidecarCore alert panels every 0.25s.
    /// This is a backup defense — the method-swizzle interceptor is the primary defense.
    /// The timer catches any alerts that slip through the interceptor (e.g. if the content
    /// view text wasn't set at the time orderFront: was called).
    private func startAlertSweepTimer() {
        alertSweepTimer?.invalidate()
        alertSweepTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.dismissSidecarAlerts()
        }
        // Allow the timer to fire even during modal sessions and event tracking
        RunLoop.main.add(alertSweepTimer!, forMode: .common)
    }

    /// Find and close any SidecarCore error alert panels.
    /// Uses aggressive dismissal: ends any modal session, orders the window out, then closes it.
    private func dismissSidecarAlerts() {
        for window in NSApp.windows {
            guard Self.isSidecarAlertPanel(window) else { continue }

            // Throttle logging to once per 30 seconds to avoid console spam
            let now = Date()
            if now.timeIntervalSince(lastAlertDismissTime) > 30 {
                NSLog("[iPad Mirror] Auto-dismissing SidecarCore error alert")
                lastAlertDismissTime = now
            }

            // End any modal session the alert may have started — without this,
            // close() on a modal panel can hang or be ignored.
            if NSApp.modalWindow == window {
                NSApp.abortModal()
            }

            // orderOut immediately removes from screen; close() releases it.
            window.orderOut(nil)
            window.close()
        }
    }

    /// Returns `true` if the window is a SidecarCore error alert that should be suppressed.
    /// Called from both the timer sweep and the method-swizzle interceptor.
    static func isSidecarAlertPanel(_ window: NSWindow) -> Bool {
        guard window is NSPanel, let contentView = window.contentView else { return false }
        return sidecarAlertPatterns.contains { viewTreeContainsText(contentView, matching: $0) }
    }

    private static func viewTreeContainsText(_ view: NSView, matching text: String) -> Bool {
        if let textField = view as? NSTextField,
           textField.stringValue.localizedCaseInsensitiveContains(text) {
            return true
        }
        return view.subviews.contains { viewTreeContainsText($0, matching: text) }
    }

    // MARK: - Connection Watchdog

    /// Computes the poll interval in nanoseconds using exponential backoff.
    /// Base interval is 10s, doubling each failure, capped at 180s (3 minutes).
    private func watchdogInterval() -> UInt64 {
        let baseSeconds: UInt64 = 10
        let maxSeconds: UInt64 = 180
        let backoffSeconds = min(baseSeconds * (1 << UInt64(consecutiveFailures)), maxSeconds)
        return backoffSeconds * 1_000_000_000
    }

    /// Polls connection state and auto-reconnects if the connection drops unexpectedly.
    /// Uses exponential backoff and gives up after `maxReconnectAttempts` consecutive failures.
    func startWatchdog() {
        stopWatchdog()
        consecutiveFailures = 0
        Task { @MainActor in self.reconnectionState = .idle }

        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                let interval = self.watchdogInterval()
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { return }

                guard !self.isSuspendedForSleep else {
                    NSLog("[iPad Mirror] System asleep/waking, skipping reconnect")
                    continue
                }

                // Only attempt reconnect if we were previously connected
                guard !self.isConnected, self.lastConnectedDeviceID != nil else {
                    // Connection is fine or user disconnected intentionally; reset failures
                    if self.isConnected && self.consecutiveFailures > 0 {
                        self.consecutiveFailures = 0
                        Task { @MainActor in self.reconnectionState = .idle }
                    }
                    continue
                }

                // Check if we have exhausted retries
                if self.consecutiveFailures >= self.maxReconnectAttempts {
                    NSLog("[iPad Mirror] Reconnect abandoned after \(self.maxReconnectAttempts) attempts")
                    SpeechManager.shared.speak("Reconnection failed.")
                    self.lastConnectedDeviceID = nil
                    Task { @MainActor in self.reconnectionState = .failed }
                    return // Stop the watchdog loop
                }

                // Prevent overlapping reconnection attempts
                guard !self.isReconnecting else {
                    NSLog("[iPad Mirror] Reconnect already in progress, skipping")
                    continue
                }

                self.consecutiveFailures += 1
                let attempt = self.consecutiveFailures
                NSLog("[iPad Mirror] Connection dropped, attempting reconnect (attempt \(attempt)/\(self.maxReconnectAttempts))...")
                SpeechManager.shared.speak("Connection lost. Attempt \(attempt) of 5.")
                Task { @MainActor in self.reconnectionState = .retrying(attempt: attempt) }

                // Wait for network to settle
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }

                // Re-check — might have come back on its own
                if self.isConnected {
                    self.consecutiveFailures = 0
                    Task { @MainActor in self.reconnectionState = .idle }
                    continue
                }

                // Pre-flight: check if any device is visible before calling the framework
                guard self.devices.first(where: { self.deviceIdentifier($0) == self.lastConnectedDeviceID }) != nil
                        || self.firstAvailableDevice != nil else {
                    NSLog("[iPad Mirror] No device visible, skipping framework call (attempt \(attempt)/\(self.maxReconnectAttempts))")
                    continue
                }

                self.isReconnecting = true
                do {
                    let result = try await self.reconnect()
                    NSLog("[iPad Mirror] \(result)")
                    self.consecutiveFailures = 0
                    self.isReconnecting = false
                    Task { @MainActor in self.reconnectionState = .idle }
                    SidecarBridge.resetModifierKeys()
                    SpeechManager.shared.speak("Reconnected.")
                    DisplayManager.shared.takeoverIfEnabled()
                } catch {
                    self.isReconnecting = false
                    let desc = error.localizedDescription
                    NSLog("[iPad Mirror] Reconnect failed (attempt \(attempt)/\(self.maxReconnectAttempts)): \(desc)")

                    // Dismiss any SidecarCore error alerts spawned by the failed attempt,
                    // then wait briefly — the framework may take a moment to show the alert.
                    await MainActor.run { self.dismissSidecarAlerts() }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    await MainActor.run { self.dismissSidecarAlerts() }

                    // If the error is a non-transient conflict (e.g. another AirPlay/mirroring
                    // session is active), stop retrying — it won't resolve on its own.
                    let isConflict = Self.nonTransientErrorPatterns.contains { desc.localizedCaseInsensitiveContains($0) }
                    if isConflict {
                        NSLog("[iPad Mirror] Non-transient conflict detected, stopping watchdog: \(desc)")
                        SpeechManager.shared.speak("Another mirroring session is active. Disconnect it first.")
                        self.lastConnectedDeviceID = nil
                        Task { @MainActor in self.reconnectionState = .failed }
                        return
                    }
                }
            }
        }
    }

    func stopWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
        consecutiveFailures = 0
        isReconnecting = false
        Task { @MainActor in self.reconnectionState = .idle }
    }

    /// Manually retries reconnection after the watchdog has given up.
    /// Call this from the UI when the user clicks "Retry".
    func retryReconnection() {
        // Restore the last connected device ID if watchdog cleared it on failure
        if lastConnectedDeviceID == nil, let knownID = lastKnownDeviceID {
            lastConnectedDeviceID = knownID
        }
        NSLog("[iPad Mirror] User-initiated reconnection retry")
        consecutiveFailures = 0
        isReconnecting = false
        startWatchdog()
        // Also attempt an immediate connect
        Task {
            _ = try? await self.connect()
        }
    }

    private func reconnect() async throws -> String {
        guard !isSuspendedForSleep else {
            NSLog("[iPad Mirror] reconnect() blocked — system asleep/waking")
            throw SidecarError.noDeviceAvailable
        }
        guard let targetID = lastConnectedDeviceID else {
            throw SidecarError.noDeviceAvailable
        }

        let target = devices.first { deviceIdentifier($0) == targetID } ?? firstAvailableDevice
        guard let target = target else {
            throw SidecarError.noDeviceAvailable
        }

        let name = deviceName(target)

        return try await withCheckedThrowingContinuation { continuation in
            let sel = NSSelectorFromString("connectToDevice:completion:")
            guard manager.responds(to: sel) else {
                continuation.resume(throwing: SidecarError.apiUnavailable)
                return
            }

            let block: @convention(block) (NSError?) -> Void = { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: "Reconnected to \(name)")
                }
            }

            manager.perform(sel, with: target, with: block)
        }
    }
}

enum SidecarError: LocalizedError {
    case noDeviceAvailable
    case notConnected
    case apiUnavailable

    var errorDescription: String? {
        switch self {
        case .noDeviceAvailable:
            return "No iPad found nearby. Make sure your iPad is on the same Wi-Fi and signed into the same Apple ID."
        case .notConnected:
            return "No iPad is currently connected."
        case .apiUnavailable:
            return "Sidecar API not available on this system."
        }
    }
}

// MARK: - NSWindow Alert Interceptor (Method Swizzling)

extension NSWindow {
    /// Swizzled replacement for `orderFront:`. Suppresses SidecarCore alert panels
    /// before they are ever rendered, preventing alert accumulation.
    @objc func ipm_orderFront(_ sender: Any?) {
        // Call original first (implementations are swapped, so this calls real orderFront:)
        self.ipm_orderFront(sender)
        // If this is a SidecarCore alert, immediately yank it off screen and close it.
        // Both calls happen in the same run-loop turn so the panel is never rendered.
        if SidecarBridge.isSidecarAlertPanel(self) {
            if NSApp.modalWindow == self { NSApp.abortModal() }
            self.orderOut(nil)
            self.close()
        }
    }

    /// Swizzled replacement for `makeKeyAndOrderFront:`.
    @objc func ipm_makeKeyAndOrderFront(_ sender: Any?) {
        self.ipm_makeKeyAndOrderFront(sender)
        if SidecarBridge.isSidecarAlertPanel(self) {
            if NSApp.modalWindow == self { NSApp.abortModal() }
            self.orderOut(nil)
            self.close()
        }
    }
}
