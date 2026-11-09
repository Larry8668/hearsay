import Foundation

/// THE integration seam. The app never names a concrete source or engine type anywhere else.
///
/// Called on the main thread. `makeEngine()` is called once per speaker at launch (the engines are
/// prepared once and reused for every session; both share one downloaded model set but each loads
/// its own copy, ~55 MB each); `makeSource` is called each time a speaker starts listening, and the
/// source is dropped after `stop()`.
enum Wiring {
    /// Per-app system audio (one tap and one model stream per app that plays) is the default;
    /// `defaults write dev.hearsay.app perAppAudio -bool false` goes back to one mixed tap.
    static var perAppAudio: Bool { UserDefaults.standard.object(forKey: "perAppAudio") as? Bool ?? true }

    static func makeEngine() -> TranscriptionEngine {
        ParakeetEngine()          // variant from UserDefaults "engineVariant", default parakeet-unified-640ms
    }

    static func makeEngine(for speaker: Speaker) -> TranscriptionEngine {
        speaker == .them && perAppAudio ? PerAppEngine(make: makeEngine) : makeEngine()
    }

    static func makeSource(_ speaker: Speaker) -> AudioSource {
        if speaker == .me { return MicCapture() }
        return perAppAudio ? PerAppAudioTap() : SystemAudioTap()
    }
}
