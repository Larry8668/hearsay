import AppKit
import Combine
import SwiftUI

/// What the main window shows: the live session, or one saved transcript (by its sidecar URL).
enum MainSelection: Hashable {
    case live
    case transcript(URL)
}

/// The main window's own state: selection, the opened transcript, and the voices hidden per
/// saved transcript (in memory only; the live view's set is `AppModel.hiddenVoices`). Outlives
/// the window, which is rebuilt each time it is shown.
@MainActor
final class MainWindowState: ObservableObject {
    @Published var selection: MainSelection = .live {
        didSet { if selection != oldValue { load() } }
    }
    @Published private(set) var document: TranscriptLibrary.Document?
    @Published var hiddenPast: [URL: Set<Voice>] = [:]
    /// The inline "Move to Trash?" row is showing for the selected transcript.
    @Published var confirmingDelete = false
    /// De-duplicated copies of the two `AppModel` values the toolbar and a saved transcript need:
    /// observing them here, not `AppModel`, keeps partials (several a second) away from those views.
    @Published private(set) var phase: AppModel.Phase = .idle
    @Published private(set) var fontSize: Double = 14.5
    let library: TranscriptLibrary
    private var subs: Set<AnyCancellable> = []

    init(library: TranscriptLibrary, model: AppModel) {
        self.library = library
        phase = model.phase
        fontSize = model.fontSize
        model.$phase.removeDuplicates().sink { [weak self] in self?.phase = $0 }.store(in: &subs)
        model.$fontSize.removeDuplicates().sink { [weak self] in self?.fontSize = $0 }.store(in: &subs)
        // The shown transcript trashed (here or in Finder): fall back to Live. Changed on disk
        // (its summary differs): read it again.
        library.$entries.dropFirst().sink { [weak self] entries in
            guard let self = self, case .transcript(let url) = self.selection else { return }
            guard let entry = entries.first(where: { $0.jsonURL == url }) else { self.selection = .live; return }
            if entry != self.document?.entry { self.load() }
        }.store(in: &subs)
    }

    var selectedEntry: TranscriptLibrary.Entry? {
        guard case .transcript(let url) = selection else { return nil }
        return library.entries.first { $0.jsonURL == url }
    }

    private func load() {
        confirmingDelete = false
        guard case .transcript(let url) = selection else { document = nil; return }
        document = TranscriptLibrary.load(url)
        if document == nil { Log.warn("library: could not load \(url.lastPathComponent)") }
    }

    func hidden(for url: URL) -> Set<Voice> { hiddenPast[url] ?? [] }
    func toggle(_ v: Voice, for url: URL) {
        var set = hidden(for: url)
        if set.contains(v) { set.remove(v) } else { set.insert(v) }
        hiddenPast[url] = set
    }
}

/// Sidebar: the Live entry, then the saved transcripts newest first, grouped by day.
struct MainSidebarView: View {
    @ObservedObject var state: MainWindowState
    @ObservedObject var library: TranscriptLibrary
    /// Not observed here: a partial arriving several times a second must only re-render the
    /// Live row (`LiveSidebarRow`), not the whole list.
    let model: AppModel
    /// The live session's own file, listed as "Live" rather than as a past transcript.
    let currentFile: () -> URL?

    var body: some View {
        List(selection: Binding(get: { Optional(state.selection) }, set: { if let s = $0 { state.selection = s } })) {
            LiveSidebarRow(state: state, model: model).tag(MainSelection.live)
            let groups = Self.group(library.entries.filter { $0.jsonURL != currentFile() })
            if groups.isEmpty {
                Text("No transcripts yet")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .padding(.top, 12).frame(maxWidth: .infinity, alignment: .center)
                    .selectionDisabled()
            }
            ForEach(groups, id: \.day) { group in
                Section(Self.dayTitle(group.day)) {
                    ForEach(group.entries) { entry in
                        row(entry).tag(MainSelection.transcript(entry.jsonURL))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand { if state.selectedEntry != nil { state.confirmingDelete = true } }
        .frame(minWidth: 200)
    }

    private func row(_ e: TranscriptLibrary.Entry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(e.startedAt, format: .dateTime.hour().minute()).font(.system(size: 13, weight: .medium))
                Spacer(minLength: 6)
                Text(e.endedAt == nil ? "unfinished" : TranscriptFormatter.duration(e.duration))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text(detail(e)).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .padding(.vertical, 2)
    }

    /// "48 lines · Zoom, Chrome"
    private func detail(_ e: TranscriptLibrary.Entry) -> String {
        var s = "\(e.lineCount) line\(e.lineCount == 1 ? "" : "s")"
        if !e.apps.isEmpty { s += " · " + e.apps.joined(separator: ", ") }
        return s
    }

    struct DayGroup { var day: Date; var entries: [TranscriptLibrary.Entry] }

    /// Entries are newest first; days come out newest first too.
    static func group(_ entries: [TranscriptLibrary.Entry]) -> [DayGroup] {
        var groups: [DayGroup] = []
        for e in entries {
            let day = Calendar.current.startOfDay(for: e.startedAt)
            if groups.last?.day == day { groups[groups.count - 1].entries.append(e) } else { groups.append(DayGroup(day: day, entries: [e])) }
        }
        return groups
    }

    static func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        let sameYear = Calendar.current.isDate(day, equalTo: Date(), toGranularity: .year)
        return day.formatted(sameYear ? .dateTime.weekday(.abbreviated).day().month(.abbreviated)
                                      : .dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
    }
}

/// "● Live — Listening · 12:34 · 48 lines". Highlighted (the sidebar's selection) while a session
/// is active; the dot is red while listening, amber while paused.
struct LiveSidebarRow: View {
    /// Observes the de-duplicated phase, not `AppModel`; the line count is read on each tick.
    @ObservedObject var state: MainWindowState
    let model: AppModel

    var body: some View {
        HStack(spacing: 9) {
            Circle().fill(dotColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text("Live").font(.system(size: 13, weight: .medium))
                if state.phase != .idle {
                    // Anchored to the session start so the tick lands on the second (see LiveContentView).
                    TimelineView(.periodic(from: model.startedAt ?? .now, by: 1)) { ctx in
                        Text(liveDetail(now: ctx.date)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    }
                } else {
                    Text(model.lines.isEmpty ? "Not listening" : "Last session kept")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private func liveDetail(now: Date) -> String {
        let n = model.lines.count
        let what: String
        switch state.phase {
        case .paused: what = "Paused"
        case .starting: what = "Starting"
        case .stopping: what = "Saving"
        default: what = "Listening"
        }
        var s = what + " · " + RecordingBarView.clock(model.listeningTime(now: now))
        s += " · \(n) line\(n == 1 ? "" : "s")"
        return s
    }

    private var dotColor: Color {
        switch state.phase {
        case .listening: return Color(red: 1, green: 0.27, blue: 0.23)
        case .paused: return Color(red: 1, green: 0.66, blue: 0.1)
        case .starting, .stopping: return Color.secondary.opacity(0.7)
        case .idle: return Color.secondary.opacity(0.35)
        }
    }
}
