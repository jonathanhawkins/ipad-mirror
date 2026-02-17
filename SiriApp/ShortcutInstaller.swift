import Foundation

struct ShortcutInstaller {
    struct ShortcutDef {
        let name: String
        let url: String
        let iconColor: Int
    }

    static let shortcuts: [ShortcutDef] = [
        ShortcutDef(name: "Connect iPad Mirror", url: "ipadmirror://connect", iconColor: 463140863),
        ShortcutDef(name: "Disconnect iPad Mirror", url: "ipadmirror://disconnect", iconColor: 4282601983),
        ShortcutDef(name: "Toggle iPad Mirror", url: "ipadmirror://toggle", iconColor: 1440408063),
    ]

    /// Check which shortcuts are already installed by running `shortcuts list`
    static func installedShortcuts() -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            let names = Set(output.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
            return names
        } catch {
            NSLog("[iPad Mirror] Failed to list shortcuts: \(error)")
            return []
        }
    }

    static var allInstalled: Bool {
        let installed = installedShortcuts()
        return shortcuts.allSatisfy { installed.contains($0.name) }
    }

    /// Install all missing shortcuts. Returns the count installed.
    static func installMissing() async -> Int {
        let installed = installedShortcuts()
        var count = 0

        for shortcut in shortcuts {
            if installed.contains(shortcut.name) {
                NSLog("[iPad Mirror] Shortcut '\(shortcut.name)' already installed, skipping")
                continue
            }

            do {
                try await installShortcut(shortcut)
                count += 1
                // Brief pause between imports so dialogs don't stack
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                NSLog("[iPad Mirror] Failed to install shortcut '\(shortcut.name)': \(error)")
            }
        }

        return count
    }

    private static func installShortcut(_ def: ShortcutDef) async throws {
        let plist = buildPlist(name: def.name, url: def.url, iconColor: def.iconColor)
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .binary, options: 0)

        let tempDir = FileManager.default.temporaryDirectory
        let unsignedPath = tempDir.appendingPathComponent("\(def.name).unsigned.shortcut")
        let signedPath = tempDir.appendingPathComponent("\(def.name).shortcut")

        try data.write(to: unsignedPath)

        // Sign the shortcut
        let signProcess = Process()
        signProcess.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        signProcess.arguments = [
            "sign", "--mode", "anyone",
            "--input", unsignedPath.path,
            "--output", signedPath.path,
        ]
        signProcess.standardError = FileHandle.nullDevice
        try signProcess.run()
        signProcess.waitUntilExit()

        guard FileManager.default.fileExists(atPath: signedPath.path) else {
            throw NSError(domain: "ShortcutInstaller", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Signing failed for \(def.name)"])
        }

        // Open the signed shortcut to trigger the import dialog
        let openProcess = Process()
        openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openProcess.arguments = [signedPath.path]
        try openProcess.run()
        openProcess.waitUntilExit()

        NSLog("[iPad Mirror] Opened shortcut for import: \(def.name)")

        // Clean up unsigned file
        try? FileManager.default.removeItem(at: unsignedPath)
    }

    private static func buildPlist(name: String, url: String, iconColor: Int) -> [String: Any] {
        [
            "WFQuickActionSurfaces": [] as [Any],
            "WFWorkflowActions": [
                [
                    "WFWorkflowActionIdentifier": "is.workflow.actions.openurl",
                    "WFWorkflowActionParameters": [
                        "WFInput": [
                            "Value": [
                                "WFSerializationType": "WFTextTokenString",
                                "Value": [
                                    "attachmentsByRange": [:] as [String: Any],
                                    "string": url,
                                ],
                            ] as [String: Any],
                        ] as [String: Any],
                    ] as [String: Any],
                ] as [String: Any],
            ] as [[String: Any]],
            "WFWorkflowClientVersion": "2302.0.4",
            "WFWorkflowHasOutputFallback": false,
            "WFWorkflowHasShortcutInputVariables": false,
            "WFWorkflowIcon": [
                "WFWorkflowIconGlyphNumber": 59572,
                "WFWorkflowIconStartColor": iconColor,
            ] as [String: Any],
            "WFWorkflowImportQuestions": [] as [Any],
            "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowName": name,
            "WFWorkflowOutputContentItemClasses": [] as [Any],
            "WFWorkflowTypes": [] as [Any],
        ]
    }
}
