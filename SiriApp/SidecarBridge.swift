import Foundation
import ObjectiveC
import CoreGraphics

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

    /// Observable reconnection state for the UI to display.
    @MainActor var reconnectionState: ReconnectionState = .idle {
        didSet {
            reconnectionStateCallback?(reconnectionState)
        }
    }

    /// Callback invoked on the main actor when reconnection state changes.
    /// Set this from the UI layer to react to state transitions.
    @MainActor var reconnectionStateCallback: ((ReconnectionState) -> Void)?

    init() {
        guard let bundle = Bundle(path: "/System/Library/PrivateFrameworks/SidecarCore.framework") else {
            fatalError("SidecarCore.framework not found")
        }
        bundle.load()

        guard let managerClass = NSClassFromString("SidecarDisplayManager") as? NSObject.Type else {
            fatalError("SidecarDisplayManager class not found")
        }
        manager = managerClass.init()
    }

    var devices: [NSObject] {
        (manager.value(forKey: "devices") as? [NSObject]) ?? []
    }

    var connectedDevices: [NSObject] {
        (manager.value(forKey: "connectedDevices") as? [NSObject]) ?? []
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
        guard let target = target else {
            NSLog("[iPad Mirror] Connect failed: no iPad found after retries")
            throw SidecarError.noDeviceAvailable
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
                    continuation.resume(returning: "Disconnected from \(name)")
                }
            }

            manager.perform(sel, with: target, with: block)
        }
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
                } catch {
                    self.isReconnecting = false
                    NSLog("[iPad Mirror] Reconnect failed (attempt \(attempt)/\(self.maxReconnectAttempts)): \(error.localizedDescription)")
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
