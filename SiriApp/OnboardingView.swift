import SwiftUI

struct OnboardingView: View {
    @ObservedObject var setup = SetupManager.shared
    @State private var installShortcuts = true
    @State private var installLaunchAgent = true
    @State private var installHotKey = true

    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to iPad Mirror")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Let's set up your iPad as a second display.")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Options
            VStack(alignment: .leading, spacing: 14) {
                OptionRow(
                    enabled: $installShortcuts,
                    title: "Siri Shortcuts",
                    description: "Creates voice commands: \"Connect iPad Mirror\", \"Disconnect iPad Mirror\", \"Toggle iPad Mirror\"",
                    installed: setup.shortcutsInstalled,
                    disabled: setup.isSettingUp
                )

                OptionRow(
                    enabled: $installLaunchAgent,
                    title: "Auto-Connect on Login",
                    description: "Automatically connects your iPad when you log in to your Mac",
                    installed: setup.launchAgentInstalled,
                    disabled: setup.isSettingUp
                )

                OptionRow(
                    enabled: $installHotKey,
                    title: "Global Keyboard Shortcut",
                    description: "Toggle your iPad connection with \(GlobalHotKey.shared.displayString)",
                    installed: setup.hotKeyEnabled,
                    disabled: setup.isSettingUp
                )
            }

            Divider()

            // Progress
            if setup.isSettingUp {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text(setup.setupProgress)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }

            // Buttons
            HStack {
                Button("Skip") {
                    setup.completeOnboarding()
                    onDismiss()
                }
                .disabled(setup.isSettingUp)

                Spacer()

                Button(action: {
                    Task {
                        await setup.runSetup(
                            installShortcuts: installShortcuts,
                            installLaunchAgent: installLaunchAgent,
                            installHotKey: installHotKey
                        )
                        onDismiss()
                    }
                }) {
                    Text("Set Up Selected")
                        .frame(minWidth: 120)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(setup.isSettingUp || (!installShortcuts && !installLaunchAgent && !installHotKey))
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            setup.refresh()
            installShortcuts = !setup.shortcutsInstalled
            installLaunchAgent = !setup.launchAgentInstalled
            installHotKey = !setup.hotKeyEnabled
        }
    }
}

struct OptionRow: View {
    @Binding var enabled: Bool
    let title: String
    let description: String
    let installed: Bool
    let disabled: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: $enabled)
                .toggleStyle(.checkbox)
                .disabled(installed || disabled)
                .labelsHidden()
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .fontWeight(.medium)
                    if installed {
                        Text("Installed")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.green.opacity(0.15))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                    }
                }
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
