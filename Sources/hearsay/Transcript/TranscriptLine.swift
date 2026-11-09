import Foundation

/// One committed line of transcript.
struct TranscriptLine: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var speaker: Speaker
    /// Bundle identifier of the app that produced the sound ("us.zoom.xos"); nil for `.me` or unknown.
    var sourceApp: String?
    var start: Date
    var end: Date
    var text: String
    /// Engine identifier that produced the line ("parakeet-eou-120m").
    var engine: String
}

/// Who is talking, as the UI tells voices apart: a speaker plus, for "them", the app the sound
/// came from. With per-app system audio two apps playing at once are two voices ("them · Zen",
/// "them · Firefox") with their own partials and caption blocks.
struct Voice: Hashable, Codable, Sendable {
    var speaker: Speaker
    var app: String?
    static let me = Voice(speaker: .me)
    init(speaker: Speaker, app: String? = nil) {
        self.speaker = speaker
        self.app = speaker == .me ? nil : app
    }
    init(_ line: TranscriptLine) { self.init(speaker: line.speaker, app: line.sourceApp) }
    /// me first, then them by app name, so lists never reorder.
    static func displayOrder(_ a: Voice, _ b: Voice) -> Bool {
        if a.speaker != b.speaker { return a.speaker == .me }
        return (a.app ?? "") < (b.app ?? "")
    }
}

/// A stretch of a session during which listening was paused (Pause / ⌃⌥P). `end` is nil while
/// the pause is still going. Stored in the JSON sidecar and rendered as a marker line in Markdown.
struct PauseInterval: Codable, Equatable, Sendable {
    var start: Date
    var end: Date?

    /// Length up to `end`, or up to `now` while still open.
    func length(now: Date) -> TimeInterval { max(0, (end ?? now).timeIntervalSince(start)) }
}
