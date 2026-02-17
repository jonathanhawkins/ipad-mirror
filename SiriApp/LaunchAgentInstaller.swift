import Foundation

struct LaunchAgentInstaller {
    static let label = "com.user.ipad-mirror"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func install() throws {
        let dir = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "ipadmirror://connect"],
            "RunAtLoad": true,
            "StandardOutPath": "/tmp/ipad-mirror.log",
            "StandardErrorPath": "/tmp/ipad-mirror.log",
        ]

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL)

        // Load the agent
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["load", plistURL.path]
        try process.run()
        process.waitUntilExit()

        NSLog("[iPad Mirror] LaunchAgent installed at \(plistURL.path)")
    }

    static func uninstall() throws {
        guard isInstalled else { return }

        // Unload the agent
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["unload", plistURL.path]
        try process.run()
        process.waitUntilExit()

        try FileManager.default.removeItem(at: plistURL)
        NSLog("[iPad Mirror] LaunchAgent uninstalled")
    }
}
