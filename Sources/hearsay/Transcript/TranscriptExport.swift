import Foundation
import UniformTypeIdentifiers

/// The formats Export… offers. Markdown and JSON are the two files hearsay saves; text and
/// subtitles are derived.
enum ExportFormat: String, CaseIterable, Identifiable {
    case markdown, json, text, srt
    var id: String { rawValue }

    var title: String {
        switch self {
        case .markdown: return "Markdown (.md)"
        case .json: return "JSON (.json)"
        case .text: return "Plain text (.txt)"
        case .srt: return "Subtitles (.srt)"
        }
    }

    var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .json: return "json"
        case .text: return "txt"
        case .srt: return "srt"
        }
    }

    var contentType: UTType {
        switch self {
        case .json: return .json
        case .text: return .plainText
        default: return UTType(filenameExtension: fileExtension, conformingTo: .plainText) ?? .plainText
        }
    }
}

/// One transcript as the window shows it (hidden voices already removed), ready to render in any
/// format. Pure: no I/O, no global state, so each format is tested against a hidden voice.
struct TranscriptExport {
    /// The lines to export: the saved (or live) ones minus the voices turned off.
    var lines: [TranscriptLine]
    var start: Date
    var end: Date?
    var engine: String
    var pauses: [PauseInterval] = []
    var meta = TranscriptMeta()
    /// The file name without extension: the title (made safe for a file name) or the date name
    /// the transcript's own files use ("2026-11-09 14.03 hearsay").
    var baseName: String
    /// Already carries the names (`TranscriptStore.namedFormatter`).
    var formatter: TranscriptFormatter

    /// The live session (or the last one) with the window's voice filter applied.
    init(store: TranscriptStore, hiding hidden: Set<Voice>) {
        self.init(lines: store.lines.visible(hiding: hidden), start: store.startedAt, end: store.endedAt, engine: store.engine,
                  pauses: store.pauses, meta: store.meta,
                  baseName: store.markdownURL.deletingPathExtension().lastPathComponent, formatter: store.namedFormatter)
    }

    /// A saved transcript with the window's voice filter applied.
    init(document doc: TranscriptLibrary.Document, hiding hidden: Set<Voice>,
         formatter: TranscriptFormatter = TranscriptFormatter(), yourName: String? = VoiceNames.storedYourName) {
        var f = formatter
        f.names = VoiceNames(doc.entry.meta, yourName: yourName, roster: doc.speakers)
        self.init(lines: doc.lines.visible(hiding: hidden), start: doc.entry.startedAt, end: doc.entry.endedAt, engine: doc.entry.engine,
                  pauses: doc.pauses, meta: doc.entry.meta,
                  baseName: doc.entry.markdownURL.deletingPathExtension().lastPathComponent, formatter: f)
    }

    init(lines: [TranscriptLine], start: Date, end: Date?, engine: String, pauses: [PauseInterval] = [],
         meta: TranscriptMeta = TranscriptMeta(), baseName: String, formatter: TranscriptFormatter) {
        self.lines = lines; self.start = start; self.end = end; self.engine = engine
        self.pauses = pauses; self.meta = meta; self.baseName = baseName; self.formatter = formatter
    }

    /// The save panel's suggested name: the title when there is one, else the date name.
    var defaultName: String { meta.title.map(TranscriptExport.fileSafe) ?? baseName }

    /// "/" and ":" are path separators to the file system and Finder respectively; the rest is
    /// kept so a title survives the round trip through the file name readably.
    static func fileSafe(_ title: String) -> String {
        let s = title.map { "/:".contains($0) ? "-" : $0 }
        let t = String(s).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "transcript" : t
    }

    func render(_ format: ExportFormat) -> String {
        switch format {
        case .markdown: return formatter.markdown(lines: lines, start: start, end: end, engine: engine, pauses: pauses, meta: meta)
        case .json: return json()
        case .text: return formatter.plainLines(lines: lines)
        case .srt: return formatter.srt(lines: lines, start: start)
        }
    }

    /// The sidecar's own schema (so anything that reads `~/Documents/hearsay/*.json` reads this),
    /// holding only the visible lines plus the title, tags and names.
    private func json() -> String {
        var side = TranscriptStore.Sidecar(startedAt: start, endedAt: end, engine: engine, lines: lines, pauses: pauses.isEmpty ? nil : pauses)
        side.meta = meta
        // The generated labels of the speakers still shown (names are in `meta`).
        let shown = Set(lines.compactMap(\.speakerID))
        let speakers = formatter.names.roster.map.filter { shown.contains($0.key) }
        side.speakers = speakers.isEmpty ? nil : speakers
        guard let data = try? TranscriptStore.jsonEncoder.encode(side) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Writes `render(format)` to `url` atomically.
    func write(_ format: ExportFormat, to url: URL) throws {
        try Data(render(format).utf8).write(to: url, options: .atomic)
        Log.info("transcript: exported \(url.lastPathComponent) (\(format.rawValue), \(lines.count) lines)")
    }
}
