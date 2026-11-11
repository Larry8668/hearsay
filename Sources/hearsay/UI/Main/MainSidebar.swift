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
        didSet {
            if picked != [selection] { picked = [selection] }
            if selection != oldValue { load() }
        }
    }
    /// What the sidebar highlights. One row is `selection`; two or more are a bulk selection
    /// (transcripts only: Live never joins one) and `selection` keeps its last single value.
    /// Changed through `pick`, which keeps the two in step.
    @Published private(set) var picked: Set<MainSelection> = [.live]
    @Published private(set) var document: TranscriptLibrary.Document?
    @Published var hiddenPast: [URL: Set<Voice>] = [:]
    /// The inline "Move to Trash?" row is showing for the selected transcript.
    @Published var confirmingDelete = false
    /// The header's open inline editor (title, tag field, a chip's rename), if any.
    @Published var editing: MetaEditing?
    /// The sidebar's search text, already debounced (`SidebarSearchField`).
    @Published var query = "" {
        didSet { if query != oldValue { dropHiddenPicks() } }
    }
    /// Settings ▸ Your name, de-duplicated from `AppModel` like `phase`.
    @Published private(set) var yourName: String?
    /// De-duplicated copies of the two `AppModel` values the toolbar and a saved transcript need:
    /// observing them here, not `AppModel`, keeps partials (several a second) away from those views.
    @Published private(set) var phase: AppModel.Phase = .idle
    @Published private(set) var fontSize: Double = 14.5
    let library: TranscriptLibrary
    /// The live session's own file: listed as "Live", and never trashed from here.
    private let currentFile: () -> URL?
    private var subs: Set<AnyCancellable> = []

    init(library: TranscriptLibrary, model: AppModel, currentFile: @escaping () -> URL? = { nil }) {
        self.library = library
        self.currentFile = currentFile
        phase = model.phase
        fontSize = model.fontSize
        yourName = model.yourName
        model.$phase.removeDuplicates().sink { [weak self] in self?.phase = $0 }.store(in: &subs)
        model.$fontSize.removeDuplicates().sink { [weak self] in self?.fontSize = $0 }.store(in: &subs)
        model.$yourName.removeDuplicates().sink { [weak self] in self?.yourName = $0 }.store(in: &subs)
        // The shown transcript trashed (here or in Finder): fall back to Live. Changed on disk
        // (its summary differs): read it again.
        library.$entries.dropFirst().sink { [weak self] entries in
            guard let self = self else { return }
            // Trashed rows (here or in Finder) leave a bulk selection too.
            let urls = Set(entries.map(\.jsonURL))
            let gone = self.picked.filter { if case .transcript(let u) = $0 { return !urls.contains(u) } else { return false } }
            if !gone.isEmpty { let rest = self.picked.subtracting(gone); self.pick(rest.isEmpty ? [.live] : rest) }
            guard case .transcript(let url) = self.selection else { return }
            guard let entry = entries.first(where: { $0.jsonURL == url }) else { self.selection = .live; return }
            if entry != self.document?.entry { self.load() }
        }.store(in: &subs)
    }

    /// Two or more transcripts highlighted: the content pane shows a summary, not a transcript.
    var isBulk: Bool { picked.count > 1 }

    /// The shown saved transcript; nil for Live and for a bulk selection.
    var selectedEntry: TranscriptLibrary.Entry? {
        guard !isBulk, case .transcript(let url) = selection else { return nil }
        return library.entries.first { $0.jsonURL == url }
    }

    /// The highlighted transcripts of a bulk selection, newest first.
    var bulkEntries: [TranscriptLibrary.Entry] {
        guard isBulk else { return [] }
        return library.entries.filter { picked.contains(.transcript($0.jsonURL)) }
    }

    /// The past transcripts the sidebar lists now (not the live file, matching the search),
    /// newest first.
    var visibleEntries: [TranscriptLibrary.Entry] {
        let live = currentFile()
        return library.entries.filter { $0.jsonURL != live && $0.matches(query) }
    }

    /// The List's selection came back changed. Live never stays in a multi-selection (⌘A and
    /// ⇧-click sweep it in); an empty set is refused like a click on nothing always was.
    func pick(_ new: Set<MainSelection>) {
        var s = new
        if s.count > 1 { s.remove(.live) }
        if s.isEmpty { s = [selection] }
        guard s != picked else { return }
        picked = s
        confirmingDelete = false
        if s.count == 1, let only = s.first { selection = only }
    }

    /// Typing in the search must not leave rows selected that the list no longer shows: a bulk
    /// delete would take them too.
    private func dropHiddenPicks() {
        guard isBulk else { return }
        let shown = Set(visibleEntries.map { MainSelection.transcript($0.jsonURL) })
        let kept = picked.intersection(shown)
        if kept != picked { pick(kept.isEmpty ? [selection] : kept) }
    }

    /// Delete key and the sidebar's context menu: the inline confirm for these rows (the clicked
    /// row, or the whole selection when it was in it).
    func askDelete(_ items: Set<MainSelection>) {
        let rows = items.filter { if case .transcript = $0 { return true } else { return false } }
        guard !rows.isEmpty else { return }
        pick(rows)
        confirmingDelete = true
    }

    /// Title / tags / names for the shown saved transcript: the view changes now, the files on
    /// the library's queue.
    func setMeta(_ meta: TranscriptMeta) {
        guard var doc = document, doc.entry.meta != meta else { return }
        doc.entry.meta = meta
        document = doc
        library.setMeta(meta, for: doc.entry)
    }

    private func load() {
        confirmingDelete = false
        editing = nil
        guard case .transcript(let url) = selection else { document = nil; return }
        document = TranscriptLibrary.load(url)
        if document == nil { Log.warn(.ui, "library: could not load \(url.lastPathComponent)") }
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
        VStack(spacing: 0) {
            SidebarSearchField(query: $state.query)
            List(selection: Binding(get: { state.picked }, set: { state.pick($0) })) {
                LiveSidebarRow(state: state, model: model).tag(MainSelection.live)
                let searching = !state.query.trimmingCharacters(in: .whitespaces).isEmpty
                let groups = Self.group(state.visibleEntries)
                if groups.isEmpty {
                    Text(searching ? "No matches" : "No transcripts yet")
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
            .contextMenu(forSelectionType: MainSelection.self) { items in
                if items.contains(where: { $0 != .live }) {
                    Button("Move to Trash") { state.askDelete(items) }
                }
            }
        }
        .onDeleteCommand { if state.isBulk || state.selectedEntry != nil { state.confirmingDelete = true } }
        .frame(minWidth: 200)
    }

    /// Title (or the start time) and length, then "14:03 · 48 lines · Zoom", then up to three
    /// tags. The time moves to the detail line when a title takes its place.
    private func row(_ e: TranscriptLibrary.Entry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                if let title = e.meta.title {
                    Text(title).font(.system(size: 13, weight: .medium))
                } else {
                    Text(e.startedAt, format: .dateTime.hour().minute()).font(.system(size: 13, weight: .medium))
                }
                Spacer(minLength: 6)
                Text(e.endedAt == nil ? "unfinished" : TranscriptFormatter.duration(e.duration))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text(detail(e)).font(.system(size: 11)).foregroundStyle(.secondary)
            if !e.meta.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(e.meta.tags.prefix(3), id: \.self) { TagChip(text: $0) }
                    if e.meta.tags.count > 3 { Text("+\(e.meta.tags.count - 3)").font(.system(size: 10)).foregroundStyle(.tertiary) }
                }
                .padding(.top, 1)
            }
        }
        .lineLimit(1)
        .padding(.vertical, 2)
    }

    /// "48 lines · Zoom, Chrome", led by the start time when the title line holds the title.
    private func detail(_ e: TranscriptLibrary.Entry) -> String {
        var s = "\(e.lineCount) line\(e.lineCount == 1 ? "" : "s")"
        if e.meta.title != nil { s = e.startedAt.formatted(.dateTime.hour().minute()) + " · " + s }
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
