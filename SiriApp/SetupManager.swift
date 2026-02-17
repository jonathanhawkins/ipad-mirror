import Foundation
import SwiftUI

@MainActor
final class SetupManager: ObservableObject {
    static let shared = SetupManager()

    private let hasCompletedOnboardingKey = "hasCompletedOnboarding"

    @Published var shortcutsInstalled: Bool = false
    @Published var launchAgentInstalled: Bool = false
    @Published var hotKeyEnabled: Bool = false
    @Published var isSettingUp: Bool = false
    @Published var setupProgress: String = ""

    var needsOnboarding: Bool {
        !UserDefaults.standard.bool(forKey: hasCompletedOnboardingKey)
    }

    init() {
        refresh()
    }

    func refresh() {
        shortcutsInstalled = ShortcutInstaller.allInstalled
        launchAgentInstalled = LaunchAgentInstaller.isInstalled
        hotKeyEnabled = GlobalHotKey.shared.isEnabled
    }

    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: hasCompletedOnboardingKey)
    }

    func resetOnboarding() {
        UserDefaults.standard.set(false, forKey: hasCompletedOnboardingKey)
    }

    func runSetup(
        installShortcuts: Bool,
        installLaunchAgent: Bool,
        installHotKey: Bool
    ) async {
        isSettingUp = true

        if installShortcuts && !shortcutsInstalled {
            setupProgress = "Installing Siri Shortcuts..."
            let count = await ShortcutInstaller.installMissing()
            NSLog("[iPad Mirror] Installed \(count) shortcuts")
            // Wait a moment for user to finish clicking import dialogs
            if count > 0 {
                setupProgress = "Click \"Add Shortcut\" for each dialog..."
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }

        if installLaunchAgent && !launchAgentInstalled {
            setupProgress = "Setting up auto-connect on login..."
            do {
                try LaunchAgentInstaller.install()
            } catch {
                NSLog("[iPad Mirror] LaunchAgent install failed: \(error)")
            }
        }

        if installHotKey && !hotKeyEnabled {
            setupProgress = "Registering keyboard shortcut..."
            GlobalHotKey.shared.register {
                Task {
                    do {
                        let result = try await SidecarBridge.shared.toggle()
                        NSLog("[iPad Mirror] Hotkey toggle: \(result)")
                    } catch {
                        NSLog("[iPad Mirror] Hotkey toggle failed: \(error.localizedDescription)")
                    }
                }
            }
        }

        setupProgress = "Done!"
        refresh()
        completeOnboarding()

        try? await Task.sleep(nanoseconds: 500_000_000)
        isSettingUp = false
    }
}
