import AppKit

/// Pure text rendering of a transcript: Markdown file, SRT subtitles, plain text, file names.
/// No I/O and no global state, so it is deterministic under test: the time zone and the
/// bundle-ID → app-name lookup are injected.
struct TranscriptFormatter {
    var timeZone: TimeZone = .current
    /// "us.zoom.xos" → "Zoom". Defaults to the LaunchServices lookup in `AppNames`.
    var appName: (String) -> String = { AppNames.name(for: $0) }
    /// Display names for the voices (per transcript, then Settings ▸ Your name) and the diarized
    /// speakers' generated labels ("Speaker 2"); injected like the time zone so the output is
    /// deterministic under test.
    var names = VoiceNames()

    // MARK: File naming

    /// "2026-11-09 14.03 hearsay" — local time, no colons (Finder shows ":" as "/" and some sync
    /// tools reject it), sorts chronologically by name.
    func baseName(for start: Date) -> String {
        format(start, "yyyy-MM-dd HH.mm") + " hearsay"
    }

    // MARK: Markdown

    /// ```
    /// # Call transcript — Sun 9 Nov 2026, 14:03–14:41 (38 min)
    /// _Speakers: me, Speaker 2 · Apps heard: Zoom, Safari · Engine: parakeet-eou-120m · Made with hearsay, on this Mac._
    ///
    /// **14:03:12 Speaker 2** So the deadline moves to Friday?
    ///
    /// _— paused 4 min —_
    /// ```
    /// `end == nil` means the call is still going ("14:03 – in progress"). Each pause becomes a
    /// marker line placed where it happened, so a reader knows the gap in the text is deliberate.
    ///
    /// With a title the H1 is the title and the date range moves to the line under it; tags go
    /// first in the italic line ("Tags: planning, q4 · Apps heard: …"):
    /// ```
    /// # Design review
    /// Sun 9 Nov 2026, 14:03–14:41 (38 min)
    /// _Tags: design, q4 · Apps heard: Zoom · Engine: … · Made with hearsay, on this Mac._
    /// ```
    func markdown(lines: [TranscriptLine], start: Date, end: Date?, engine: String, pauses: [PauseInterval] = [],
                  meta info: TranscriptMeta = TranscriptMeta()) -> String {
        let range = headerRange(start: start, end: end, pauses: pauses)
        var out = info.title.map { "# \(escape($0))\n\(range)\n" } ?? "# Call transcript — \(range)\n"
        var meta: [String] = []
        if !info.tags.isEmpty { meta.append("Tags: " + info.tags.joined(separator: ", ")) }
        // Only worth a word once there is something to tell apart (a lone "me" is the default).
        if names.hasSpeakersToList {
            meta.append("Speakers: " + names.roster.order.map { names.speakerName($0) }.joined(separator: ", "))
        }
        let apps = appsHeard(lines)
        if !apps.isEmpty { meta.append("Apps heard: " + apps.joined(separator: ", ")) }
        meta.append("Engine: \(engine)")
        meta.append("Made with hearsay, on this Mac.")
        out += "_" + meta.joined(separator: " · ") + "_\n"
        var pending = pauses.sorted { $0.start < $1.start }[...]
        for line in lines {
            // A pause goes before the first line that started after it began. Engines flush their
            // trailing text when a pause begins, so those finals (start < pause) stay above it.
            while let p = pending.first, p.start <= line.start { out += pauseMarker(p); pending.removeFirst() }
            // One paragraph per line: renders cleanly everywhere and diffs line by line.
            out += "\n**\(format(line.start, "HH:mm:ss")) \(label(line))** \(escape(line.text))\n"
        }
        for p in pending { out += pauseMarker(p) }
        return out
    }

    /// "_— paused 4 min —_", or "_— paused —_" while the pause is still going.
    func pauseMarker(_ p: PauseInterval) -> String {
        guard let end = p.end else { return "\n_— paused —_\n" }
        return "\n_— paused \(TranscriptFormatter.shortDuration(end.timeIntervalSince(p.start))) —_\n"
    }

    /// "Mon 9 Nov 2026, 14:03–14:41 (38 min)", or "(38 min, 4 min paused)" when there were pauses.
    /// The first figure is wall-clock time, matching the range shown next to it.
    func headerRange(start: Date, end: Date?, pauses: [PauseInterval] = []) -> String {
        guard let end = end else { return dateRange(start: start, end: nil) }
        return "\(dateRange(start: start, end: end)) (\(lengthText(start: start, end: end, pauses: pauses)))"
    }

    /// "Mon 9 Nov 2026, 14:03–14:41", or "Mon 9 Nov 2026, 14:03 – in progress" (the main window's
    /// title for a transcript).
    func dateRange(start: Date, end: Date?) -> String {
        let day = format(start, "EEE d MMM yyyy")
        guard let end = end else { return "\(day), \(format(start, "HH:mm")) – in progress" }
        return "\(day), \(format(start, "HH:mm"))–\(format(end, "HH:mm"))"
    }

    /// "38 min", or "38 min, 4 min paused".
    func lengthText(start: Date, end: Date, pauses: [PauseInterval] = []) -> String {
        var length = TranscriptFormatter.duration(end.timeIntervalSince(start))
        let paused = pauses.reduce(0) { $0 + $1.length(now: end) }
        if paused >= 0.5 { length += ", \(TranscriptFormatter.shortDuration(paused)) paused" }
        return length
    }

    /// Like `duration`, but seconds under a minute ("40 s"): a pause is often brief, and
    /// "paused under 1 min" reads oddly.
    static func shortDuration(_ seconds: TimeInterval) -> String {
        seconds < 59.5 ? "\(Int(seconds.rounded())) s" : duration(seconds)
    }

    /// "under 1 min", "38 min", "1 h 05 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "under 1 min" }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h " + String(format: "%02d min", minutes % 60)
    }

    /// The voice's display name when one is set ("Priya"), else "me", "them (Zoom)", or "them"
    /// when the app is unknown; with speakers told apart "Speaker 2" or "them (Zoom) · Speaker 2".
    func label(_ line: TranscriptLine) -> String {
        if let n = names.custom(Voice(line)) { return n }
        let base: String
        switch line.speaker {
        case .me: base = "me"
        case .them: base = line.sourceApp.map { "them (\(appName($0)))" } ?? "them"
        }
        return names.roster.label(line.speakerID, lane: line.speaker, base: base)
    }

    /// Distinct app names in order of first appearance.
    func appsHeard(_ lines: [TranscriptLine]) -> [String] {
        var seen: [String] = []
        for case let app? in lines.map(\.sourceApp) {
            let n = appName(app)
            if !seen.contains(n) { seen.append(n) }
        }
        return seen
    }

    /// Speech can contain "*" or "_" (spelled-out symbols); escape the few characters that would
    /// otherwise turn a line bold/italic or into HTML.
    private func escape(_ s: String) -> String {
        var r = ""
        for ch in s {
            if "*_`\\<".contains(ch) { r.append("\\") }
            r.append(ch)
        }
        return r
    }

    // MARK: SRT / plain text

    /// SubRip with times relative to the session start, e.g. to line up with a call recording.
    func srt(lines: [TranscriptLine], start: Date) -> String {
        var out = ""
        for (i, line) in lines.enumerated() {
            let a = max(0, line.start.timeIntervalSince(start))
            let b = max(a + 0.5, line.end.timeIntervalSince(start))   // never zero-length cues
            out += "\(i + 1)\n\(TranscriptFormatter.srtTime(a)) --> \(TranscriptFormatter.srtTime(b))\n"
            out += "\(label(line)): \(line.text)\n\n"
        }
        return out
    }

    static func srtTime(_ t: TimeInterval) -> String {
        let ms = Int((t * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }

    /// "[14:03:12] me: So the deadline moves to Friday?" — for the clipboard.
    func plainText(lines: [TranscriptLine]) -> String {
        lines.map { "[\(format($0.start, "HH:mm:ss"))] \(label($0)): \($0.text)" }.joined(separator: "\n")
    }

    /// "me: So the deadline moves to Friday?" — one line each, no times (the .txt export: a
    /// transcript to paste into notes or a prompt).
    func plainLines(lines: [TranscriptLine]) -> String {
        lines.map { "\(label($0)): \($0.text)" }.joined(separator: "\n")
    }

    func clock(_ date: Date) -> String { format(date, "HH:mm:ss") }

    // MARK: -

    private func format(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")   // fixed: file names and headers must not vary by locale
        f.timeZone = timeZone
        f.dateFormat = pattern
        return f.string(from: date)
    }
}

/// Bundle identifier → user-facing app name, via LaunchServices with a readable fallback.
enum AppNames {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String] = [:]

    /// Well-known call apps, used when the app isn't installed here (e.g. a transcript from a
    /// browser call) and to keep names short ("Teams", not "Microsoft Teams (work or school)").
    static let known: [String: String] = [
        "us.zoom.xos": "Zoom", "com.microsoft.teams2": "Teams", "com.microsoft.teams": "Teams",
        "com.google.Chrome": "Chrome", "com.apple.Safari": "Safari", "org.mozilla.firefox": "Firefox",
        "com.apple.FaceTime": "FaceTime", "com.tinyspeck.slackmacgap": "Slack", "com.hnc.Discord": "Discord",
        "com.cisco.webexmeetingsapp": "Webex", "net.whatsapp.WhatsApp": "WhatsApp", "com.brave.Browser": "Brave",
        "company.thebrowser.Browser": "Arc", "com.microsoft.edgemac": "Edge",
    ]

    static func name(for bundleID: String) -> String {
        lock.lock(); defer { lock.unlock() }
        if let c = cache[bundleID] { return c }
        let n = lookup(bundleID)
        cache[bundleID] = n
        return n
    }

    private static func lookup(_ id: String) -> String {
        if let k = known[id] { return k }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            let info = Bundle(url: url)?.infoDictionary
            if let n = (info?["CFBundleDisplayName"] ?? info?["CFBundleName"]) as? String, !n.isEmpty { return n }
            return url.deletingPathExtension().lastPathComponent
        }
        // "com.example.someapp" → "Someapp"
        let last = id.split(separator: ".").last.map(String.init) ?? id
        return last.prefix(1).uppercased() + last.dropFirst()
    }
}
