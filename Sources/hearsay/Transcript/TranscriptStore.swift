import AppKit

/// One call's transcript on disk: `~/Documents/hearsay/2026-11-09 14.03 hearsay.md` plus a
/// `.json` sidecar with the raw `TranscriptLine`s (for re-rendering or other tools).
///
/// Lines are kept sorted by `start`: the two engines run independently, so a "them" line can be
/// committed after a later "me" line. Every insert rewrites both files atomically (write to temp +
/// rename, so a crash never leaves half a file), debounced to at most once per second; `finish()`
/// always writes synchronously so a quit or SIGTERM can't lose the tail.
///
/// Main thread only. File I/O happens on a private serial queue so it never blocks the UI.
final class TranscriptStore {
    /// `~/Documents/hearsay` (`hearsay-dev` in dev mode). Dev aid: `HEARSAY_TRANSCRIPTS_DIR=/some/dir` points a test instance
    /// elsewhere, so unattended runs never touch the user's own transcripts.
    static var defaultDirectory: URL {
        DevMode.transcriptsDirectory(dev: DevMode.isDev, environment: ProcessInfo.processInfo.environment,
                                     documents: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0])
    }

    let directory: URL
    let startedAt: Date
    let engine: String
    private(set) var endedAt: Date?
    private(set) var lines: [TranscriptLine] = []
    /// Pauses in order; the last one is open (`end == nil`) while paused.
    private(set) var pauses: [PauseInterval] = []
    /// Diarized speakers seen so far, in order, and which one is the enrolled voice (see
    /// SpeakerRoster): where "Speaker 2" comes from. Names people give them live in `meta.names`.
    private(set) var speakers = SpeakerRoster()
    let formatter: TranscriptFormatter
    /// Title, tags and voice names (see `TranscriptMeta`). Kept here so every write, including
    /// the final one, carries them; a change after the file exists rewrites it like a new line.
    var meta = TranscriptMeta() {
        didSet { if meta != oldValue, !lines.isEmpty { scheduleWrite() } }
    }
    /// Settings ▸ Your name at the time of each write (read then, not at creation, so a name set
    /// mid-session reaches the file). Injected so tests are deterministic.
    let yourName: () -> String?
    /// `formatter` with this transcript's names applied: what every render and export uses.
    var namedFormatter: TranscriptFormatter {
        var f = formatter
        f.names = VoiceNames(meta, yourName: yourName(), roster: speakers)
        return f
    }
    /// Fixed at creation from `startedAt`; " 2", " 3"… appended if that minute is taken.
    let markdownURL: URL
    var jsonURL: URL { markdownURL.deletingPathExtension().appendingPathExtension("json") }
    /// Becomes true once something was written. A session with no speech leaves no files behind.
    private(set) var hasFile = false

    private let io = DispatchQueue(label: "hearsay.transcript.io", qos: .utility)
    private var lastWrite = Date.distantPast
    private var writePending = false
    let debounce: TimeInterval

    init(directory: URL = TranscriptStore.defaultDirectory, startedAt: Date = Date(), engine: String,
         formatter: TranscriptFormatter = TranscriptFormatter(), debounce: TimeInterval = 1,
         yourName: @escaping () -> String? = { VoiceNames.storedYourName }) {
        self.directory = directory
        self.startedAt = startedAt
        self.engine = engine
        self.formatter = formatter
        self.debounce = debounce
        self.yourName = yourName
        markdownURL = TranscriptStore.uniqueURL(in: directory, base: formatter.baseName(for: startedAt))
    }

    static func uniqueURL(in dir: URL, base: String) -> URL {
        var url = dir.appendingPathComponent(base + ".md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n).md"); n += 1
        }
        return url
    }

    // MARK: Lines

    /// Inserts by `start` (stable: equal starts keep arrival order) and schedules a rewrite.
    func insert(_ line: TranscriptLine) {
        lines.insert(line, at: TranscriptStore.insertionIndex(for: line.start, in: lines))
        scheduleWrite()
    }

    /// Binary search for the first index whose start is later than `start`. Usually the end of the
    /// array, so appends stay O(log n).
    static func insertionIndex(for start: Date, in lines: [TranscriptLine]) -> Int {
        var lo = 0, hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid].start <= start { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    // MARK: Speakers

    /// Records a diarized speaker id as soon as it is heard (partials included), so numbering
    /// follows the order people first spoke.
    func note(speaker id: String) {
        guard speakers.note(id), !lines.isEmpty else { return }
        scheduleWrite()
    }

    /// Marks a speaker as the enrolled voice: "me" instead of a number (see `SpeakerRoster`).
    func markEnrolled(speaker id: String) {
        guard speakers.markEnrolled(id), !lines.isEmpty else { return }
        scheduleWrite()
    }

    /// Gives a speaker a name ("Anna") that replaces "Speaker 2" in the files; an empty name
    /// goes back to the number. The same as renaming its chip: the name lives in `meta.names`
    /// under the speaker id (which is the voice's key), and the transcript is rewritten.
    func rename(speaker id: String, to name: String) {
        speakers.note(id)
        meta.setName(name, forKey: id)
    }

    // MARK: Pauses

    var isPaused: Bool { pauses.last.map { $0.end == nil } ?? false }

    func beginPause(at date: Date = Date()) {
        guard !isPaused else { return }
        pauses.append(PauseInterval(start: date))
        if !lines.isEmpty { scheduleWrite() }   // a pause before any speech leaves no file yet
    }

    func endPause(at date: Date = Date()) {
        guard isPaused else { return }
        pauses[pauses.count - 1].end = max(date, pauses[pauses.count - 1].start)
        if !lines.isEmpty { scheduleWrite() }
    }

    /// Stamps the end time and writes immediately (synchronously, so callers on the quit path can
    /// rely on the file being complete when this returns). A pause still open (stop or quit while
    /// paused) is closed at `end`.
    func finish(at end: Date = Date()) {
        endPause(at: end)
        endedAt = end
        writePending = false
        guard !lines.isEmpty else { Log.info(.session, "transcript: no lines, nothing saved"); return }
        let snapshot = render()
        io.sync { TranscriptStore.write(snapshot) }
        hasFile = true
        Log.info(.session, "transcript: finalised \(markdownURL.lastPathComponent) (\(lines.count) lines)")
    }

    private func scheduleWrite() {
        guard !writePending else { return }
        let wait = lastWrite.addingTimeInterval(debounce).timeIntervalSinceNow
        if wait <= 0 { writeNow(); return }
        writePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self = self, self.writePending else { return }
            self.writePending = false
            self.writeNow()
        }
    }

    private func writeNow() {
        lastWrite = Date()
        let snapshot = render()
        io.async { TranscriptStore.write(snapshot) }
        hasFile = true
    }

    /// Blocks until queued writes are on disk (tests, quit path).
    func waitForWrites() { io.sync {} }

    // MARK: Rendering + I/O

    private struct Snapshot { var dir: URL; var md: URL; var json: URL; var markdown: String; var sidecar: Data }

    /// JSON sidecar layout: `{ version, startedAt, endedAt?, engine, lines: [TranscriptLine], pauses?,
    /// title?, tags?, names?, speakers? }`. Every field after `lines` is optional, so sidecars
    /// written before it existed still decode (same version). `title`, `tags` and `names` are the
    /// person's (`TranscriptMeta`); `speakers` is the diarizer's roster (`SpeakerRoster`): speaker
    /// id → generated label ("Speaker 2", or "me" for the enrolled voice). A line's `speakerID` is
    /// also its voice's key, so `names[id]`, when present, overrides `speakers[id]`.
    struct Sidecar: Codable {
        var version = 1; var startedAt: Date; var endedAt: Date?; var engine: String; var lines: [TranscriptLine]
        var pauses: [PauseInterval]?
        var title: String?; var tags: [String]?; var names: [String: String]?
        var speakers: [String: String]?
    }

    /// ISO 8601 with milliseconds: whole seconds would lose the order of lines that start in the
    /// same second when the sidecar is read back.
    static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(isoFormatter().string(from: date))
        }
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            guard let date = isoFormatter().date(from: s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "bad date \(s)"))
            }
            return date
        }
        return d
    }()

    private static func isoFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    private func render() -> Snapshot {
        let md = namedFormatter.markdown(lines: lines, start: startedAt, end: endedAt, engine: engine, pauses: pauses, meta: meta)
        var side = Sidecar(startedAt: startedAt, endedAt: endedAt, engine: engine, lines: lines, pauses: pauses.isEmpty ? nil : pauses)
        side.meta = meta
        side.speakers = speakers.isEmpty ? nil : speakers.map
        let data = (try? TranscriptStore.jsonEncoder.encode(side)) ?? Data()
        return Snapshot(dir: directory, md: markdownURL, json: jsonURL, markdown: md, sidecar: data)
    }

    /// Rewrites a saved transcript's files with new title / tags / names: the sidecar keeps every
    /// other field as it was, and the Markdown is rendered again from the sidecar's lines (its
    /// header carries the title and tags; its lines the names). Synchronous; call off the main
    /// thread. The files' names never change: they are the session's start time.
    static func updateMeta(_ meta: TranscriptMeta, at jsonURL: URL, formatter: TranscriptFormatter = TranscriptFormatter(),
                           yourName: String? = VoiceNames.storedYourName) throws {
        var side = try jsonDecoder.decode(Sidecar.self, from: Data(contentsOf: jsonURL))
        side.meta = meta
        var f = formatter
        f.names = VoiceNames(meta, yourName: yourName, roster: side.roster)
        let md = f.markdown(lines: side.lines, start: side.startedAt, end: side.endedAt, engine: side.engine, pauses: side.pauses ?? [], meta: meta)
        let mdURL = jsonURL.deletingPathExtension().appendingPathExtension("md")
        try Data(md.utf8).write(to: mdURL, options: .atomic)
        try jsonEncoder.encode(side).write(to: jsonURL, options: .atomic)
        Log.info("transcript: updated title/tags/names of \(jsonURL.lastPathComponent)")
    }

    private static func write(_ s: Snapshot) {
        do {
            try FileManager.default.createDirectory(at: s.dir, withIntermediateDirectories: true)
            try Data(s.markdown.utf8).write(to: s.md, options: .atomic)
            try s.sidecar.write(to: s.json, options: .atomic)
        } catch {
            Log.error(.session, "transcript: write failed for \(s.md.path): \(error)")
        }
    }

    // MARK: Exports and Finder

    /// `hiding`: voices the window has turned off; they stay in the files, out of the clipboard.
    func plainText(hiding hidden: Set<Voice> = []) -> String { namedFormatter.plainText(lines: lines.visible(hiding: hidden)) }

    func copyAll(hiding hidden: Set<Voice> = []) {
        TranscriptStore.copy(plainText(hiding: hidden))
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Writes `<name>.srt` next to the Markdown file and returns it.
    @discardableResult
    func exportSRT(hiding hidden: Set<Voice> = []) -> URL? {
        TranscriptStore.writeSRT(lines: lines.visible(hiding: hidden), start: startedAt,
                                 nextTo: markdownURL, formatter: namedFormatter)
    }

    /// `<transcript>.srt` beside the given transcript file; nil when there is nothing to write
    /// or the write fails.
    @discardableResult
    static func writeSRT(lines: [TranscriptLine], start: Date, nextTo transcript: URL,
                         formatter: TranscriptFormatter = TranscriptFormatter()) -> URL? {
        guard !lines.isEmpty else { return nil }
        let url = transcript.deletingPathExtension().appendingPathExtension("srt")
        do {
            try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(formatter.srt(lines: lines, start: start).utf8).write(to: url, options: .atomic)
            Log.info(.session, "transcript: exported \(url.lastPathComponent)")
            return url
        } catch {
            Log.error(.session, "transcript: SRT export failed: \(error)")
            return nil
        }
    }

    func revealInFinder() {
        waitForWrites()
        if hasFile { NSWorkspace.shared.activateFileViewerSelecting([markdownURL]) } else { TranscriptStore.openFolder() }
    }

    func open() {
        waitForWrites()
        if hasFile { NSWorkspace.shared.open(markdownURL) } else { TranscriptStore.openLast() }
    }

    // MARK: Folder-level helpers (no session needed)

    /// Most recently modified transcript in the folder.
    static func lastTranscriptURL(in dir: URL = defaultDirectory) -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return items.filter { $0.pathExtension == "md" }.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
    }

    static func openLast() {
        if let url = lastTranscriptURL() { NSWorkspace.shared.open(url) } else { openFolder() }
    }

    static func openFolder() {
        try? FileManager.default.createDirectory(at: defaultDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(defaultDirectory)
    }
}
