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
