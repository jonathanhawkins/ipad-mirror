import Foundation
import ObjectiveC
import CoreGraphics

/// Loads the private SidecarCore framework and provides access to Sidecar display management.
final class SidecarBridge: @unchecked Sendable {
    static let shared = SidecarBridge()

    private let manager: NSObject
    private var watchdogTask: Task<Void, Never>?

    /// The identifier of the device we last connected to, for auto-reconnect.
    private var lastConnectedDeviceID: String?

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

        // Already connected?
        let connectedIDs = Set(connectedDevices.map { deviceIdentifier($0) })
        if connectedIDs.contains(targetID) {
            lastConnectedDeviceID = targetID
            startWatchdog()
            return "Already connected to \(name)"
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

    func toggle() async throws -> String {
        NSLog("[iPad Mirror] Toggle: isConnected=\(isConnected), devices=\(devices.count)")
        if isConnected {
            return try await disconnect()
        } else {
            return try await connect()
        }
    }

    // MARK: - Connection Watchdog

    /// Polls connection state and auto-reconnects if the connection drops unexpectedly.
    func startWatchdog() {
        stopWatchdog()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // check every 10s
                guard !Task.isCancelled, let self = self else { return }

                if !self.isConnected, self.lastConnectedDeviceID != nil {
                    NSLog("[iPad Mirror] Connection dropped, attempting reconnect...")

                    // Wait for network to settle
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard !Task.isCancelled else { return }

                    // Re-check — might have come back on its own
                    if !self.isConnected {
                        do {
                            let result = try await self.reconnect()
                            NSLog("[iPad Mirror] \(result)")
                            SidecarBridge.resetModifierKeys()
                        } catch {
                            NSLog("[iPad Mirror] Reconnect failed: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
    }

    func stopWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
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
