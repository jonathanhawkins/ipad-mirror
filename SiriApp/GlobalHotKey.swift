import Cocoa
import Carbon.HIToolbox

/// Global hotkey using the Carbon RegisterEventHotKey API.
/// Much more reliable than NSEvent.addGlobalMonitorForEvents.
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    private var hotKeyRef: EventHotKeyRef?
    private var callback: (() -> Void)?

    // UserDefaults keys
    private let enabledKey = "globalHotKeyEnabled"
    private let keyCodeKey = "globalHotKeyCode"
    private let modifiersKey = "globalHotKeyModifiers"

    // Default: Ctrl+Option+Cmd+I
    var keyCode: UInt16 {
        get {
            let val = UserDefaults.standard.integer(forKey: keyCodeKey)
            return val == 0 ? UInt16(kVK_ANSI_I) : UInt16(val)
        }
        set { UserDefaults.standard.set(Int(newValue), forKey: keyCodeKey) }
    }

    var modifierFlags: NSEvent.ModifierFlags {
        get {
            let raw = UserDefaults.standard.integer(forKey: modifiersKey)
            if raw == 0 {
                return [.control, .option, .command]
            }
            return NSEvent.ModifierFlags(rawValue: UInt(raw))
        }
        set { UserDefaults.standard.set(Int(newValue.rawValue), forKey: modifiersKey) }
    }

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    var displayString: String {
        var parts: [String] = []
        let m = modifierFlags
        if m.contains(.control) { parts.append("⌃") }
        if m.contains(.option) { parts.append("⌥") }
        if m.contains(.shift) { parts.append("⇧") }
        if m.contains(.command) { parts.append("⌘") }
        parts.append(keyCodeToString(keyCode))
        return parts.joined()
    }

    func register(callback: @escaping () -> Void) {
        self.callback = callback
        unregister()

        // Convert NSEvent modifier flags to Carbon modifier flags
        let carbonModifiers = carbonModifierFlags(from: modifierFlags)

        // Install the event handler (idempotent — only installs once)
        installCarbonEventHandler()

        // Register the hotkey with the system
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x49504D48) // "IPMH" — iPad Mirror Hotkey
        hotKeyID.id = 1

        let status = RegisterEventHotKey(
            UInt32(keyCode),
            carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status == noErr {
            isEnabled = true
            NSLog("[iPad Mirror] Carbon hotkey registered: \(displayString)")
            logToFile("Carbon hotkey registered: \(displayString)")
        } else {
            NSLog("[iPad Mirror] Failed to register Carbon hotkey: \(status)")
            logToFile("Failed to register Carbon hotkey: \(status)")
        }
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    func setHotKey(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifierFlags = modifiers
        if let cb = callback {
            register(callback: cb)
        }
    }

    // MARK: - Carbon Event Handler

    private static var handlerInstalled = false

    private func installCarbonEventHandler() {
        guard !Self.handlerInstalled else { return }
        Self.handlerInstalled = true

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, _) -> OSStatus in
                GlobalHotKey.shared.handleCarbonHotKey(event)
                return noErr
            },
            1,
            &eventType,
            nil,
            nil
        )
    }

    private func handleCarbonHotKey(_ event: EventRef?) {
        guard event != nil else { return }
        NSLog("[iPad Mirror] Hotkey triggered")
        logToFile("Hotkey triggered")
        callback?()
    }

    private func logToFile(_ message: String) {
        let path = "/tmp/iPadMirror.log"
        let line = "\(Date()): \(message)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
        }
    }

    // MARK: - Helpers

    private func carbonModifierFlags(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option)  { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift)   { carbon |= UInt32(shiftKey) }
        return carbon
    }

    private func keyCodeToString(_ code: UInt16) -> String {
        let map: [UInt16: String] = [
            UInt16(kVK_ANSI_A): "A", UInt16(kVK_ANSI_S): "S",
            UInt16(kVK_ANSI_D): "D", UInt16(kVK_ANSI_F): "F",
            UInt16(kVK_ANSI_H): "H", UInt16(kVK_ANSI_G): "G",
            UInt16(kVK_ANSI_Z): "Z", UInt16(kVK_ANSI_X): "X",
            UInt16(kVK_ANSI_C): "C", UInt16(kVK_ANSI_V): "V",
            UInt16(kVK_ANSI_B): "B", UInt16(kVK_ANSI_Q): "Q",
            UInt16(kVK_ANSI_W): "W", UInt16(kVK_ANSI_E): "E",
            UInt16(kVK_ANSI_R): "R", UInt16(kVK_ANSI_Y): "Y",
            UInt16(kVK_ANSI_T): "T", UInt16(kVK_ANSI_O): "O",
            UInt16(kVK_ANSI_U): "U", UInt16(kVK_ANSI_I): "I",
            UInt16(kVK_ANSI_P): "P", UInt16(kVK_ANSI_L): "L",
            UInt16(kVK_ANSI_J): "J", UInt16(kVK_ANSI_K): "K",
            UInt16(kVK_ANSI_N): "N", UInt16(kVK_ANSI_M): "M",
        ]
        return map[code] ?? "?"
    }
}
