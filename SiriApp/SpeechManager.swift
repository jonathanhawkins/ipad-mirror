import AVFoundation

/// Provides audio narration for Broken Screen Mode.
/// Gates speech on `UserDefaults("brokenScreenModeEnabled")` so that
/// `speak(_:)` is a no-op when the mode is off.
final class SpeechManager: @unchecked Sendable {
    static let shared = SpeechManager()

    private let synth = AVSpeechSynthesizer()

    private var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "brokenScreenModeEnabled")
    }

    /// Speaks a message only when Broken Screen Mode is enabled.
    /// Interrupts any in-progress utterance first.
    func speak(_ message: String) {
        guard isEnabled else { return }
        synth.stopSpeaking(at: .immediate)
        synth.speak(AVSpeechUtterance(string: message))
    }

    /// Always speaks, regardless of mode — used for toggle confirmation.
    func announce(_ message: String) {
        synth.stopSpeaking(at: .immediate)
        synth.speak(AVSpeechUtterance(string: message))
    }
}
