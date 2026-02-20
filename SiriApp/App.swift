import SwiftUI
import AppIntents

@main
struct iPadMirrorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var isConnected = SidecarBridge.shared.isConnected
    @State private var reconnectionState: ReconnectionState = .idle

    init() {
        iPadMirrorShortcuts.updateAppShortcutParameters()
        donateIntents()
    }

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 4) {
                if let name = SidecarBridge.shared.connectedDeviceName {
                    Text("Connected to \(name)")
                        .font(.headline)

                    Button("Disconnect") {
                        Task {
                            _ = try? await SidecarBridge.shared.disconnect()
                            isConnected = SidecarBridge.shared.isConnected
                        }
                    }
                } else if case .retrying(let attempt) = reconnectionState {
                    Text("Reconnecting... (attempt \(attempt)/5)")
                        .font(.headline)
                        .foregroundStyle(.orange)

                    Text("iPad connection was lost")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Cancel Reconnect") {
                        SidecarBridge.shared.stopWatchdog()
                        isConnected = SidecarBridge.shared.isConnected
                        reconnectionState = .idle
                    }
                } else if case .failed = reconnectionState {
                    Text("Reconnection Failed")
                        .font(.headline)
                        .foregroundStyle(.red)

                    Text("Could not reach iPad after multiple attempts")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Retry Connection") {
                        SidecarBridge.shared.retryReconnection()
                    }
                } else if let device = SidecarBridge.shared.firstAvailableDevice {
                    Text("\(SidecarBridge.shared.deviceName(device)) available")
                        .font(.headline)

                    Button("Connect") {
                        Task {
                            _ = try? await SidecarBridge.shared.connect()
                            isConnected = SidecarBridge.shared.isConnected
                        }
                    }
                } else {
                    Text("No iPad found")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }

                Divider()

                Button("Refresh") {
                    isConnected = SidecarBridge.shared.isConnected
                }
                .keyboardShortcut("r")

                Button("Reset Keyboard") {
                    SidecarBridge.resetModifierKeys()
                }

                Button("Setup...") {
                    appDelegate.showOnboarding()
                }

                Button("Quit iPad Mirror") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .padding(4)
            .task {
                // Subscribe to reconnection state changes from the bridge
                await MainActor.run {
                    SidecarBridge.shared.reconnectionStateCallback = { newState in
                        self.reconnectionState = newState
                        self.isConnected = SidecarBridge.shared.isConnected
                    }
                }
            }
        } label: {
            Image(systemName: menuBarIcon)
        }
    }

    private var menuBarIcon: String {
        switch reconnectionState {
        case .retrying:
            return "ipad.badge.exclamationmark"
        case .failed:
            return "ipad.slash"
        case .idle:
            return isConnected ? "ipad.and.arrow.forward" : "ipad"
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register global hotkey if previously configured
        if GlobalHotKey.shared.isEnabled {
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

        // Show onboarding on first run
        if SetupManager.shared.needsOnboarding {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.showOnboarding()
            }
        }
    }

    // MARK: - URL Scheme Handler

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme == "ipadmirror" else { continue }
            let command = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            NSLog("[iPad Mirror] URL command: \(command)")

            Task {
                switch command.lowercased() {
                case "connect":
                    _ = try? await SidecarBridge.shared.connect()
                case "disconnect":
                    _ = try? await SidecarBridge.shared.disconnect()
                case "toggle":
                    _ = try? await SidecarBridge.shared.toggle()
                default:
                    NSLog("[iPad Mirror] Unknown URL command: \(command)")
                }
            }
        }
    }

    // MARK: - Onboarding Window

    func showOnboarding() {
        if let window = onboardingWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = OnboardingView {
            self.onboardingWindow?.close()
            self.onboardingWindow = nil
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "iPad Mirror Setup"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        onboardingWindow = window
    }
}
