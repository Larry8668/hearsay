import Foundation

/// Who produced a piece of audio / a transcript line.
/// `me` is the microphone; `them` is whatever the Mac plays (the other side of a call).
enum Speaker: String, Codable, Sendable, CaseIterable {
    case me, them
}

/// A chunk of audio ready for an engine: **16 kHz, mono, Float32 in -1...1**.
/// Every source converts to this format itself so engines never resample.
struct AudioChunk: Sendable {
    static let sampleRate: Double = 16_000

    var samples: [Float]
    /// Wall-clock time of the FIRST sample in `samples`.
    var startTime: Date
    var speaker: Speaker
    /// For `.them`: bundle identifier(s) of the app(s) that were producing sound while this chunk
    /// was captured (e.g. "us.zoom.xos"). Empty when unknown or for `.me`.
    var sourceApps: [String] = []

    var duration: TimeInterval { Double(samples.count) / AudioChunk.sampleRate }
    var endTime: Date { startTime.addingTimeInterval(duration) }
}

/// A live audio producer. `start()` returns a stream that ends when `stop()` is called or the
/// device goes away. Chunks are delivered in order; a typical chunk is 50–200 ms. Chunks are
/// contiguous while audio flows, but `startTime` may JUMP forward: the system tap delivers
/// nothing while no app plays sound, and device switches lose a moment. Sources do not pad
/// those gaps with silence; engines must therefore derive timestamps from each chunk's
/// `startTime`, never from a running sample count alone.
protocol AudioSource: AnyObject {
    var speaker: Speaker { get }
    /// Human-readable device / tap description for the UI ("MacBook Air Microphone", "System audio").
    var displayName: String { get }
    func start() throws -> AsyncStream<AudioChunk>
    func stop()
}

enum AudioSourceError: Error, LocalizedError {
    case permissionDenied(Speaker)
    case deviceUnavailable(String)
    case coreAudio(OSStatus, String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let s): return s == .me ? "Microphone access was denied." : "System audio recording was denied."
        case .deviceUnavailable(let d): return "Audio device unavailable: \(d)"
        case .coreAudio(let code, let what): return "Core Audio error \(code) during \(what)"
        }
    }
}
