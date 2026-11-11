import Foundation

/// What a person adds to a transcript on top of its lines: a title, tags, and display names for
/// its voices. Lives in the JSON sidecar beside the lines (every field optional there, so
/// sidecars from before it existed load unchanged) and is rendered into the Markdown header
/// and every export. The lines keep their raw voices: a rename never rewrites a line, and the
/// colours never change.
struct TranscriptMeta: Codable, Equatable, Sendable {
    var title: String?
    var tags: [String] = []
    /// Display name per voice, keyed by `Voice.key` ("me", "them:us.zoom.xos").
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
    mutating func setName(_ name: String?, for voice: Voice) {
        let n = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        names[voice.key] = n.isEmpty ? nil : n
    }
}

extension Voice {
    /// A stable key for per-transcript settings: "me", "them", "them:us.zoom.xos". Shaped so a
    /// later diarization feature can tell people apart within one voice with a "#n" suffix
    /// ("me#1", "them:us.zoom.xos#2") without changing the format: before "#" is the voice, after
    /// it the person. Bundle identifiers never contain "#" or ":".
    var key: String {
        guard speaker == .them, let app = app else { return speaker.rawValue }
        return "them:\(app)"
    }

    /// The voice a key names; a "#n" person suffix is ignored so the voice still resolves.
    init?(key: String) {
        let body = key.split(separator: "#", maxSplits: 1).first.map(String.init) ?? key
        let parts = body.split(separator: ":", maxSplits: 1).map(String.init)
        guard let first = parts.first, let speaker = Speaker(rawValue: first) else { return nil }
        self.init(speaker: speaker, app: parts.count > 1 ? parts[1] : nil)
    }
}

/// Resolves what a voice is called. Precedence: the transcript's own name for that voice, then
/// Settings ▸ Your name for "me", then the built-in label ("me", "them · Zoom" / "them (Zoom)").
/// A value, so views and the formatter get a snapshot and re-render only when it changes.
struct VoiceNames: Equatable, Sendable {
    /// `TranscriptMeta.names`.
    var names: [String: String] = [:]
    /// Settings ▸ Your name (`storedYourName`); nil or blank means none.
    var yourName: String?

    init(names: [String: String] = [:], yourName: String? = nil) {
        self.names = names
        self.yourName = yourName
    }

    init(_ meta: TranscriptMeta, yourName: String?) { self.init(names: meta.names, yourName: yourName) }

    /// The name chosen for the voice, or nil when the built-in label applies.
    func custom(_ v: Voice) -> String? {
        if let n = names[v.key]?.trimmingCharacters(in: .whitespaces), !n.isEmpty { return n }
        if v.speaker == .me, let y = yourName?.trimmingCharacters(in: .whitespaces), !y.isEmpty { return y }
        return nil
    }

    /// "Priya", "Aditya", or the chip's built-in label: "me", "them · Zoom", "them".
    func chipLabel(_ v: Voice, appName: (String) -> String = { AppNames.name(for: $0) }) -> String {
        custom(v) ?? VoiceNames.defaultChipLabel(v, appName: appName)
    }

    static func defaultChipLabel(_ v: Voice, appName: (String) -> String = { AppNames.name(for: $0) }) -> String {
        guard v.speaker == .them, let app = v.app else { return v.speaker.rawValue }
        return "them · \(appName(app))"
    }

    // MARK: Settings ▸ Your name

    static let yourNameKey = "yourName"

    /// The global default for "me", in UserDefaults; blank is stored as nothing.
    static var storedYourName: String? {
        get { TranscriptMeta.cleanTitle(UserDefaults.standard.string(forKey: yourNameKey)) }
        set {
            if let n = TranscriptMeta.cleanTitle(newValue) { UserDefaults.standard.set(n, forKey: yourNameKey) }
            else { UserDefaults.standard.removeObject(forKey: yourNameKey) }
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
