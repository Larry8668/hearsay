import Foundation

/// Speaker ids: `"<stream>#<slot>"`, where the stream is a voice's key (`Voice.key`: "me",
/// "them", or one app's stream of the them lane, "them:us.zoom.xos") and the slot the
/// diarizer's 1-based slot: "me#1", "them:us.zoom.xos#2". A diarized speaker's id is its voice's
/// key, so the names a person gives (`TranscriptMeta.names`) are keyed the same way for a whole
/// app and for one person in it. Unique within a transcript, stable within a session,
/// meaningless across sessions (a new session hands slots out in order of first speech again).
enum SpeakerID {
    static func make(stream: String, slot: Int) -> String { "\(stream)#\(slot + 1)" }

    /// "them:us.zoom.xos#2" → "them:us.zoom.xos". Bundle identifiers never contain "#".
    static func stream(of id: String) -> String {
        guard let i = id.lastIndex(of: "#") else { return id }
        return String(id[..<i])
    }

    /// The 1-based slot: "them:us.zoom.xos#2" → 2.
    static func slot(of id: String) -> Int? {
        guard let i = id.lastIndex(of: "#") else { return nil }
        return Int(id[id.index(after: i)...])
    }

    /// The stream key of a lane, or of one app of the them lane: "me", "them", "them:us.zoom.xos".
    static func stream(_ speaker: Speaker, app: String?) -> String {
        guard speaker == .them, let app, !app.isEmpty else { return speaker.rawValue }
        return "them:\(app)"
    }
}

/// The diarized speakers of one transcript: ids in order of first appearance, and which of them
/// is the enrolled voice. It only generates the default labels; names a person gives a speaker
/// are `TranscriptMeta.names[id]` and win over these (see `VoiceNames`).
///
/// Naming is lazy so a lone voice keeps its lane's label: the microphone lane says "me" until a
/// second speaker turns up, at which point the first becomes "Speaker 1" and the newcomer
/// "Speaker 2". Numbers are per stream and never change once given; an enrolled voice is "me"
/// and does not use up a number.
struct SpeakerRoster: Codable, Equatable, Sendable {
    private(set) var order: [String] = []
    /// Ids recognised as the enrolled voice (Settings ▸ Tell speakers apart ▸ Learn my voice…).
    private(set) var enrolled: Set<String> = []

    init() {}

    /// Rebuilds a saved transcript's roster from its sidecar: `labels` is `Sidecar.speakers`
    /// (id → generated label, "me" for the enrolled voice), `lines` give the order of first
    /// appearance (ids that never made a line go after, by slot).
    init(labels: [String: String], lines: [TranscriptLine]) {
        var first: [String: Int] = [:]
        for (i, l) in lines.enumerated() { if let id = l.speakerID, first[id] == nil { first[id] = i } }
        for id in labels.keys where first[id] == nil { first[id] = Int.max }
        order = first.keys.sorted { a, b in
            let (fa, fb) = (first[a] ?? .max, first[b] ?? .max)
            if fa != fb { return fa < fb }
            let (sa, sb) = (SpeakerID.slot(of: a) ?? 0, SpeakerID.slot(of: b) ?? 0)
            return sa != sb ? sa < sb : a < b
        }
        enrolled = Set(labels.filter { $0.value == "me" }.keys)
    }

    /// Records a speaker; true when it is new (callers republish state only then).
    @discardableResult
    mutating func note(_ id: String) -> Bool {
        guard !order.contains(id) else { return false }
        order.append(id)
        return true
    }

    /// Marks a speaker as the enrolled voice; true when that changed anything.
    @discardableResult
    mutating func markEnrolled(_ id: String) -> Bool {
        let new = note(id)
        return enrolled.insert(id).inserted || new
    }

    var isEmpty: Bool { order.isEmpty }

    /// Ids seen on one stream, in order.
    func ids(in stream: String) -> [String] { order.filter { SpeakerID.stream(of: $0) == stream } }

    /// "Speaker 2" / "me" (the enrolled voice), or nil while the id is the stream's only voice
    /// (an enrolled "me" on the stream makes the other voice "Speaker 1" straight away).
    func displayName(_ id: String) -> String? {
        if enrolled.contains(id) { return "me" }
        let streamIDs = ids(in: SpeakerID.stream(of: id))
        let numbered = streamIDs.filter { !enrolled.contains($0) }
        let hasMe = numbered.count < streamIDs.count
        guard numbered.count > 1 || hasMe, let n = numbered.firstIndex(of: id) else { return nil }
        return "Speaker \(n + 1)"
    }

    /// Chip / line label: "me", "Speaker 2", "them · Zoom", "them · Zoom · Speaker 2"; `base` is
    /// the lane's label without a speaker and `separator` how the speaker is appended to it.
    func label(_ id: String?, lane: Speaker, base: String, separator: String = " · ") -> String {
        guard let id, let name = displayName(id) else { return base }
        if lane == .me { return name }
        return base + separator + name
    }

    /// id → generated label for every speaker, for the sidecar (`Sidecar.speakers`).
    var map: [String: String] {
        var m: [String: String] = [:]
        for id in order { m[id] = defaultName(id) }
        return m
    }

    /// The generated label even for a lone voice: "me" on the microphone lane, "Speaker 1" elsewhere.
    func defaultName(_ id: String) -> String {
        displayName(id) ?? (SpeakerID.stream(of: id) == Speaker.me.rawValue ? "me" : "Speaker 1")
    }

    // Decoding tolerates rosters written without a field.
    enum CodingKeys: String, CodingKey { case order, enrolled }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        order = try c.decodeIfPresent([String].self, forKey: .order) ?? []
        enrolled = try c.decodeIfPresent(Set<String>.self, forKey: .enrolled) ?? []
    }
}

extension TranscriptStore.Sidecar {
    /// The diarized speakers as saved (empty when speakers were not told apart).
    var roster: SpeakerRoster { SpeakerRoster(labels: speakers ?? [:], lines: lines) }
}
