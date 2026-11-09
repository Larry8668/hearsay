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

/// A stretch of a session during which listening was paused (Pause / ⌃⌥P). `end` is nil while
/// the pause is still going. Stored in the JSON sidecar and rendered as a marker line in Markdown.
struct PauseInterval: Codable, Equatable, Sendable {
    var start: Date
    var end: Date?

    /// Length up to `end`, or up to `now` while still open.
    func length(now: Date) -> TimeInterval { max(0, (end ?? now).timeIntervalSince(start)) }
}
