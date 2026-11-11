import AppKit
import Combine

/// The saved transcripts in `~/Documents/hearsay`, for the main window's sidebar: one entry per
/// `.json` sidecar, newest first, kept current by watching the folder. Loading the full lines of
/// one transcript is a separate step (`load`), so the list stays cheap with hundreds of files.
///
/// Parsing happens on a utility queue (a long call's sidecar is a few hundred KB); the published
/// `entries` only change on the main thread. Sidecars are re-parsed only when their modification
/// date changes, so the once-a-second rewrite of the live session's file costs one small parse.
@MainActor
final class TranscriptLibrary: ObservableObject {
    /// What the sidebar shows for one transcript. `id` is the sidecar's URL.
    struct Entry: Identifiable, Equatable, Sendable {
        var id: URL { jsonURL }
        var jsonURL: URL
        var markdownURL: URL { jsonURL.deletingPathExtension().appendingPathExtension("md") }
        var srtURL: URL { jsonURL.deletingPathExtension().appendingPathExtension("srt") }
        var startedAt: Date
        /// nil while the session is still being written (or was never finished: a crash).
        var endedAt: Date?
        var engine: String
        var lineCount: Int
        /// App names in order of first appearance ("Zoom", "Chrome").
        var apps: [String]
        var pausedTotal: TimeInterval
        var lastLineEnd: Date

        /// Wall-clock length; an unfinished transcript ends with its last line.
        var duration: TimeInterval { max(0, (endedAt ?? lastLineEnd).timeIntervalSince(startedAt)) }
    }

    /// A transcript opened in the main window: the sidecar in full.
    struct Document: Equatable {
        var entry: Entry
        var lines: [TranscriptLine]
        var pauses: [PauseInterval]
    }

    @Published private(set) var entries: [Entry] = []
    let directory: URL
    private let queue = DispatchQueue(label: "hearsay.library", qos: .utility)
    private var watcher: DispatchSourceFileSystemObject?
    private var reloadPending = false
    /// Parsed entries keyed by sidecar URL with the modification date they were parsed at.
    private var cache: [URL: (modified: Date, entry: Entry?)] = [:]

    init(directory: URL = TranscriptStore.defaultDirectory) { self.directory = directory }

    // MARK: Listing

    /// Starts watching the folder (created if missing, so the watch has something to attach to)
    /// and loads the list.
    func start() {
        guard watcher == nil else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.path, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            src.setEventHandler { [weak self] in self?.scheduleReload() }
            src.setCancelHandler { close(fd) }
            src.resume()
            watcher = src
        } else {
            Log.warn("library: cannot watch \(directory.path)")
        }
        reload()
    }

    /// A finished transcript is two atomic renames (.md then .json): coalesce the burst.
    private func scheduleReload() {
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.reloadPending = false
            self?.reload()
        }
    }

    func reload() {
        let dir = directory
        let known = cache
        queue.async { [weak self] in
            let fm = FileManager.default
            // Rebuilt from `dir` so they compare equal to the store's own URLs (the listing
            // resolves symlinks, e.g. /var → /private/var).
            let urls = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { $0.pathExtension == "json" }.map { dir.appendingPathComponent($0.lastPathComponent) }
            var fresh: [URL: (modified: Date, entry: Entry?)] = [:]
            for url in urls {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if let c = known[url], c.modified == modified { fresh[url] = c; continue }
                fresh[url] = (modified, (try? Data(contentsOf: url)).flatMap { TranscriptLibrary.parse($0, url: url) })
            }
            let list = fresh.values.compactMap(\.entry).sorted { $0.startedAt > $1.startedAt }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.cache = fresh
                if self.entries != list { self.entries = list }
            }
        }
    }

    /// The sidebar's summary of one sidecar. nil when the file isn't a hearsay sidecar.
    nonisolated static func parse(_ data: Data, url: URL, appName: (String) -> String = { AppNames.name(for: $0) }) -> Entry? {
        guard let side = try? TranscriptStore.jsonDecoder.decode(TranscriptStore.Sidecar.self, from: data) else { return nil }
        var apps: [String] = []
        for case let app? in side.lines.map(\.sourceApp) {
            let n = appName(app)
            if !apps.contains(n) { apps.append(n) }
        }
        let lastEnd = side.lines.map(\.end).max() ?? side.startedAt
        let paused = (side.pauses ?? []).reduce(0) { $0 + $1.length(now: side.endedAt ?? lastEnd) }
        return Entry(jsonURL: url, startedAt: side.startedAt, endedAt: side.endedAt, engine: side.engine,
                     lineCount: side.lines.count, apps: apps, pausedTotal: paused, lastLineEnd: lastEnd)
    }

    // MARK: Loading one

    /// Reads the whole sidecar. Synchronous: a few hundred KB from local disk, and the caller
    /// wants the lines on the next frame.
    nonisolated static func load(_ url: URL, appName: (String) -> String = { AppNames.name(for: $0) }) -> Document? {
        guard let data = try? Data(contentsOf: url), let entry = parse(data, url: url, appName: appName),
              let side = try? TranscriptStore.jsonDecoder.decode(TranscriptStore.Sidecar.self, from: data) else { return nil }
        return Document(entry: entry, lines: side.lines, pauses: side.pauses ?? [])
    }

    // MARK: Deleting

    /// Moves the transcript's files (.md, .json and an exported .srt) to the Trash. The folder
    /// watcher drops the entry from the list once the move is done.
    func delete(_ entry: Entry) {
        let urls = [entry.markdownURL, entry.jsonURL, entry.srtURL].filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        Log.info("library: trashing \(entry.markdownURL.lastPathComponent)")
        NSWorkspace.shared.recycle(urls) { _, error in
            if let error = error { Log.error("library: trash failed: \(error)") }
        }
    }
}

extension Array where Element == TranscriptLine {
    /// The lines the window shows with some voices turned off. The saved files never use this:
    /// every line is always written; only the view, Copy and Export SRT of that view are filtered.
    func visible(hiding hidden: Set<Voice>) -> [TranscriptLine] {
        hidden.isEmpty ? self : filter { !hidden.contains(Voice($0)) }
    }

    /// Distinct voices in display order (me, then them by app).
    var voices: [Voice] {
        var seen = Set<Voice>()
        for line in self { seen.insert(Voice(line)) }
        return seen.sorted(by: Voice.displayOrder)
    }
}
