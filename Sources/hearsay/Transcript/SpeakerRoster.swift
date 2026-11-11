import Foundation

/// Speaker ids: `"<stream>/<slot>"`, where the stream is the lane ("me", "them") or one app's
/// stream of the them lane ("them/us.zoom.xos") and the slot is the diarizer's 1-based slot.
/// Unique within a transcript, stable within a session, meaningless across sessions (a new
/// session hands slots out in order of first speech again).
enum SpeakerID {
    static func make(stream: String, slot: Int) -> String { "\(stream)/\(slot + 1)" }

    /// "them/us.zoom.xos/2" → "them/us.zoom.xos".
    static func stream(of id: String) -> String {
        guard let i = id.lastIndex(of: "/") else { return id }
        return String(id[..<i])
    }

    static func stream(_ speaker: Speaker, app: String?) -> String {
        guard speaker == .them, let app, !app.isEmpty else { return speaker.rawValue }
        return "them/\(app)"
    }
}

/// The speakers of one transcript: ids in order of first appearance, plus display names.
///
/// Naming is lazy so a lone voice keeps its lane's label: the microphone lane says "me" until a
/// second speaker turns up, at which point the first becomes "Speaker 1" and the newcomer
/// "Speaker 2". Numbers are per stream and never change once given; an enrolled voice is named
/// "me" and does not use up a number. `names` holds explicit names (enrolment, renames) and is
/// what the JSON sidecar persists together with the computed labels.
struct SpeakerRoster: Codable, Equatable, Sendable {
    private(set) var order: [String] = []
    var names: [String: String] = [:]

    init() {}

    /// Records a speaker; true when it is new (callers republish state only then).
    @discardableResult
    mutating func note(_ id: String) -> Bool {
        guard !order.contains(id) else { return false }
        order.append(id)
        return true
    }

    var isEmpty: Bool { order.isEmpty }

    /// Ids seen on one stream, in order.
    func ids(in stream: String) -> [String] { order.filter { SpeakerID.stream(of: $0) == stream } }

    /// "Speaker 2" / "me" / a custom name, or nil while the id is the stream's only voice (an
    /// enrolled "me" on the stream makes the other voice "Speaker 1" straight away).
    func displayName(_ id: String) -> String? {
        if let n = names[id] { return n }
        let stream = SpeakerID.stream(of: id)
        let streamIDs = ids(in: stream)
        let numbered = streamIDs.filter { names[$0] != "me" }
        let hasMe = numbered.count < streamIDs.count
        guard numbered.count > 1 || hasMe, let n = numbered.firstIndex(of: id) else { return nil }
        return "Speaker \(n + 1)"
    }

    /// Chip / line label: "me", "Speaker 2", "them · Zoom", "them · Zoom · Speaker 2"; `base` is
    /// the lane's label without a speaker and `separator` how the speaker is appended to it.
    func label(_ id: String?, lane: Speaker, base: String, separator: String = " · ") -> String {
        guard let id, let name = displayName(id) else { return base }
        if lane == .me { return name == "me" ? "me" : name }
        return base + separator + name
    }

    /// id → display name for every speaker, for the sidecar and the header.
    var map: [String: String] {
        var m: [String: String] = [:]
        for id in order { m[id] = displayName(id) ?? (SpeakerID.stream(of: id) == "me" ? "me" : "Speaker 1") }
        return m
    }

    /// Display names in order of appearance, for the Markdown header.
    var displayNames: [String] { order.compactMap { map[$0] } }

    mutating func rename(_ id: String, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { names[id] = nil } else { names[id] = n }
        note(id)
    }

    // Decoding tolerates sidecars written without the roster.
    enum CodingKeys: String, CodingKey { case order, names }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        order = try c.decodeIfPresent([String].self, forKey: .order) ?? []
        names = try c.decodeIfPresent([String: String].self, forKey: .names) ?? [:]
    }
}
