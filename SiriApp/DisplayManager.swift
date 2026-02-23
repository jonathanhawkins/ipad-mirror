import Foundation
import CoreGraphics
import AppKit

/// Handles display takeover for Broken Screen Mode.
/// After Sidecar connects, moves the iPad display to origin (0,0) making
/// it the primary display (menu bar), and repositions all windows onto it.
final class DisplayManager: @unchecked Sendable {
    static let shared = DisplayManager()

    /// Saved display origins so we can restore on disconnect.
    private var savedOrigins: [CGDirectDisplayID: CGPoint] = [:]

    private var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "brokenScreenModeEnabled")
    }

    /// After a 2-second delay (for Sidecar display to register), makes the
    /// iPad display primary by moving it to origin (0,0).
    func takeoverIfEnabled() {
        guard isEnabled else { return }
        // Delay to let the Sidecar display register with the system
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.performTakeover()
        }
    }

    /// Restores original display layout if we previously saved origins.
    func restoreIfNeeded() {
        guard !savedOrigins.isEmpty else { return }
        performRestore()
    }

    // MARK: - Private

    private func performTakeover() {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var displayCount: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &displayIDs, &displayCount) == .success,
              displayCount > 1 else {
            NSLog("[iPad Mirror] Display takeover: not enough displays (\(displayCount))")
            return
        }

        let activeDisplays = Array(displayIDs.prefix(Int(displayCount)))

        // Find the first non-built-in display (the iPad via Sidecar)
        guard let iPadDisplay = activeDisplays.first(where: { CGDisplayIsBuiltin($0) == 0 }) else {
            NSLog("[iPad Mirror] Display takeover: no external display found")
            return
        }

        // Save current origins for all displays
        savedOrigins.removeAll()
        for id in activeDisplays {
            let bounds = CGDisplayBounds(id)
            savedOrigins[id] = bounds.origin
        }

        let iPadBounds = CGDisplayBounds(iPadDisplay)
        let builtinDisplay = activeDisplays.first(where: { CGDisplayIsBuiltin($0) != 0 })

        // Move iPad to (0,0) to make it primary; shift built-in to the right
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else {
            NSLog("[iPad Mirror] Display takeover: CGBeginDisplayConfiguration failed")
            return
        }

        // Move iPad to origin — this makes it the primary (menu bar) display
        CGConfigureDisplayOrigin(config, iPadDisplay, 0, 0)

        // Move built-in display to the right of the iPad
        if let builtinID = builtinDisplay {
            CGConfigureDisplayOrigin(config, builtinID, Int32(iPadBounds.width), 0)
        }

        let result = CGCompleteDisplayConfiguration(config, .forSession)
        if result == .success {
            NSLog("[iPad Mirror] Display takeover: iPad is now primary")
            // Move all windows to the iPad display
            moveAllWindowsToDisplay(iPadDisplay)
        } else {
            NSLog("[iPad Mirror] Display takeover: CGCompleteDisplayConfiguration failed (\(result.rawValue))")
        }
    }

    private func performRestore() {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else {
            NSLog("[iPad Mirror] Display restore: CGBeginDisplayConfiguration failed")
            return
        }

        for (displayID, origin) in savedOrigins {
            CGConfigureDisplayOrigin(config, displayID, Int32(origin.x), Int32(origin.y))
        }

        let result = CGCompleteDisplayConfiguration(config, .forSession)
        if result == .success {
            NSLog("[iPad Mirror] Display restore: original layout restored")
        } else {
            NSLog("[iPad Mirror] Display restore: CGCompleteDisplayConfiguration failed (\(result.rawValue))")
        }

        savedOrigins.removeAll()
    }

    /// Moves all visible application windows to the target display using AppleScript.
    private func moveAllWindowsToDisplay(_ displayID: CGDirectDisplayID) {
        let bounds = CGDisplayBounds(displayID)
        let x = Int(bounds.origin.x) + 50
        let y = Int(bounds.origin.y) + 50

        let script = """
        tell application "System Events"
            set appProcesses to every process whose visible is true
            repeat with proc in appProcesses
                try
                    set wins to every window of proc
                    repeat with w in wins
                        set position of w to {\(x), \(y)}
                    end repeat
                end try
            end repeat
        end tell
        """

        if let appleScript = NSAppleScript(source: script) {
            var errorDict: NSDictionary?
            appleScript.executeAndReturnError(&errorDict)
            if let error = errorDict {
                NSLog("[iPad Mirror] Window move AppleScript error: \(error)")
            } else {
                NSLog("[iPad Mirror] Moved all windows to iPad display")
            }
        }
    }
}
