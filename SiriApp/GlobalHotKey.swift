import Cocoa
import Carbon.HIToolbox

final class GlobalHotKey {
    static let shared = GlobalHotKey()

    private var monitor: Any?
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

        let targetKeyCode = self.keyCode
        let targetModifiers = self.modifierFlags
        let relevantFlags: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let pressed = event.modifierFlags.intersection(relevantFlags)
            if event.keyCode == targetKeyCode && pressed == targetModifiers {
                NSLog("[iPad Mirror] Hotkey triggered")
                self?.callback?()
            }
        }

        isEnabled = true
        NSLog("[iPad Mirror] Global hotkey registered: \(displayString)")
    }

    func unregister() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    func setHotKey(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifierFlags = modifiers
        if let cb = callback {
            register(callback: cb)
        }
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
