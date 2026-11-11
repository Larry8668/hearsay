import Foundation

/// What a person adds to a transcript on top of its lines: a title, tags, and display names for
/// its voices. Lives in the JSON sidecar beside the lines (every field optional there, so
/// sidecars from before it existed load unchanged) and is rendered into the Markdown header
/// and every export. The lines keep their raw voices: a rename never rewrites a line, and the
/// colours never change.
struct TranscriptMeta: Codable, Equatable, Sendable {
    var title: String?
    var tags: [String] = []
    /// Display name per voice, keyed by `Voice.key`: "me", "them:us.zoom.xos", or for one
    /// diarized speaker its id, "me#2", "them:us.zoom.xos#1" (see `SpeakerID`).
    var names: [String: String] = [:]

    var isEmpty: Bool { title == nil && tags.isEmpty && names.isEmpty }

    /// Trimmed; an empty title is no title, so clearing the field goes back to the date.
    static func cleanTitle(_ s: String?) -> String? {
        let t = s?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }

    /// Trimmed, without a leading "#", never empty, and de-duplicated case-insensitively (the
    /// first spelling wins) so "Q4" and "q4" don't become two chips.
    static func cleanTags(_ tags: [String]) -> [String] {
        var out: [String] = []
        for raw in tags {
            var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            while t.hasPrefix("#") { t.removeFirst() }
            t = t.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !out.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) else { continue }
            out.append(t)
        }
        return out
    }

    mutating func setTitle(_ s: String?) { title = TranscriptMeta.cleanTitle(s) }
    mutating func setTags(_ t: [String]) { tags = TranscriptMeta.cleanTags(t) }

    /// Sets a voice's display name; an empty or whitespace name removes it (back to the default).
    mutating func setName(_ name: String?, for voice: Voice) { setName(name, forKey: voice.key) }

    mutating func setName(_ name: String?, forKey key: String) {
        let n = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        names[key] = n.isEmpty ? nil : n
    }
}

extension Voice {
    /// A stable key for per-transcript settings: "me", "them", "them:us.zoom.xos", and for a
    /// diarized speaker its id, which is the stream's key plus "#slot" ("me#1",
    /// "them:us.zoom.xos#2"): before "#" is the voice, after it the person. Bundle identifiers
    /// never contain "#" or ":".
    var key: String { speakerID ?? SpeakerID.stream(speaker, app: app) }

    /// The voice a key names, with its speaker when the key has a "#slot".
    init?(key: String) {
        let body = SpeakerID.stream(of: key)
        let parts = body.split(separator: ":", maxSplits: 1).map(String.init)
        guard let first = parts.first, let speaker = Speaker(rawValue: first) else { return nil }
        self.init(speaker: speaker, app: parts.count > 1 ? parts[1] : nil, speakerID: key.contains("#") ? key : nil)
    }
}

/// Resolves what a voice is called; the one naming system for lanes, apps and diarized speakers.
/// Precedence: the transcript's own name for that voice (`names[Voice.key]`), then Settings ▸
/// Your name wherever the label would be "me" (the mic lane while it is one voice, or the
/// enrolled voice; never "Speaker 2"), then the generated label: the lane's ("me",
/// "them · Zoom" / "them (Zoom)") with the roster's speaker appended ("Speaker 2",
/// "them · Zoom · Speaker 2").
/// A value, so views and the formatter get a snapshot and re-render only when it changes.
struct VoiceNames: Equatable, Sendable {
    /// `TranscriptMeta.names`.
    var names: [String: String] = [:]
    /// Settings ▸ Your name (`storedYourName`); nil or blank means none.
    var yourName: String?
    /// The diarized speakers ("Speaker 2"); empty when speakers are not told apart.
    var roster = SpeakerRoster()

    init(names: [String: String] = [:], yourName: String? = nil, roster: SpeakerRoster = SpeakerRoster()) {
        self.names = names
        self.yourName = yourName
        self.roster = roster
    }

    init(_ meta: TranscriptMeta, yourName: String?, roster: SpeakerRoster = SpeakerRoster()) {
        self.init(names: meta.names, yourName: yourName, roster: roster)
    }

    /// The name chosen for the voice, or nil when the generated label applies.
    func custom(_ v: Voice) -> String? {
        if let n = names[v.key]?.trimmingCharacters(in: .whitespaces), !n.isEmpty { return n }
        if isMe(v), let y = yourName?.trimmingCharacters(in: .whitespaces), !y.isEmpty { return y }
        return nil
    }

    /// True when the voice's generated label is "me": the mic lane without a speaker, its only
    /// speaker so far, or the enrolled voice.
    func isMe(_ v: Voice) -> Bool {
        guard v.speaker == .me else { return false }
        if let id = v.speakerID, roster.isProvisional(id) { return false }
        guard let id = v.speakerID, let n = roster.displayName(id) else { return true }
        return n == "me"
    }

    /// "Priya", "Aditya", or the chip's generated label: "me", "them · Zoom", "them",
    /// "Speaker 2", "them · Zoom · Speaker 2".
    func chipLabel(_ v: Voice, appName: (String) -> String = { AppNames.name(for: $0) }) -> String {
        custom(v) ?? roster.label(v.speakerID, lane: v.speaker, base: VoiceNames.defaultChipLabel(v, appName: appName))
    }

    /// A speaker's own name without its lane ("Anna", "Speaker 2", "me"), for the Markdown
    /// header's "Speakers:" list.
    func speakerName(_ id: String) -> String {
        if let v = Voice(key: id), let n = custom(v) { return n }
        return roster.defaultName(id)
    }

    /// True when the roster is worth listing: more than one speaker, or one that was named or
    /// enrolled (a lone, unnamed "me" is the default and says nothing).
    var hasSpeakersToList: Bool {
        roster.order.count > 1 || roster.order.contains { names[$0] != nil || roster.enrolled.contains($0) }
    }

    static func defaultChipLabel(_ v: Voice, appName: (String) -> String = { AppNames.name(for: $0) }) -> String {
        guard v.speaker == .them, let app = v.app else { return v.speaker.rawValue }
        return "them · \(appName(app))"
    }

    // MARK: Settings ▸ Your name

    static let yourNameKey = "yourName"

    /// The global default for "me", in UserDefaults; blank is stored as nothing.
    static var storedYourName: String? {
        get { TranscriptMeta.cleanTitle(Prefs.store.string(forKey: yourNameKey)) }
        set {
            if let n = TranscriptMeta.cleanTitle(newValue) { Prefs.store.set(n, forKey: yourNameKey) }
            else { Prefs.store.removeObject(forKey: yourNameKey) }
        }
    }
}

extension TranscriptStore.Sidecar {
    /// The optional sidecar fields as one value (absent fields read as empty).
    var meta: TranscriptMeta {
        get { TranscriptMeta(title: title, tags: tags ?? [], names: names ?? [:]) }
        set {
            title = newValue.title
            tags = newValue.tags.isEmpty ? nil : newValue.tags
            names = newValue.names.isEmpty ? nil : newValue.names
        }
    }
}
