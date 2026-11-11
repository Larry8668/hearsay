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
    /// Who spoke, when speakers are told apart (`SpeakerID`): the diarizer slot that dominated
    /// the line's span. Nil when diarization is off or no slot was active.
    var speakerID: String?
}

/// Who is talking, as the UI tells voices apart: a speaker plus, for "them", the app the sound
/// came from, plus the diarized speaker when there is one. With per-app system audio two apps
/// playing at once are two voices ("them · Zen", "them · Firefox") with their own partials and
/// caption blocks; with diarization on, so are two people on one lane ("me · Speaker 2").
struct Voice: Hashable, Codable, Sendable {
    var speaker: Speaker
    var app: String?
    var speakerID: String?
    static let me = Voice(speaker: .me)
    init(speaker: Speaker, app: String? = nil, speakerID: String? = nil) {
        self.speaker = speaker
        self.app = speaker == .me ? nil : app
        self.speakerID = speakerID
    }
    init(_ line: TranscriptLine) { self.init(speaker: line.speaker, app: line.sourceApp, speakerID: line.speakerID) }
    /// The audio stream this voice came from ("me", "them:us.zoom.xos"); its speakers share it.
    /// Taken from the speaker id when there is one: the id names the diarized stream even when
    /// the line's app vote came out differently.
    var stream: String { speakerID.map(SpeakerID.stream(of:)) ?? SpeakerID.stream(speaker, app: app) }
    /// me first, then them by app name, then speakers in id order, so lists never reorder.
    static func displayOrder(_ a: Voice, _ b: Voice) -> Bool {
        if a.speaker != b.speaker { return a.speaker == .me }
        if a.app != b.app { return (a.app ?? "") < (b.app ?? "") }
        return (a.speakerID ?? "") < (b.speakerID ?? "")
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
