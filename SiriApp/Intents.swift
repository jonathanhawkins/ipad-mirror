import AppIntents

// MARK: - Connect Intent

struct ConnectIPadIntent: AppIntent {
    static var title: LocalizedStringResource = "Connect iPad Display"
    static var description: IntentDescription = IntentDescription(
        "Connects your iPad as a Sidecar display.",
        categoryName: "Display"
    )
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await SidecarBridge.shared.connect()
        return .result(dialog: "\(result)")
    }
}

// MARK: - Disconnect Intent

struct DisconnectIPadIntent: AppIntent {
    static var title: LocalizedStringResource = "Disconnect iPad Display"
    static var description: IntentDescription = IntentDescription(
        "Disconnects your iPad Sidecar display.",
        categoryName: "Display"
    )
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await SidecarBridge.shared.disconnect()
        return .result(dialog: "\(result)")
    }
}

// MARK: - Toggle Intent

struct ToggleIPadIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle iPad Display"
    static var description: IntentDescription = IntentDescription(
        "Toggles the iPad Sidecar display connection on or off.",
        categoryName: "Display"
    )
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await SidecarBridge.shared.toggle()
        return .result(dialog: "\(result)")
    }
}

// MARK: - Status Intent

struct IPadStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "iPad Display Status"
    static var description: IntentDescription = IntentDescription(
        "Checks the current iPad Sidecar display connection status.",
        categoryName: "Display"
    )
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let bridge = SidecarBridge.shared
        if let name = bridge.connectedDeviceName {
            return .result(dialog: "Connected to \(name)")
        } else if let device = bridge.firstAvailableDevice {
            return .result(dialog: "\(bridge.deviceName(device)) is available but not connected")
        } else {
            return .result(dialog: "No iPad found nearby")
        }
    }
}

// MARK: - Intent Donation

/// Donates all intents to the system to boost Siri discoverability.
/// Called on app launch to ensure Siri knows about these actions.
func donateIntents() {
    Task {
        let connectIntent = ConnectIPadIntent()
        let disconnectIntent = DisconnectIPadIntent()
        let toggleIntent = ToggleIPadIntent()
        let statusIntent = IPadStatusIntent()

        // Donate each intent so Siri indexes them
        _ = try? await connectIntent.donate()
        _ = try? await disconnectIntent.donate()
        _ = try? await toggleIntent.donate()
        _ = try? await statusIntent.donate()

        NSLog("[iPad Mirror] Donated all intents to Siri")
    }
}

// MARK: - App Shortcuts (Siri Phrases)

struct iPadMirrorShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConnectIPadIntent(),
            phrases: [
                "Connect \(.applicationName)",
                "Connect to \(.applicationName)",
                "Start \(.applicationName)",
                "Turn on \(.applicationName)",
            ],
            shortTitle: "Connect iPad",
            systemImageName: "ipad.and.arrow.forward"
        )

        AppShortcut(
            intent: DisconnectIPadIntent(),
            phrases: [
                "Disconnect \(.applicationName)",
                "Disconnect from \(.applicationName)",
                "Stop \(.applicationName)",
                "Turn off \(.applicationName)",
            ],
            shortTitle: "Disconnect iPad",
            systemImageName: "ipad"
        )

        AppShortcut(
            intent: ToggleIPadIntent(),
            phrases: [
                "Toggle \(.applicationName)",
                "Switch \(.applicationName)",
            ],
            shortTitle: "Toggle iPad",
            systemImageName: "arrow.triangle.2.circlepath"
        )

        AppShortcut(
            intent: IPadStatusIntent(),
            phrases: [
                "Is \(.applicationName) connected",
                "\(.applicationName) status",
            ],
            shortTitle: "iPad Status",
            systemImageName: "info.circle"
        )
    }
}
