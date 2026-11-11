import Foundation

/// What an engine emits while listening.
enum EngineEvent: Sendable {
    /// Best guess for the utterance in progress. Replaces the previous partial for this voice
    /// (speaker + app + diarized speaker; `app` is nil for the microphone or when no app is
    /// known, `speakerID` nil while speakers are not told apart on this lane).
    case partial(text: String, speaker: Speaker, app: String?, speakerID: String?)
    /// A committed line. `start`/`end` are wall-clock times derived from the chunk timestamps.
    case final(TranscriptLine)
    /// Non-fatal problem worth surfacing (model fell behind, device glitch).
    case warning(String)
}

/// Where the engine's model files are and how far a download has got.
enum ModelState: Equatable, Sendable {
    case notDownloaded
    case downloading(fraction: Double)   // 0...1, or -1 when unknown
    case ready
    case failed(String)
}

/// A speech-to-text engine that consumes `AudioChunk`s and produces `EngineEvent`s.
///
/// One engine instance serves ONE speaker (one stream of audio). The session layer creates two
/// instances (me / them) and interleaves their final lines by timestamp. Implementations are
/// actors or otherwise thread-safe; `feed` is called from an audio-rate task, `events` is read
/// from the main actor.
protocol TranscriptionEngine: AnyObject {
    /// Short identifier used in Settings and the transcript header ("parakeet-eou-120m").
    var identifier: String { get }
    var displayName: String { get }
    /// BCP-47 codes this engine can transcribe ("en", "de", ...).
    var languages: [String] { get }

    /// Load / download models. Progress is reported through `modelState`.
    func prepare(progress: @escaping @Sendable (ModelState) -> Void) async throws

    /// Begin a listening session for `speaker`. Must be called after `prepare` succeeded.
    func start(speaker: Speaker) async throws -> AsyncStream<EngineEvent>
    /// Like `start(speaker:)` for one named stream of the lane ("them/us.zoom.xos" for a per-app
    /// stream): the key under which the stream's diarizer is kept and its speaker ids are made.
    func start(speaker: Speaker, stream: String?) async throws -> AsyncStream<EngineEvent>
    /// Push audio. Non-blocking; the engine buffers internally.
    func feed(_ chunk: AudioChunk) async
    /// Flush: emit any trailing text as a final line, then end the event stream.
    func stop() async
}

extension TranscriptionEngine {
    func start(speaker: Speaker, stream: String?) async throws -> AsyncStream<EngineEvent> { try await start(speaker: speaker) }
}

enum EngineError: Error, LocalizedError {
    case modelUnavailable(String)
    case notPrepared
    case inference(String)

    var errorDescription: String? {
        switch self {
        case .modelUnavailable(let s): return "Speech model unavailable: \(s)"
        case .notPrepared: return "Engine used before prepare() finished."
        case .inference(let s): return "Transcription failed: \(s)"
        }
    }
}
