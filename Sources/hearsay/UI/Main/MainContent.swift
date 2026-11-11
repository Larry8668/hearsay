import AppKit
import SwiftUI

/// The main window's content pane: the live transcript or the selected saved one, each with a
/// header (title, details, speaker toggle chips) above the lines.
struct MainContentView: View {
    @ObservedObject var state: MainWindowState
    @ObservedObject var library: TranscriptLibrary
    /// Observed only by `LiveContentView`: a saved transcript must not re-render on every partial.
    let model: AppModel
    let actions: MainWindow.ContentActions

    var body: some View {
        Group {
            switch state.selection {
            case .live:
                LiveContentView(model: model, firstRun: library.entries.isEmpty)
            case .transcript(let url):
                if let doc = state.document, doc.entry.jsonURL == url {
                    PastContentView(doc: doc, state: state, actions: actions)
                } else {
                    ContentUnavailableView("Couldn't read this transcript", systemImage: "doc.questionmark",
                                           description: Text("The file may have been moved or isn't a hearsay sidecar."))
                }
            }
        }
        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Title, one line of details, and the voice chips. 16 pt gutters, 8/12 vertical rhythm.
struct ContentHeader<Detail: View>: View {
    let title: String
    @ViewBuilder let detail: Detail
    let voices: [Voice]
    let hidden: Set<Voice>
    let toggle: (Voice) -> Void
    let showAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                detail.font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
            if !voices.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    VoiceFilterBar(voices: voices, hidden: hidden, toggle: toggle, showAll: showAll)
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
    }
}

/// The current session, straight from `AppModel`: lines, partials, and the chips of every voice
/// heard so far. Follows new lines; the hidden voices come from `model.hiddenVoices`.
struct LiveContentView: View {
    @ObservedObject var model: AppModel
    let firstRun: Bool

    private var voices: [Voice] {
        Array(Set(model.lines.map { Voice($0) }).union(model.partials.keys)).sorted(by: Voice.displayOrder)
    }

    var body: some View {
        let hidden = model.hiddenVoices
        VStack(spacing: 0) {
            ContentHeader(title: "Live transcript", detail: {
                if model.startedAt != nil {
                    // Ticks once a second; only this text re-renders.
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in Text(details(now: ctx.date)) }
                } else {
                    Text("Not listening · press \(Hotkey.toggleListening.display) to start")
                }
            }, voices: voices, hidden: hidden,
               toggle: { v in if model.hiddenVoices.contains(v) { model.hiddenVoices.remove(v) } else { model.hiddenVoices.insert(v) } },
               showAll: { model.hiddenVoices = [] })
            Divider()
            if model.lines.isEmpty && model.partials.isEmpty {
                if firstRun && model.phase == .idle { FirstRunEmptyState(model: model) } else { LiveEmptyState(model: model) }
            } else {
                TranscriptView(lines: model.lines.visible(hiding: hidden),
                               partials: model.partials.filter { !hidden.contains($0.key) },
                               fontSize: model.fontSize, follow: true)
            }
        }
    }

    private func details(now: Date) -> String {
        let n = model.lines.count
        let count = "\(n) line\(n == 1 ? "" : "s")"
        switch model.phase {
        case .idle: return "Last session · \(count)"
        case .starting: return model.pausedAt == nil && model.pausedTotal == 0 && n == 0 ? "Starting…" : "Resuming…"
        case .stopping: return "Saving transcript… · \(count)"
        case .listening, .paused:
            var s = (model.phase == .paused ? "Paused" : "Listening") + " · " + RecordingBarView.clock(model.listeningTime(now: now)) + " · " + count
            if model.pausedTotal > 0 || model.pausedAt != nil { s += " · " + TranscriptFormatter.shortDuration(model.pausedTotal + (model.pausedAt.map { now.timeIntervalSince($0) } ?? 0)) + " paused" }
            return s
        }
    }
}

/// A saved transcript from its sidecar, with the inline "Move to Trash?" row when asked.
struct PastContentView: View {
    let doc: TranscriptLibrary.Document
    @ObservedObject var state: MainWindowState
    let actions: MainWindow.ContentActions

    var body: some View {
        let e = doc.entry
        let hidden = state.hidden(for: e.jsonURL)
        VStack(spacing: 0) {
            ContentHeader(title: TranscriptFormatter().dateRange(start: e.startedAt, end: e.endedAt),
                          detail: { Text(details) }, voices: doc.lines.voices, hidden: hidden,
                          toggle: { state.toggle($0, for: e.jsonURL) }, showAll: { state.hiddenPast[e.jsonURL] = [] })
            Divider()
            if state.confirmingDelete {
                deleteRow(e)
                Divider()
            }
            if doc.lines.isEmpty {
                ContentUnavailableView("Nothing was said", systemImage: "captions.bubble")
            } else {
                TranscriptView(lines: doc.lines.visible(hiding: hidden), pauses: doc.pauses, fontSize: state.fontSize)
            }
        }
    }

    /// "38 min, 4 min paused · 48 lines · Apps heard: Zoom, Chrome · parakeet-unified-640ms"
    private var details: String {
        let e = doc.entry
        var parts: [String] = []
        if let end = e.endedAt { parts.append(TranscriptFormatter().lengthText(start: e.startedAt, end: end, pauses: doc.pauses)) }
        else { parts.append("unfinished · " + TranscriptFormatter.duration(e.duration)) }
        parts.append("\(e.lineCount) line\(e.lineCount == 1 ? "" : "s")")
        if !e.apps.isEmpty { parts.append("Apps heard: " + e.apps.joined(separator: ", ")) }
        parts.append(e.engine.isEmpty ? "unknown engine" : e.engine)
        return parts.joined(separator: " · ")
    }

    /// Inline, not a sheet: a sheet would take focus from the call app and block the window.
    private func deleteRow(_ e: TranscriptLibrary.Entry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "trash").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Move this transcript to the Trash?").font(.system(size: 13, weight: .medium))
                Text("\(e.markdownURL.lastPathComponent) and its .json sidecar.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            Button("Cancel") { state.confirmingDelete = false }.keyboardShortcut(.cancelAction)
            Button("Move to Trash") { actions.delete(e) }.keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent).tint(.red)
        }
        .controlSize(.small)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.red.opacity(0.06))
    }
}

/// Start / Pause / Stop in the toolbar, with the listening time while a session runs.
/// Observes `MainWindowState.phase` (de-duplicated), not `AppModel`, so partials don't touch it.
struct SessionControl: View {
    @ObservedObject var state: MainWindowState
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            switch state.phase {
            case .idle:
                Button { model.actions.toggleListening() } label: {
                    Label("Start listening", systemImage: "record.circle")
                }
                .buttonStyle(PrimaryButtonStyle())
                .help("Start listening (\(Hotkey.toggleListening.display))")
            case .starting, .stopping:
                ProgressView().controlSize(.small)
                Text(state.phase == .starting ? "Starting…" : "Saving…").font(.system(size: 12)).foregroundStyle(.secondary)
                if state.phase == .starting { stopButton }
            case .listening, .paused:
                HStack(spacing: 6) {
                    Circle().fill(state.phase == .paused ? Color(red: 1, green: 0.66, blue: 0.1) : Color(red: 1, green: 0.27, blue: 0.23))
                        .frame(width: 7, height: 7)
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(RecordingBarView.clock(model.listeningTime(now: ctx.date)))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                    }
                }
                .padding(.trailing, 2)
                Button { model.actions.togglePause() } label: {
                    Label(state.phase == .paused ? "Resume" : "Pause", systemImage: state.phase == .paused ? "play.fill" : "pause.fill")
                }
                .help("\(state.phase == .paused ? "Resume" : "Pause") (\(Hotkey.togglePause.display))")
                stopButton
            }
        }
        .labelStyle(.titleAndIcon)
        .font(.system(size: 12))
        // Fixed width: NSToolbar sizes a custom item once, so the control must not grow when
        // "Start listening" becomes dot + time + Pause + Stop (hours need the extra room).
        .frame(width: 250, height: 28, alignment: .leading)
        .animation(.easeOut(duration: 0.15), value: state.phase)
    }

    private var stopButton: some View {
        Button { model.actions.stop() } label: { Label("Stop", systemImage: "stop.fill") }
            .help("Stop and save the transcript (\(Hotkey.toggleListening.display))")
    }
}

/// The window's one accent-filled button. Drawn by hand: `.borderedProminent` inside a
/// toolbar item comes out grey (the toolbar's vibrancy washes the tint out).
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 11).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1)))
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Smaller / larger transcript text (the Settings menu has named sizes too).
struct FontSizeControl: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            Button { model.bumpFont(-1) } label: { Text("A").font(.system(size: 10.5, weight: .medium)).frame(width: 22, height: 22) }
                .help("Smaller text")
            Button { model.bumpFont(1) } label: { Text("A").font(.system(size: 14, weight: .medium)).frame(width: 22, height: 22) }
                .help("Larger text")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
    }
}
