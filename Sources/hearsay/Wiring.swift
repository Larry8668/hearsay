import Foundation

/// THE integration seam. The app never names a concrete source or engine type anywhere else, so
/// swapping the stubs for the real implementations is a change to this file only:
///
///     static func makeEngine() -> TranscriptionEngine { ParakeetEngine() }
///     static func makeSource(_ speaker: Speaker) -> AudioSource {
///         speaker == .me ? MicCapture() : SystemAudioTap()
///     }
///
/// Called on the main thread. `makeEngine()` is called once per speaker at launch (the engines are
/// prepared once and reused for every session); `makeSource` is called each time a speaker starts
/// listening, and the source is dropped after `stop()`.
///
/// INTEGRATION STUB: currently returns the fakes from Stubs.swift.
enum Wiring {
    static func makeEngine() -> TranscriptionEngine {
        FakeEngine()
    }

    static func makeSource(_ speaker: Speaker) -> AudioSource {
        FakeSource(speaker: speaker)
    }
}
