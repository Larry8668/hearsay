import AppKit

/// Deep links into System Settings ▸ Privacy & Security. Placeholder until the audio worktree's
/// `Permissions` helper lands (it may then own these).
enum SettingsLinks {
    static let microphone = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    /// "Screen & System Audio Recording" ▸ System Audio Recording Only (Core Audio taps, macOS 14.2+).
    static let systemAudio = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!

    static func open(for speaker: Speaker) {
        NSWorkspace.shared.open(speaker == .me ? microphone : systemAudio)
    }
}
